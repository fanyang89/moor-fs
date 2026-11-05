"""Real process-death checkpoints in sealed mutable replica repair."""

import errno
import hashlib
import os
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
        for point in ("mutable_first_chunk", "mutable_synced"):
            with open(data[bad], "r+b", buffering=0) as target:
                target.write(damaged)
                target.truncate(len(damaged))
                os.fsync(target.fileno())
            log = directory / f"mutable-repair-{bad}-{point}.log"
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
                    content[:chunk] + damaged[chunk:]
                    if point == "mutable_first_chunk"
                    else content
                )
                assert data[bad].read_bytes() == expected
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
            if point == "mutable_first_chunk":
                failed = run("scrub-mutable", endpoints, config, inode, success=False)
                assert "SealedContentMismatch" in failed.stdout + failed.stderr, failed
            else:
                assert run("scrub-mutable", endpoints, config, inode)["sealed"]
            repaired = run("repair-mutable", endpoints, config, inode)
            assert repaired["sealed"] and repaired["sha256"] == report["sha256"]
            assert all(file.read_bytes() == content for file in data)
            assert [file.stat().st_ino for file in data] == identities
            assert run("get", endpoints, inode) == metadata
            assert path.read_bytes() == content
            print(
                f"PASS: mutable repair NAS {bad + 1} SIGKILL at {point}, source/evidence preserved, ownership and in-place retry",
                flush=True,
            )
