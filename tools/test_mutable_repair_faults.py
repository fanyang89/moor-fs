"""Real process-death checkpoints in sealed mutable replica repair."""

import errno
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time


def wait_stopped(process, point, log):
    deadline = time.monotonic() + 60
    while True:
        pid, status = os.waitpid(process.pid, os.WUNTRACED | os.WNOHANG)
        if pid:
            if os.WIFSTOPPED(status):
                assert os.WSTOPSIG(status) == signal.SIGSTOP, status
                return
            process.returncode = os.waitstatus_to_exitcode(status)
            raise AssertionError(f"process missed {point}: {log.read_text()}")
        assert time.monotonic() < deadline, f"checkpoint timed out: {point}"
        time.sleep(0.02)


def test_mutable_repair_faults(
    executable, directory, endpoints, config, inode, path, data, run
):
    chunk = 256 * 1024
    content = bytes(range(256)) * 3072 + b"repair-tail"
    with open(path, "wb", buffering=0) as writer:
        assert writer.write(content) == len(content)
        os.fsync(writer.fileno())
    report = run("seal-mutable", endpoints, config, inode)
    assert report["sealed"] and report["sha256"] == hashlib.sha256(content).hexdigest()
    metadata = run("get", endpoints, inode)
    mappings = {entry["id"]: entry for entry in json.loads(Path(config).read_text())}
    binding = metadata["mutable_file"]
    client_data = [
        Path(mappings[backend]["root"])
        / "mutable"
        / f"{inode}-{binding['generation']}"
        / "data"
        for backend in binding["backends"]
    ]
    identities = [file.stat().st_ino for file in data]
    # Inspect on the server side for CIFS: mandatory client locks must remain
    # held while repair is paused. Only the test injects out-of-band corruption.
    evidence = [
        {
            file.name: file.read_bytes()
            for file in target.parent.iterdir()
            if file.name != "data"
        }
        for target in data
    ]
    damaged = b"?" * (len(content) + 31)

    for bad in range(2):
        for missing, point in (
            (False, "mutable_first_chunk"),
            (False, "mutable_synced"),
            (True, "mutable_created"),
            (True, "mutable_first_chunk"),
            (True, "mutable_synced"),
        ):
            if missing:
                # Delete through the tested mount so CIFS invalidates its cached
                # dentry/deferred handle before the missing-path assertion.
                client_data[bad].unlink()
                fd = os.open(client_data[bad].parent, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(fd)
                finally:
                    os.close(fd)
                failed = run("scrub-mutable", endpoints, config, inode, success=False)
                assert "FileNotFound" in failed.stdout + failed.stderr, failed
                assert not data[bad].exists()
            else:
                with open(data[bad], "r+b", buffering=0) as target:
                    target.write(damaged)
                    target.truncate(len(damaged))
                    os.fsync(target.fileno())
            log = directory / f"mutable-repair-{bad}-{missing}-{point}.log"
            with log.open("w") as output:
                process = subprocess.Popen(
                    [
                        executable,
                        "repair-mutable",
                        endpoints,
                        str(config),
                        str(inode),
                    ],
                    stdout=output,
                    stderr=output,
                    env={**os.environ, "NAS_FS_REPAIR_STOP": point},
                )
            try:
                wait_stopped(process, point, log)
                expected = (
                    b""
                    if point == "mutable_created"
                    else (
                        content[:chunk] + (b"" if missing else damaged[chunk:])
                        if point == "mutable_first_chunk"
                        else content
                    )
                )
                assert data[bad].read_bytes() == expected
                if missing:
                    identities[bad] = data[bad].stat().st_ino
                assert data[1 - bad].stat().st_ino == identities[1 - bad]
                assert data[1 - bad].read_bytes() == content
                assert run("get", endpoints, inode) == metadata
                for command in ("scrub-mutable", "repair-mutable"):
                    busy = run(command, endpoints, config, inode, success=False)
                    assert "FileBusy" in busy.stdout + busy.stderr, busy
                try:
                    fd = os.open(path, os.O_RDONLY)
                except OSError as exc:
                    assert exc.errno == errno.EBUSY, exc
                else:
                    os.close(fd)
                    raise AssertionError("FUSE opened a file owned by stopped repair")
                process.kill()
                assert process.wait(timeout=15) == -signal.SIGKILL
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=15)

            assert data[bad].read_bytes() == expected
            assert data[1 - bad].read_bytes() == content
            for index, target in enumerate(data):
                assert {
                    file.name: file.read_bytes()
                    for file in target.parent.iterdir()
                    if file.name != "data"
                } == evidence[index]
            if point in ("mutable_created", "mutable_first_chunk"):
                failed = run("scrub-mutable", endpoints, config, inode, success=False)
                assert "SealedContentMismatch" in failed.stdout + failed.stderr, failed
            else:
                assert run("scrub-mutable", endpoints, config, inode)["sealed"]
            repaired = run("repair-mutable", endpoints, config, inode)
            assert repaired["sealed"] and repaired["sha256"] == report["sha256"]
            assert all(file.read_bytes() == content for file in data)
            assert [file.stat().st_ino for file in data] == identities
            assert run("get", endpoints, inode) == metadata
            read_started = time.time_ns()
            assert path.read_bytes() == content
            accessed = run("get", endpoints, inode)
            atime = accessed["times"]["atime"]
            assert (
                read_started
                <= atime["seconds"] * 1000000000 + atime["nanoseconds"]
                <= time.time_ns()
            )
            assert accessed["access"]["sequence"] > (
                metadata["access"]["sequence"] if metadata["access"] else 0
            )
            metadata["times"]["atime"] = atime
            metadata["access"] = accessed["access"]
            assert accessed == metadata
            print(
                f"PASS: mutable {'missing-data rebuild' if missing else 'repair'} NAS {bad + 1} SIGKILL at {point}, source/evidence preserved, ownership and in-place retry",
                flush=True,
            )

    # One missing empty active log can be recreated only while both complete
    # files still match both seals. Its publication must survive process death.
    log_name = f"wal-{metadata['mutable_file']['next_sequence']}"
    for missing in range(2):
        lost_log = client_data[missing].parent / log_name
        lost_log.unlink()
        fd = os.open(lost_log.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
        failed = run("scrub-mutable", endpoints, config, inode, success=False)
        assert "FileNotFound" in failed.stdout + failed.stderr, failed
        assert not lost_log.exists()
        source_log_inode = (data[1 - missing].parent / log_name).stat().st_ino
        log = directory / f"mutable-wal-rebuild-{missing}.log"
        with log.open("w") as output:
            process = subprocess.Popen(
                [executable, "repair-mutable", endpoints, str(config), str(inode)],
                stdout=output,
                stderr=output,
                env={**os.environ, "NAS_FS_REPAIR_STOP": "mutable_wal_created"},
            )
        try:
            wait_stopped(process, "mutable_wal_created", log)
            new_inode = (data[missing].parent / log_name).stat().st_ino
            assert all(file.read_bytes() == content for file in data)
            assert [file.stat().st_ino for file in data] == identities
            assert run("get", endpoints, inode) == metadata
            for command in ("scrub-mutable", "repair-mutable"):
                busy = run(command, endpoints, config, inode, success=False)
                assert "FileBusy" in busy.stdout + busy.stderr, busy
            process.kill()
            assert process.wait(timeout=15) == -signal.SIGKILL
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=15)
        for index, target in enumerate(data):
            assert {
                file.name: file.read_bytes()
                for file in target.parent.iterdir()
                if file.name != "data"
            } == evidence[index]
        assert run("scrub-mutable", endpoints, config, inode)["sealed"]
        assert (
            run("repair-mutable", endpoints, config, inode)["sha256"]
            == report["sha256"]
        )
        assert run("get", endpoints, inode) == metadata
        assert (data[missing].parent / log_name).stat().st_ino == new_inode
        assert (data[1 - missing].parent / log_name).stat().st_ino == source_log_inode
        assert [file.stat().st_ino for file in data] == identities
        print(
            f"PASS: missing active WAL on NAS {missing + 1} rebuilt durably before SIGKILL, data/evidence preserved and retry succeeds",
            flush=True,
        )
