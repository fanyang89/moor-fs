"""WAL FUSE sessions, in-place updates and acknowledged-write crash recovery."""

import errno
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def test_wal_fuse(executable, directory, endpoints, run, smb=False, server_roots=None):
    config = directory / "backends.json"
    roots = [Path(item["root"]) for item in json.loads(config.read_text())]
    processes, mounts, logs = [], [], []

    def mount():
        path = directory / f"wal-mount-{len(mounts)}"
        path.mkdir()
        mounts.append(path)
        log = open(directory / f"{path.name}.log", "w+")
        logs.append(log)
        process = subprocess.Popen(
            [
                executable,
                "mount",
                endpoints,
                str(path),
                "--backends",
                str(config),
                "--write-backends",
                "1,2",
                "--write-mode",
                "wal",
            ],
            stdout=log,
            stderr=log,
        )
        processes.append(process)
        deadline = time.monotonic() + 20
        while not os.path.ismount(path):
            assert process.poll() is None, Path(log.name).read_text()
            assert time.monotonic() < deadline, "WAL mount timed out"
            time.sleep(0.05)
        return path, process

    def error(operation, expected):
        try:
            operation()
        except OSError as exc:
            assert exc.errno in expected, exc
        else:
            raise AssertionError(f"expected errno {expected}")

    try:
        inode = run(
            "apply",
            endpoints,
            json.dumps(
                {
                    "request_id": 40000,
                    "command": {
                        "create": {"parent": 1, "name": "wal-file", "kind": "file"},
                    },
                }
            ),
        )["inode"]
        source = directory / "wal-source"
        source.write_bytes(b"baseline")
        assert (
            run(
                "put-file",
                endpoints,
                config,
                json.dumps(
                    {
                        "request_id": 40001,
                        "inode": inode,
                        "version_id": 40001,
                        "expected_version": 0,
                        "backends": [1, 2],
                    }
                ),
                source,
            )["status"]
            == "ok"
        )
        historical = [set((root / "objects").iterdir()) for root in roots]
        run("scrub-mutable", endpoints, config, inode, success=False)
        assert run("get", endpoints, inode)["mutable_file"] is None
        first, process = mount()
        second, _ = mount()
        path = first / "wal-file"
        with open(path, "rb", buffering=0) as reader:
            assert reader.read() == b"baseline"
            bound = run("get", endpoints, inode)["mutable_file"]
            leaves = [
                root / "mutable" / f"{inode}-{bound['generation']}" for root in roots
            ]
            identities = [(leaf / "data").stat().st_ino for leaf in leaves]
            with open(path, "r+b", buffering=0) as writer:
                error(lambda: os.open(path, os.O_WRONLY), {errno.EBUSY})
                error(lambda: os.open(second / "wal-file", os.O_RDONLY), {errno.EBUSY})
                error(path.unlink, {errno.EBUSY})
                assert os.pwrite(writer.fileno(), b"XY", 4) == 2
                assert os.pread(reader.fileno(), 8, 0) == b"baseXYne"
                assert os.pwrite(writer.fileno(), b"Z", 4096) == 1
                assert path.stat().st_size == os.fstat(reader.fileno()).st_size == 4097
                assert os.pread(reader.fileno(), 4089, 8) == b"\0" * 4088 + b"Z"
                os.ftruncate(writer.fileno(), 6)
                assert os.pread(reader.fileno(), 8, 0) == b"baseXY"
                os.fsync(writer.fileno())
                os.fsync(writer.fileno())
        with open(path, "wb", buffering=0) as writer:
            assert path.stat().st_size == 0
            writer.write(b"replacement")
        fd = os.open(path, os.O_WRONLY | os.O_DSYNC)
        try:
            assert os.pwrite(fd, b"R", 0) == 1
        finally:
            os.close(fd)
        assert path.read_bytes() == b"Replacement"
        for i, leaf in enumerate(leaves):
            assert (leaf / "data").read_bytes() == b"Replacement"
            assert (leaf / "data").stat().st_ino == identities[i]
            assert set((roots[i] / "objects").iterdir()) == historical[i]
        print(
            "PASS: WAL migration, shared reads/live size, sparse writes, truncate, fsync, O_DSYNC and ownership",
            flush=True,
        )

        reader = os.open(path, os.O_RDONLY)
        writer = os.open(path, os.O_WRONLY)
        hidden = directory / "wal-hidden-backend"
        if smb:
            hidden.mkdir()
            subprocess.run(
                ["sudo", "-n", "mount", "--bind", str(hidden), str(roots[1])],
                check=True,
            )
        else:
            roots[1].rename(hidden)
            roots[1].mkdir()
        try:
            error(lambda: os.pwrite(writer, b"bad", 0), {errno.EIO})
            error(lambda: os.pread(reader, 3, 0), {errno.EIO})
        finally:
            if smb:
                subprocess.run(["sudo", "-n", "umount", str(roots[1])], check=True)
            else:
                roots[1].rmdir()
                hidden.rename(roots[1])
        error(lambda: os.fsync(writer), {errno.EIO})
        error(lambda: os.pread(reader, 3, 0), {errno.EIO})
        for fd in (writer, reader):
            try:
                os.close(fd)
            except OSError as exc:
                assert exc.errno == errno.EIO
        assert path.read_bytes() == b"Replacement"
        print(
            "PASS: backend path replacement freezes all shared handles; restored backend requires reopen",
            flush=True,
        )

        # No descriptor is inherited by the parent; the child pauses only after
        # write acknowledgement, without flush/fsync/close checkpointing.
        assert run("seal-mutable", endpoints, config, inode)["sealed"]
        child = subprocess.Popen(
            [
                sys.executable,
                "-c",
                """
import os, signal, sys
fd = os.open(sys.argv[1], os.O_WRONLY)
assert os.pwrite(fd, b'acknowledged', 0) == 12
os.kill(os.getpid(), signal.SIGSTOP)
try:
    os.fsync(fd)
except OSError:
    os._exit(0)
os._exit(1)
""",
                str(path),
            ]
        )
        try:
            deadline = time.monotonic() + 30
            while True:
                assert child.poll() is None
                status = Path(f"/proc/{child.pid}/status").read_text()
                if any(
                    line.startswith("State:") and "T" in line
                    for line in status.splitlines()
                ):
                    break
                assert time.monotonic() < deadline
                time.sleep(0.05)
            assert all(not (leaf / "seal").exists() for leaf in leaves)
            process.kill()
            process.wait(timeout=15)
            child.send_signal(signal.SIGCONT)
            assert child.wait(timeout=15) == 0
        finally:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=15)
        recovered, _ = mount()
        assert (recovered / "wal-file").read_bytes() == b"acknowledged"
        assert run("get", endpoints, inode)["mutable_file"]["size"] == 12
        print(
            "PASS: acknowledged WAL write survives FUSE SIGKILL; old fsync fails and reopen reconciles metadata",
            flush=True,
        )
        if smb:
            from serve_smb import export

            with export(recovered, directory / "wal-smb", writable=True) as (_, port):

                def client(command):
                    result = subprocess.run(
                        [
                            "smbclient",
                            "//127.0.0.1/nas",
                            "-p",
                            str(port),
                            "-N",
                            "-U",
                            "guest",
                            "--option=client min protocol=SMB3",
                            "-c",
                            command,
                        ],
                        capture_output=True,
                        text=True,
                        timeout=90,
                    )
                    assert (
                        result.returncode == 0
                        and "NT_STATUS_" not in result.stdout + result.stderr
                    ), result

                target = directory / "wal-download"
                for content in (b"upload" * 1000, b"overwrite", b""):
                    source.write_bytes(content)
                    client(f"put {source} smb-wal; get smb-wal {target}")
                    assert target.read_bytes() == content
                client(
                    "mkdir wal-dir; rename smb-wal wal-dir/renamed; del wal-dir/renamed; rmdir wal-dir"
                )
            print(
                "PASS: real SMB WAL upload, overwrite, download, empty file, rename, deletion and directories",
                flush=True,
            )
            supervised = directory / "wal-supervised"
            supervised.mkdir()
            log_path = directory / "wal-supervised.log"
            with log_path.open("w") as output:
                supervisor = subprocess.Popen(
                    [
                        sys.executable,
                        str(Path(__file__).with_name("serve_access.py")),
                        endpoints,
                        str(supervised),
                        str(directory / "wal-access-state"),
                        "--executable",
                        executable,
                        "--backends",
                        str(config),
                        "--write-backends",
                        "1,2",
                        "--write-mode",
                        "wal",
                        "--port",
                        "0",
                    ],
                    stdout=output,
                    stderr=output,
                )
            try:
                deadline = time.monotonic() + 60
                while True:
                    assert supervisor.poll() is None, log_path.read_text()
                    ready = [
                        line
                        for line in log_path.read_text().splitlines()
                        if line.startswith('{"ready":')
                    ]
                    if ready:
                        status = json.loads(ready[0])
                        assert status["write_mode"] == "wal" and status["writable"]
                        port = status["port"]
                        break
                    assert time.monotonic() < deadline, log_path.read_text()
                    time.sleep(0.05)
                source.write_bytes(b"supervised WAL")
                client(
                    f"put {source} supervised-wal; get supervised-wal {target}; del supervised-wal"
                )
                assert target.read_bytes() == b"supervised WAL"
            finally:
                supervisor.terminate()
                supervisor.wait(timeout=45)
            assert supervisor.returncode == 0 and not os.path.ismount(supervised), (
                log_path.read_text()
            )
            print(
                "PASS: supervisor forwards WAL mode, serves SMB and shuts down cleanly",
                flush=True,
            )
        report = run("scrub-mutable", endpoints, config, inode)
        assert report["replicas_equal"] and report["size"] == 12
        assert report["sha256"] == hashlib.sha256(b"acknowledged").hexdigest()
        physical_roots = server_roots or roots
        for bad in range(2):
            reader = os.open(recovered / "wal-file", os.O_RDONLY)
            other = os.open(recovered / "wal-file", os.O_RDONLY)
            busy = run("scrub-mutable", endpoints, config, inode, success=False)
            assert "FileBusy" in busy.stdout + busy.stderr, busy
            data = physical_roots[bad] / "mutable" / leaves[bad].name / "data"
            with open(data, "r+b", buffering=0) as corrupt:
                corrupt.write(b"X")
                os.fsync(corrupt.fileno())
            error(lambda: os.pread(reader, 12, 0), {errno.EIO})
            error(lambda: os.pread(other, 12, 0), {errno.EIO})
            for fd in (reader, other):
                try:
                    os.close(fd)
                except OSError as exc:
                    assert exc.errno == errno.EIO
            failed = run("scrub-mutable", endpoints, config, inode, success=False)
            assert "ReplicaContentMismatch" in failed.stdout + failed.stderr, failed
            assert data.read_bytes() == b"Xcknowledged"
            assert (
                physical_roots[1 - bad] / "mutable" / leaves[1 - bad].name / "data"
            ).read_bytes() == b"acknowledged"
            # Restore the injected byte from the test fixture, not by electing
            # an unverified replica as an automatic repair source.
            with open(data, "r+b", buffering=0) as restored:
                restored.write(b"a")
                os.fsync(restored.fileno())
            assert (recovered / "wal-file").read_bytes() == b"acknowledged"
        print(
            "PASS: corruption on either NAS fails shared reads and scrub without repairing from an untrusted peer",
            flush=True,
        )
        missing = run("repair-mutable", endpoints, config, inode, success=False)
        assert "MissingSeal" in missing.stdout + missing.stderr, missing
        sealed = run("seal-mutable", endpoints, config, inode)
        assert sealed["sealed"] and sealed["sha256"] == report["sha256"]
        physical = [
            root / "mutable" / leaf.name / "data"
            for root, leaf in zip(physical_roots, leaves)
        ]
        stable_inodes = [data.stat().st_ino for data in physical]
        for bad in range(2):
            with open(physical[bad], "r+b", buffering=0) as corrupt:
                corrupt.write(b"damaged-and-longer")
                os.fsync(corrupt.fileno())
            failed = run("scrub-mutable", endpoints, config, inode, success=False)
            assert "SealedContentMismatch" in failed.stdout + failed.stderr, failed
            repaired = run("repair-mutable", endpoints, config, inode)
            assert repaired["sealed"] and repaired["sha256"] == sealed["sha256"]
            assert all(data.read_bytes() == b"acknowledged" for data in physical)
            assert [data.stat().st_ino for data in physical] == stable_inodes
        for data in physical:
            with open(data, "r+b", buffering=0) as corrupt:
                corrupt.write(b"X")
                os.fsync(corrupt.fileno())
        failed = run("repair-mutable", endpoints, config, inode, success=False)
        assert "NoVerifiedReplica" in failed.stdout + failed.stderr, failed
        failed = run("seal-mutable", endpoints, config, inode, success=False)
        assert "SealedContentMismatch" in failed.stdout + failed.stderr, failed
        assert all(data.read_bytes() == b"Xcknowledged" for data in physical)
        # The fixture restores the original source; production needs an actual
        # verified backup when neither replica matches the persistent baseline.
        with open(physical[0], "r+b", buffering=0) as restored:
            restored.write(b"a")
            os.fsync(restored.fileno())
        assert run("repair-mutable", endpoints, config, inode)["sealed"]
        print(
            "PASS: persistent baseline repairs either replica in place, rejects identical corruption and survives write invalidation/SIGKILL",
            flush=True,
        )
        (recovered / "wal-file").unlink()
    finally:
        for path in reversed(mounts):
            subprocess.run(
                ["fusermount3", "-uz", str(path)], capture_output=True, timeout=15
            )
        for process in processes:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=15)
        for log in logs:
            log.close()
