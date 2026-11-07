#!/usr/bin/env python3
"""Exercise CLI process restart and SIGKILL recovery on a temporary database."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    executable = str(
        Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/moor-fs").resolve()
    )
    with tempfile.TemporaryDirectory(prefix="moor-fs-lmdb-") as directory:

        def snapshot():
            return json.loads(
                subprocess.check_output(
                    [executable, "metadata-show", directory], text=True
                )
            )

        before = snapshot()
        killed = 0
        committed = 0
        for attempt in range(1, 65):
            index = before["index"] + 1
            request = {
                "request_id": attempt,
                "command": {
                    "create": {"parent": 1, "name": f"file-{attempt}", "kind": "file"}
                },
            }
            process = subprocess.Popen(
                [
                    executable,
                    "metadata-apply",
                    directory,
                    str(index),
                    "1",
                    json.dumps(request),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                timeout = (0, 0.001, 0.003, 0.005, 0.01, 0.02, 0.05, None)[attempt % 8]
                output, errors = process.communicate(timeout=timeout)
            except subprocess.TimeoutExpired:
                process.kill()
                output, errors = process.communicate()
                killed += 1
            after = snapshot()
            assert after["index"] in (before["index"], index), after
            if after["index"] == index:
                committed += 1
                state = after["state"]
                assert len(state["nodes"]) == len(before["state"]["nodes"]) + 1
                assert len(state["receipts"]) == len(before["state"]["receipts"]) + 1
                assert state["nodes"][-1]["name"] == f"file-{attempt}"
                assert state["receipts"][-1]["request_id"] == attempt
                assert (
                    state["receipts"][-1]["result"]["inode"] == state["nodes"][-1]["id"]
                )
                assert state["next_id"] == state["nodes"][-1]["id"] + 1
            else:
                assert after == before
            if process.returncode == 0:
                assert "status=ok" in output, (output, errors)
                assert after["index"] == index
            else:
                assert process.returncode == -9, (process.returncode, errors)
            before = after
        assert killed > 0
        assert committed > 0
        print(
            f"64 process attempts: {killed} SIGKILL attempts, {committed} recovered commits; atomicity verified"
        )


if __name__ == "__main__":
    main()
