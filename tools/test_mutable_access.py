"""Guarded mutable-file migration/recovery with live metadata and real backends."""

import json
from pathlib import Path
import signal
import subprocess
import time


def test_mutable_access(executable, directory, endpoints, run, leader, stop, start):
    config = directory / "backends.json"
    mappings = json.loads(config.read_text())
    roots = [Path(mapping["root"]) for mapping in mappings]
    source = directory / "mutable-source"
    source.write_bytes(b"baseline")
    inode = run(
        "apply",
        endpoints,
        json.dumps(
            {
                "request_id": 30000,
                "command": {
                    "create": {
                        "parent": 1,
                        "name": "mutable-access",
                        "kind": "file",
                    }
                },
            }
        ),
    )["inode"]
    assert (
        run(
            "put-file",
            endpoints,
            config,
            json.dumps(
                {
                    "request_id": 30001,
                    "inode": inode,
                    "version_id": 30001,
                    "expected_version": 0,
                    "backends": [1, 2],
                }
            ),
            source,
        )["status"]
        == "ok"
    )
    before = [set((root / "objects").iterdir()) for root in roots]
    command = [executable, endpoints, str(config), str(inode)]

    def invoke(action):
        subprocess.run(command + [action], check=True, timeout=60)

    invoke("migrate")
    bound = run("get", endpoints, inode)["mutable_file"]
    leaves = [root / "mutable" / f"{inode}-{bound['generation']}" for root in roots]
    inodes = [(leaf / "data").stat().st_ino for leaf in leaves]
    for action in ("write", "checkpoint", "collect"):
        process = subprocess.Popen(command + [action])
        try:
            deadline = time.monotonic() + 60
            while True:
                if process.poll() is not None:
                    raise RuntimeError(
                        f"mutable {action} exited before checkpoint: {process.returncode}"
                    )
                status = Path(f"/proc/{process.pid}/status").read_text()
                if any(
                    line.startswith("State:") and "T" in line
                    for line in status.splitlines()
                ):
                    break
                if time.monotonic() >= deadline:
                    raise TimeoutError("mutable access did not stop")
                time.sleep(0.05)
            other = subprocess.run(
                command + ["verify"], capture_output=True, timeout=30
            )
            assert other.returncode != 0 and b"FileBusy" in other.stderr, other
            if action == "write":
                old = leader()
                stop(old)
                assert leader() != old
                start(old)
            process.kill()
            assert process.wait(timeout=15) == -signal.SIGKILL
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=15)
        invoke("verify")
        current = run("get", endpoints, inode)
        assert current["current_version"] == 0
        assert current["mutable_file"]["size"] == 8
        assert current["mutable_file"]["generation"] == bound["generation"]
        for i, leaf in enumerate(leaves):
            assert (leaf / "data").read_bytes() == b"baseXYne"
            assert (leaf / "data").stat().st_ino == inodes[i]
            assert set((roots[i] / "objects").iterdir()) == before[i]
            if action == "collect":
                assert len(list(leaf.glob("wal-*"))) == 1
        print(
            f"PASS: mutable access {action} SIGKILL, RPC reconciliation, ownership and retained immutable objects",
            flush=True,
        )
