#!/usr/bin/env python3
"""Exercise the standalone mutable-file store on two existing CIFS mounts."""

import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def main():
    executable, first, second = sys.argv[1:]
    roots = [Path(first), Path(second)]
    for root in roots:
        root.mkdir()
    command = [executable]

    def run(action):
        subprocess.run(command + [action, *map(str, roots)], check=True, timeout=30)

    run("create")
    inodes = [(root / "data").stat().st_ino for root in roots]
    for action in ("write", "checkpoint", "collect"):
        process = subprocess.Popen(command + [action, *map(str, roots)])
        try:
            deadline = time.monotonic() + 30
            while True:
                if process.poll() is not None:
                    raise RuntimeError(
                        f"{action} exited before checkpoint: {process.returncode}"
                    )
                status = Path(f"/proc/{process.pid}/status").read_text()
                if any(
                    line.startswith("State:") and "T" in line
                    for line in status.splitlines()
                ):
                    break
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"{action} did not stop")
                time.sleep(0.05)
            # Both NAS locks must reject another session even from a new process.
            other = subprocess.run(
                command + ["verify", *map(str, roots)], capture_output=True, timeout=30
            )
            assert other.returncode != 0 and b"FileBusy" in other.stderr, other
            os.kill(process.pid, signal.SIGKILL)
            assert process.wait(timeout=15) == -signal.SIGKILL
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=15)
        run("verify")
        assert [(root / "data").stat().st_ino for root in roots] == inodes
        if action == "collect":
            for root in roots:
                assert len(list(root.glob("wal-*"))) == 1
        print(
            f"PASS: mutable CIFS {action} SIGKILL, exclusive ownership, replay and stable data inodes",
            flush=True,
        )


if __name__ == "__main__":
    main()
