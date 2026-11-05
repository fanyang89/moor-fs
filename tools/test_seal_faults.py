"""Real SIGKILL at durable seal publication and pre-write invalidation boundaries."""

import hashlib
import os
import signal
import subprocess
import sys
import time

from test_mutable_repair_faults import wait_stopped


def test_seal_faults(executable, directory, endpoints, config, inode, path, data, run):
    content = b"seal lifecycle payload\n" * 4096
    identities = [file.stat().st_ino for file in data]

    def snapshot():
        return [
            {
                file.name: file.read_bytes()
                for file in target.parent.iterdir()
                if file.name != "seal"
            }
            for target in data
        ]

    def seed():
        with open(path, "wb", buffering=0) as writer:
            assert writer.write(content) == len(content)
            os.fsync(writer.fileno())
        assert all(not (file.parent / "seal").exists() for file in data)

    def check_unchanged(before, metadata):
        assert snapshot() == before
        assert run("get", endpoints, inode) == metadata
        assert [file.stat().st_ino for file in data] == identities

    for point in ("seal_first_published", "seal_published"):
        seed()
        before = snapshot()
        metadata = run("get", endpoints, inode)
        log = directory / f"{point}.log"
        with log.open("w") as output:
            process = subprocess.Popen(
                [
                    executable,
                    "seal-mutable",
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
            expected = [True, point == "seal_published"]
            assert [(file.parent / "seal").exists() for file in data] == expected
            check_unchanged(before, metadata)
            process.kill()
            assert process.wait(timeout=15) == -signal.SIGKILL
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=15)
        check_unchanged(before, metadata)
        report = run("scrub-mutable", endpoints, config, inode)
        assert (
            report["sealed"] and report["sha256"] == hashlib.sha256(content).hexdigest()
        )
        assert run("seal-mutable", endpoints, config, inode)["sealed"]
        assert (data[0].parent / "seal").read_bytes() == (
            data[1].parent / "seal"
        ).read_bytes()
        assert path.read_bytes() == content
        print(
            f"PASS: SIGKILL at {point}, durable baseline retained and publication retry succeeds",
            flush=True,
        )

    for operation in ("write", "truncate"):
        for point in ("seal_first_invalidated", "seal_invalidated"):
            seed()
            assert run("seal-mutable", endpoints, config, inode)["sealed"]
            before = snapshot()
            metadata = run("get", endpoints, inode)
            seal_bytes = (data[1].parent / "seal").read_bytes()
            mount = directory / f"{point}-{operation}"
            mount.mkdir()
            log = directory / f"{mount.name}.log"
            child = None
            with log.open("w") as output:
                process = subprocess.Popen(
                    [
                        executable,
                        "mount",
                        endpoints,
                        str(mount),
                        "--backends",
                        str(config),
                        "--write-backends",
                        "1,2",
                        "--write-mode",
                        "wal",
                    ],
                    stdout=output,
                    stderr=output,
                    env={**os.environ, "NAS_FS_REPAIR_STOP": point},
                )
            try:
                deadline = time.monotonic() + 20
                while not os.path.ismount(mount):
                    assert process.poll() is None, log.read_text()
                    assert time.monotonic() < deadline, log.read_text()
                    time.sleep(0.05)
                child = subprocess.Popen(
                    [
                        sys.executable,
                        "-c",
                        """
import errno, os, sys
fd = os.open(sys.argv[1], os.O_WRONLY)
try:
    if sys.argv[2] == 'write':
        os.pwrite(fd, b'changed', 0)
    else:
        os.ftruncate(fd, 3)
except OSError as exc:
    print(f'mutation failed: {exc}', flush=True)
    os._exit(0 if exc.errno in (errno.EIO, errno.ENOTCONN, errno.ECONNABORTED) else 2)
os._exit(1)
""",
                        str(mount / path.name),
                        operation,
                    ]
                )
                wait_stopped(process, point, log)
                assert child.poll() is None, (
                    "mutation returned before invalidation completed"
                )
                expected = [False, point == "seal_first_invalidated"]
                assert [(file.parent / "seal").exists() for file in data] == expected
                if expected[1]:
                    assert (data[1].parent / "seal").read_bytes() == seal_bytes
                check_unchanged(before, metadata)
                process.kill()
                assert process.wait(timeout=15) == -signal.SIGKILL
                assert child.wait(timeout=15) == 0, (
                    "unacknowledged mutation did not fail"
                )
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=15)
                if child is not None:
                    if child.poll() is None:
                        child.kill()
                    child.wait(timeout=15)
                subprocess.run(
                    ["fusermount3", "-uz", str(mount)], capture_output=True, timeout=15
                )
            check_unchanged(before, metadata)
            report = run("scrub-mutable", endpoints, config, inode)
            assert report["sealed"] == (point == "seal_first_invalidated")
            assert report["sha256"] == hashlib.sha256(content).hexdigest()
            if point == "seal_invalidated":
                missing = run("repair-mutable", endpoints, config, inode, success=False)
                assert "MissingSeal" in missing.stdout + missing.stderr, missing
            with open(path, "r+b", buffering=0) as writer:
                if operation == "write":
                    assert os.pwrite(writer.fileno(), b"changed", 0) == 7
                    expected_content = b"changed" + content[7:]
                else:
                    os.ftruncate(writer.fileno(), 3)
                    expected_content = content[:3]
                os.fsync(writer.fileno())
            assert all(file.read_bytes() == expected_content for file in data)
            assert all(not (file.parent / "seal").exists() for file in data)
            report = run("seal-mutable", endpoints, config, inode)
            assert (
                report["sealed"]
                and report["sha256"] == hashlib.sha256(expected_content).hexdigest()
            )
            assert [file.stat().st_ino for file in data] == identities
            print(
                f"PASS: {operation} SIGKILL at {point}, no premature WAL/data changes, retry and reseal succeed",
                flush=True,
            )
