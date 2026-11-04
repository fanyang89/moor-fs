"""Real mount checks, invoked by test_cluster.py --fuse."""

import errno
import json
import os
import subprocess
import time


def test_mounts(executable, directory, endpoints, run, leader, stop, start):
    processes = []
    mounts = []
    logs = []
    request_id = 1000

    def apply(command):
        nonlocal request_id
        request_id += 1
        result = run(
            "apply",
            endpoints,
            json.dumps({"request_id": request_id, "command": command}),
        )
        assert result["status"] == "ok", result
        return result["inode"]

    def expect_error(operation, code):
        try:
            operation()
        except OSError as error:
            assert error.errno == code, error
        else:
            raise AssertionError(f"expected errno {code}")

    try:
        folder = apply({"create": {"parent": 1, "name": "photos", "kind": "directory"}})
        for i in range(40):
            apply(
                {
                    "create": {
                        "parent": folder,
                        "name": f"{i:03d}-" + "x" * 240,
                        "kind": "file",
                    }
                }
            )
        for i in range(2):
            path = directory / f"mount-{i}"
            path.mkdir()
            mounts.append(path)
            log = open(directory / f"mount-{i}.log", "w")
            logs.append(log)
            process = subprocess.Popen(
                [executable, "mount", endpoints, str(path)], stdout=log, stderr=log
            )
            processes.append(process)
            deadline = time.monotonic() + 15
            while not os.path.ismount(path):
                assert process.poll() is None, (
                    directory / f"mount-{i}.log"
                ).read_text()
                assert time.monotonic() < deadline, "mount timed out"
                time.sleep(0.05)

        first, second = mounts
        assert (first / "photos").stat().st_ino == folder
        assert (second / "PHOTOS").stat().st_ino == folder
        assert (first / "original").stat().st_ino == 2
        names = sorted(os.listdir(first / "photos"))
        assert len(names) == 40
        assert names == sorted(os.listdir(second / "photos"))
        expect_error(lambda: (first / "missing").stat(), errno.ENOENT)
        expect_error(lambda: (first / "original").read_bytes(), errno.EOPNOTSUPP)
        expect_error(lambda: (first / "new").write_bytes(b"x"), errno.EROFS)
        expect_error(lambda: (first / "photos").mkdir(), errno.EEXIST)

        # Keep an open enumeration across a rename; its cookies and entries stay stable.
        with os.scandir(first / "photos") as iterator:
            initial = next(iterator).name
            node = run("lookup", endpoints, str(folder), names[-1])["id"]
            apply({"rename": {"id": node, "parent": folder, "name": "renamed"}})
            assert sorted([initial] + [entry.name for entry in iterator]) == names
        assert "renamed" in os.listdir(first / "photos")
        assert "renamed" in os.listdir(second / "photos")
        expect_error(lambda: (first / "photos" / names[-1]).stat(), errno.ENOENT)

        old = leader()
        stop(old)
        assert (second / "photos" / "renamed").stat().st_ino == node
        assert len(os.listdir(first / "photos")) == 40
        start(old)
        subprocess.run(["fusermount3", "-u", str(first)], check=True, timeout=10)
        assert processes[0].wait(timeout=15) == 0
        assert not os.path.ismount(first)
        print(
            "PASS: two read-only FUSE mounts, multi-page directories, stable handles, rename visibility and leader failover",
            flush=True,
        )
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
        for process in processes:
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        for path in mounts:
            if os.path.ismount(path):
                subprocess.run(["fusermount3", "-u", str(path)], check=True, timeout=10)
        for log in logs:
            log.close()
        assert all(process.returncode == 0 for process in processes), (
            "FUSE did not shut down cleanly"
        )
