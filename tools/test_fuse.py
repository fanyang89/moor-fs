"""Real mount checks, invoked by test_cluster.py --fuse."""

import errno
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time


def test_mounts(
    executable,
    directory,
    endpoints,
    run,
    leader,
    stop,
    start,
    smb=False,
    write_faults=False,
    drop_publish_reply=None,
):
    processes = []
    mounts = []
    logs = []
    request_id = 1000
    config = directory / "backends.json"
    roots = [Path(item["root"]) for item in json.loads(config.read_text())]

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
                [executable, "mount", endpoints, str(path), "--backends", str(config)],
                stdout=log,
                stderr=log,
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
        expect_error(lambda: (first / "original").read_bytes(), errno.EIO)
        expect_error(lambda: (first / "photos" / names[0]).read_bytes(), errno.ENODATA)
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

        inode = apply({"create": {"parent": 1, "name": "readable", "kind": "file"}})
        content = bytes(range(256)) * 5000 + b"old-tail"
        replacement = b"new-version" * 17000
        source = directory / "fuse-source.bin"

        def publish(version, expected, data):
            source.write_bytes(data)
            result = run(
                "put-file",
                endpoints,
                config,
                json.dumps(
                    {
                        "request_id": 3000 + version,
                        "inode": inode,
                        "version_id": version,
                        "expected_version": expected,
                        "backends": [1, 2],
                    }
                ),
                source,
            )
            assert result["status"] == "ok", result

        publish(300, 0, content)
        assert (first / "readable").stat().st_size == len(content)
        assert (second / "READABLE").read_bytes() == content
        with open(first / "readable", "rb", buffering=0) as pinned:
            assert os.pread(pinned.fileno(), 180003, 262139) == content[262139:442142]
            assert os.pread(pinned.fileno(), 20, len(content) - 5) == content[-5:]
            assert os.pread(pinned.fileno(), 20, len(content)) == b""
            publish(301, 300, replacement)
            for path in mounts:
                assert (path / "readable").stat().st_size == len(replacement)
                assert (path / "readable").read_bytes() == replacement
            # New opens must not change the version or EOF of an older handle.
            assert os.pread(pinned.fileno(), 30, len(content) - 30) == content[-30:]
            assert pinned.read() == content

        object_name = f"301-{hashlib.sha256(replacement).hexdigest()}"
        copies = [root / "objects" / object_name for root in roots]
        copies[0].write_bytes(b"x" * len(replacement))
        assert (first / "readable").read_bytes() == replacement
        copies[1].write_bytes(b"y" * len(replacement))
        expect_error(lambda: (second / "readable").read_bytes(), errno.EIO)
        for copy in copies:
            copy.write_bytes(replacement)

        offline = roots[0].with_name("fuse-offline")
        roots[0].rename(offline)
        try:
            assert (second / "readable").read_bytes() == replacement
        finally:
            offline.rename(roots[0])
        with open(first / "readable", "rb", buffering=0) as pinned:
            copies[0].write_bytes(b"")
            expect_error(lambda: os.pread(pinned.fileno(), 30, 0), errno.EIO)
            result = run(
                "repair-file", endpoints, config, inode, 1, "--replace-corrupt"
            )
            assert result["status"] == "repaired", result
            assert (second / "readable").read_bytes() == replacement
            # Replacement fixes new opens, never silently swaps an existing descriptor.
            expect_error(lambda: os.pread(pinned.fileno(), 30, 0), errno.EIO)

        with open(first / "readable", "rb", buffering=0) as pinned:
            old = leader()
            stop(old)
            assert pinned.read() == replacement
            leader()
            assert (second / "readable").read_bytes() == replacement
            start(old)
            publish(302, 301, b"")
            assert (second / "readable").stat().st_size == 0
            assert (second / "readable").read_bytes() == b""
            apply({"remove": {"id": inode}})
            expect_error(lambda: (second / "readable").stat(), errno.ENOENT)
            assert os.pread(pinned.fileno(), 40, 10) == replacement[10:50]
        print(
            "PASS: FUSE sizes, offset/EOF reads, pinned versions, corruption fallback, empty files and handle lifetime after unlink",
            flush=True,
        )

        old = leader()
        stop(old)
        leader()
        assert (second / "photos" / "renamed").stat().st_ino == node
        assert len(os.listdir(first / "photos")) == 40
        start(old)
        if smb:
            from test_smb import test_exports

            test_exports(
                directory, mounts, endpoints, config, roots, run, leader, stop, start
            )
        from test_write import test_writes

        test_writes(
            executable,
            directory,
            endpoints,
            config,
            roots,
            second,
            run,
            smb,
            leader,
            stop,
            start,
        )
        if write_faults:
            from test_write_faults import test_write_faults

            test_write_faults(
                executable,
                directory,
                endpoints,
                config,
                roots,
                second,
                run,
                smb,
                leader,
                stop,
                start,
                drop_publish_reply,
            )
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
