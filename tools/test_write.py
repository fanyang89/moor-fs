"""Writable FUSE and SMB checks over the cluster's configured object stores."""

import errno
import json
import os
import subprocess
import time


def test_writes(
    executable,
    directory,
    endpoints,
    config,
    roots,
    readonly,
    run,
    smb,
    leader,
    stop,
    start,
):
    mount = directory / "mount-write"
    mount.mkdir()
    log_path = directory / "mount-write.log"
    offline = roots[1].with_name("write-offline")
    overlay = directory / "write-offline-overlay"
    overlay.mkdir()
    guarded = "mount" in json.loads(config.read_text())[1]

    def hide_backend():
        if guarded:
            # CIFS can reject renaming a directory with live staging handles.
            # Cover its configured path instead; pinned handles must be rejected.
            subprocess.run(
                ["sudo", "-n", "mount", "--bind", str(overlay), str(roots[1])],
                check=True,
                timeout=15,
            )
        else:
            roots[1].rename(offline)

    def restore_backend():
        if guarded:
            subprocess.run(
                ["sudo", "-n", "umount", str(roots[1])], check=True, timeout=15
            )
        else:
            offline.rename(roots[1])

    def fails(operation, codes):
        try:
            operation()
        except OSError as error:
            assert error.errno in codes, error
        else:
            raise AssertionError("operation unexpectedly succeeded")

    with log_path.open("w") as log:
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
            ],
            stdout=log,
            stderr=log,
        )
    try:
        deadline = time.monotonic() + 15
        while not os.path.ismount(mount):
            assert process.poll() is None, log_path.read_text()
            assert time.monotonic() < deadline, "writable mount timed out"
            time.sleep(0.05)
        folder = mount / "writable"
        folder.mkdir()
        file = folder / "data.bin"
        content = bytes(range(256)) * 1300
        file.write_bytes(content)
        inode = file.stat().st_ino
        assert (readonly / "writable/data.bin").read_bytes() == content
        assert run("check-file", endpoints, config, inode)["healthy_replicas"] == 2
        with open(readonly / "writable/data.bin", "rb", buffering=0) as pinned:
            before = run("get", endpoints, inode)["current_version"]
            objects_before = [set((root / "objects").iterdir()) for root in roots]
            stages_before = [set((root / "staging").iterdir()) for root in roots]
            with open(file, "r+b", buffering=0) as writer:
                stages = [
                    (set((root / "staging").iterdir()) - stages_before[i]).pop()
                    for i, root in enumerate(roots)
                ]
                stage_inodes = [path.stat().st_ino for path in stages]
                assert os.pwrite(writer.fileno(), b"PATCH", 123) == 5
                assert os.pread(writer.fileno(), 5, 123) == b"PATCH"
                # Do not fork a CLI while this descriptor is dirty: its inherited
                # descriptor close can itself cause a FUSE flush/publication.
                assert (readonly / "writable/data.bin").read_bytes() == content
                for i, root in enumerate(roots):
                    assert set((root / "objects").iterdir()) == objects_before[i]
                    assert (
                        stages[i].read_bytes()
                        == content[:123] + b"PATCH" + content[128:]
                    )
                os.fsync(writer.fileno())
                committed = run("get", endpoints, inode)["current_version"]
                assert committed != before
                for i, root in enumerate(roots):
                    installed = set((root / "objects").iterdir()) - objects_before[i]
                    assert len(installed) == 1
                    assert installed.pop().stat().st_ino == stage_inodes[i]
                    assert not stages[i].exists()
                os.fsync(writer.fileno())
                assert run("get", endpoints, inode)["current_version"] == committed
                fails(lambda: os.open(file, os.O_WRONLY), (errno.EBUSY,))
            changed = content[:123] + b"PATCH" + content[128:]
            assert file.read_bytes() == changed
            assert pinned.read() == content
        with open(file, "r+b", buffering=0) as writer:
            os.ftruncate(writer.fileno(), 20)
        assert file.read_bytes() == changed[:20]

        session_file = folder / "session.bin"
        session_file.write_bytes(b"baseline")
        with open(session_file, "r+b", buffering=0) as writer:
            assert os.pwrite(writer.fileno(), b"ABC", 1) == 3
            assert os.pwrite(writer.fileno(), b"Z", 20) == 1
            os.ftruncate(writer.fileno(), 32)
            first_contents = b"bABCline" + b"\0" * 12 + b"Z" + b"\0" * 11
            assert os.pread(writer.fileno(), 32, 0) == first_contents
            os.fsync(writer.fileno())
            with open(readonly / "writable/session.bin", "rb", buffering=0) as pinned:
                first_objects = [set((root / "objects").iterdir()) for root in roots]
                assert os.pwrite(writer.fileno(), b"Q", 0) == 1
                os.ftruncate(writer.fileno(), 12)
                for i, root in enumerate(roots):
                    assert set((root / "objects").iterdir()) == first_objects[i]
                os.fsync(writer.fileno())
                assert pinned.read() == first_contents
                assert os.pread(writer.fileno(), 12, 0) == b"QABCline" + b"\0" * 4
        assert session_file.read_bytes() == b"QABCline" + b"\0" * 4

        # Truncating opens start empty without copying the previous contents.
        stages_before = [set((root / "staging").iterdir()) for root in roots]
        with open(session_file, "wb", buffering=0) as writer:
            for i, root in enumerate(roots):
                pending = set((root / "staging").iterdir()) - stages_before[i]
                assert len(pending) == 1 and pending.pop().stat().st_size == 0
            assert writer.write(b"truncated") == 9
        assert session_file.read_bytes() == b"truncated"

        # A changed staging replica must freeze the writer instead of publishing either copy.
        session_inode = session_file.stat().st_ino
        before = run("get", endpoints, session_inode)["current_version"]
        stages_before = [set((root / "staging").iterdir()) for root in roots]
        fd = os.open(session_file, os.O_RDWR)
        assert os.pwrite(fd, b"new", 0) == 3
        damaged = (set((roots[1] / "staging").iterdir()) - stages_before[1]).pop()
        damaged.write_bytes(b"corrupted")
        fails(lambda: os.fsync(fd), (errno.EIO,))
        fails(lambda: os.pwrite(fd, b"retry", 0), (errno.EIO,))
        fails(lambda: os.close(fd), (errno.EIO,))
        assert run("get", endpoints, session_inode)["current_version"] == before
        assert session_file.read_bytes() == b"truncated"
        for i, root in enumerate(roots):
            assert set((root / "staging").iterdir()) == stages_before[i]
        fd = os.open(session_file, os.O_RDWR | os.O_DSYNC)
        try:
            assert os.pwrite(fd, b"S", 0) == 1
            assert (readonly / "writable/session.bin").read_bytes() == b"Sruncated"
        finally:
            os.close(fd)
        session_file.unlink()

        file.write_bytes(b"replacement")
        assert file.read_bytes() == b"replacement"

        # A known second-store failure must never publish the staged modification.
        before = run("get", endpoints, inode)["current_version"]
        fd = os.open(file, os.O_RDWR)
        hide_backend()
        try:
            fails(lambda: os.pwrite(fd, b"FAIL", 0), (errno.EIO,))
            fails(lambda: os.fsync(fd), (errno.EIO,))
            assert run("get", endpoints, inode)["current_version"] == before
            assert (readonly / "writable/data.bin").read_bytes() == b"replacement"
        finally:
            restore_backend()
            fails(lambda: os.close(fd), (errno.EIO,))
        assert file.read_bytes() == b"replacement"

        # An external publication makes this writer's CAS stale, never overwrites it.
        fd = os.open(file, os.O_RDWR)
        source = directory / "write-race-source"
        source.write_bytes(b"external")
        try:
            result = run(
                "put-file",
                endpoints,
                config,
                json.dumps(
                    {
                        "request_id": 9100,
                        "inode": inode,
                        "version_id": 9100,
                        "expected_version": before,
                        "backends": [1, 2],
                    }
                ),
                source,
            )
            assert result["status"] == "ok", result
            assert os.pwrite(fd, b"stale", 0) == 5
            fails(lambda: os.fsync(fd), (errno.EAGAIN,))
            fails(lambda: os.pwrite(fd, b"again", 0), (errno.EAGAIN,))
        finally:
            fails(lambda: os.close(fd), (errno.EAGAIN,))
        assert file.read_bytes() == b"external"
        (folder / "target").mkdir()
        renamed = folder / "target/renamed.bin"
        file.rename(renamed)
        collision = folder / "occupied.bin"
        collision.write_bytes(b"keep")
        fails(lambda: renamed.rename(collision), (errno.EEXIST,))
        assert collision.read_bytes() == b"keep" and renamed.read_bytes() == b"external"
        collision.unlink()
        with open(renamed, "rb", buffering=0) as pinned:
            renamed.unlink()
            assert pinned.read() == b"external"
        (folder / "target").rmdir()
        (folder / "child").mkdir()
        fails(lambda: folder.rmdir(), (errno.ENOTEMPTY,))
        (folder / "child").rmdir()
        folder.rmdir()
        assert not (readonly / "writable").exists()
        print(
            "PASS: writable FUSE dual-replica commits, offset/truncate, pinned readers, failed replica, CAS conflict and namespace operations",
            flush=True,
        )

        if smb:
            from serve_smb import export

            with export(mount, directory / "smb-write", writable=True) as (_, port):

                def client(command, success=True):
                    print(f"SMB write test: {command}", flush=True)
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
                    output = result.stdout + result.stderr
                    if success:
                        assert result.returncode == 0 and "NT_STATUS_" not in output, (
                            output
                        )
                    else:
                        assert result.returncode != 0 or "NT_STATUS_" in output, output
                    return output

                source.write_bytes(content)
                client("mkdir smb-write-files")
                client(f'put "{source}" "smb-write-files/data.bin"')
                target = readonly / "smb-write-files/data.bin"
                assert target.read_bytes() == content
                smb_inode = target.stat().st_ino
                assert (
                    run("check-file", endpoints, config, smb_inode)["healthy_replicas"]
                    == 2
                )
                source.write_bytes(b"SMB replacement")
                client(f'put "{source}" "smb-write-files/data.bin"')
                assert target.read_bytes() == b"SMB replacement"
                before_smb = run("get", endpoints, smb_inode)["current_version"]
                hide_backend()
                try:
                    client(f'put "{source}" "smb-write-files/data.bin"', success=False)
                    assert (
                        run("get", endpoints, smb_inode)["current_version"]
                        == before_smb
                    )
                    assert target.read_bytes() == b"SMB replacement"
                finally:
                    restore_backend()
                old = leader()
                stop(old)
                try:
                    leader()
                    source.write_bytes(b"after election")
                    client(f'put "{source}" "smb-write-files/data.bin"')
                    assert target.read_bytes() == b"after election"
                finally:
                    start(old)
                client('rename "smb-write-files/data.bin" "smb-write-files/moved.bin"')
                download = directory / "smb-written-download"
                client(f'get "smb-write-files/moved.bin" "{download}"')
                assert download.read_bytes() == b"after election"
                client('rmdir "smb-write-files"', success=False)
                client('del "smb-write-files/moved.bin"')
                source.write_bytes(b"")
                client(f'put "{source}" "smb-write-files/empty.bin"')
                assert (readonly / "smb-write-files/empty.bin").read_bytes() == b""
                hide_backend()
                try:
                    client(
                        f'put "{source}" "smb-write-files/failed.bin"', success=False
                    )
                finally:
                    restore_backend()
                # Failed create may leave an unpublished inode; it is not readable empty data.
                failed = readonly / "smb-write-files/failed.bin"
                if failed.exists():
                    fails(lambda: failed.read_bytes(), (errno.ENODATA,))
                    client('del "smb-write-files/failed.bin"')
                client('del "smb-write-files/empty.bin"; rmdir "smb-write-files"')
                print(
                    "PASS: SMB create/upload/overwrite/download/rename/delete/mkdir/rmdir, empty files and second-replica failure",
                    flush=True,
                )
        subprocess.run(["fusermount3", "-u", str(mount)], check=True, timeout=10)
        assert process.wait(timeout=15) == 0
    finally:
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        if os.path.ismount(mount):
            subprocess.run(["fusermount3", "-u", str(mount)], check=True, timeout=10)
        if process.returncode:
            print(log_path.read_text(), flush=True)
