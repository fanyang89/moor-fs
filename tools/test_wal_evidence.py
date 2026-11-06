"""Dirty-data corruption must not be served or retire its recovery evidence."""

import os
import signal
import subprocess
import sys

from test_mutable_repair_faults import wait_stopped


def test_wal_evidence(directory, endpoints, inode, path, data, run):
    expected = b"abXY" + b"\0" * 8 + b"tail"

    def evidence():
        return [
            {
                file.name: file.read_bytes()
                for file in target.parent.iterdir()
                if file.name != "data"
            }
            for target in data
        ]

    cases = [
        (operation, damage)
        for operation in ("fsync", "read")
        for damage in ("payload", "gap", "size", "short", "wal-tail")
    ]
    cases += [("stat", damage) for damage in ("size", "short", "wal-tail")]
    for operation, damage in cases:
        log = directory / f"wal-evidence-{operation}-{damage}.log"
        with log.open("w") as output:
            child = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    """
import errno, os, signal, sys
fd = os.open(sys.argv[1], os.O_RDWR)
os.ftruncate(fd, 0)
assert os.pwrite(fd, b'abcdefgh', 0) == 8
assert os.pwrite(fd, b'XYZ', 2) == 3
os.ftruncate(fd, 4)
os.ftruncate(fd, 16)
assert os.pwrite(fd, b'tail', 12) == 4
assert os.pread(fd, 4, 0) == b'abXY'
os.kill(os.getpid(), signal.SIGSTOP)
try:
    if sys.argv[2] == 'fsync':
        os.fsync(fd)
    elif sys.argv[2] == 'stat':
        os.fstat(fd)
    else:
        print(repr(os.pread(fd, 4, 8 if sys.argv[3] in ('gap', 'short') else 0)), flush=True)
except OSError as exc:
    print(repr(exc), flush=True)
    os._exit(0 if exc.errno == errno.EIO else 2)
os._exit(1)
""",
                    str(path),
                    operation,
                    damage,
                ],
                stdout=output,
                stderr=output,
            )
        try:
            wait_stopped(child, "dirty write acknowledged", log)
            metadata = run("get", endpoints, inode)
            assert all(file.read_bytes() == expected for file in data)
            for file in data:
                if damage == "wal-tail":
                    log_file = max(
                        file.parent.glob("wal-*"), key=lambda item: int(item.name[4:])
                    )
                    with open(log_file, "ab", buffering=0) as corrupt:
                        corrupt.write(b"torn")
                        os.fsync(corrupt.fileno())
                    continue
                with open(file, "r+b", buffering=0) as corrupt:
                    if damage == "short":
                        corrupt.truncate(5)
                    else:
                        corrupt.seek({"payload": 2, "gap": 8, "size": 16}[damage])
                        corrupt.write(b"Q")
                    os.fsync(corrupt.fileno())
            before = evidence()
            child.send_signal(signal.SIGCONT)
            assert child.wait(timeout=30) == 0, (
                f"{operation} accepted {damage} corruption: {log.read_text()}"
            )
            assert evidence() == before, (
                "failed checkpoint modified or collected redo evidence"
            )
            assert run("get", endpoints, inode) == metadata
            assert path.read_bytes() == expected
            assert all(file.read_bytes() == expected for file in data)
            assert run("get", endpoints, inode)["mutable_file"]["size"] == len(expected)
            print(
                f"PASS: identical dirty {damage} corruption fails {operation}, retains WAL/metadata and replays on reopen",
                flush=True,
            )
        finally:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=15)
