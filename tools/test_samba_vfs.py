"""Read-only SMB3 against the native opaque VFS, without a FUSE mount."""

import os
import json
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import pwd
import signal
import socket
import subprocess
import time
import sys
import select
import errno

from test_file_ipc import Client

ROOT = Path(__file__).resolve().parent.parent


def test_samba_vfs(executable, directory, endpoints):
    runtime = directory / "vfs-core"
    state = directory / "vfs-samba"
    state.mkdir()
    for name in ("private", "state", "cache", "lock", "run", "ncalrpc"):
        (state / name).mkdir()
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    user = pwd.getpwuid(os.getuid()).pw_name
    config = state / "smb.conf"
    config.write_text(f"""[global]
server role = standalone server
workgroup = WORKGROUP
netbios name = NASFSVFS
interfaces = 127.0.0.1
bind interfaces only = yes
smb ports = {port}
disable netbios = yes
server min protocol = SMB3
map to guest = Bad User
guest account = {user}
private dir = {state}/private
state directory = {state}/state
cache directory = {state}/cache
lock directory = {state}/lock
pid directory = {state}/run
ncalrpc dir = {state}/ncalrpc
log file = {state}/samba.log
log level = 3
load printers = no
printing = bsd
printcap name = /dev/null
smb2 leases = no
[nas]
path = /
vfs objects = nas_fs
nas_fs:socket = {runtime}/core.sock
read only = yes
guest ok = yes
guest only = yes
follow symlinks = no
oplocks = no
level2 oplocks = no
kernel oplocks = no
kernel share modes = no
use sendfile = no
map archive = no
store dos attributes = no
strict sync = yes
nt acl support = no
[write]
copy = nas
read only = no
[sync]
copy = write
sync always = yes
""")
    processes = []
    logs = []
    client = None
    workers = []

    def worker(url):
        process = subprocess.Popen(
            [sys.executable, str(ROOT / "tools/smb_vfs_client.py"), url],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        )
        workers.append(process)
        return process

    def call(process, op, error=0, **fields):
        process.stdin.write(json.dumps({"op": op, **fields}) + "\n")
        process.stdin.flush()
        assert select.select([process.stdout], [], [], 25)[0], "SMB worker timed out"
        result = json.loads(process.stdout.readline())
        assert result["errno"] == error, (op, result)
        return result

    def spawn(command, name):
        log = open(state / name, "w")
        logs.append(log)
        process = subprocess.Popen(
            command, stdout=log, stderr=log, start_new_session=True
        )
        processes.append(process)
        return process

    def smb(command, success=True, share="nas"):
        result = subprocess.run(
            [
                "smbclient",
                f"//127.0.0.1/{share}",
                "-p",
                str(port),
                "-N",
                "-m",
                "SMB3",
                "-c",
                command,
            ],
            capture_output=True,
            text=True,
            timeout=40,
        )
        if success:
            assert result.returncode == 0, result.stdout + result.stderr
        else:
            # smbclient's mkdir command reports server errors but exits zero.
            assert "NT_STATUS_" in result.stdout + result.stderr, result
        return result.stdout + result.stderr

    try:
        core = spawn(
            [
                executable,
                "serve-files",
                endpoints,
                str(directory / "backends.json"),
                str(runtime),
                "1",
                "2",
            ],
            "core.log",
        )
        deadline = time.monotonic() + 15
        while not (runtime / "core.sock").exists():
            assert core.poll() is None, (state / "core.log").read_text()
            assert time.monotonic() < deadline
            time.sleep(0.02)
        client = Client(runtime / "core.sock")
        parent = client.change(
            51000, {"create": {"parent": 1, "name": "vfs-read", "kind": "directory"}}
        )
        file = client.change(
            51001, {"create": {"parent": parent, "name": "binary.dat", "kind": "file"}}
        )
        for index in range(18):
            client.change(
                51100 + index,
                {
                    "create": {
                        "parent": parent,
                        "name": f"empty-{index:02}",
                        "kind": "file",
                    }
                },
            )
        handle = client.call({"open": {"inode": file, "writable": True}})["handle"]
        data = bytes(range(256)) * 1024 + b"tail"
        for offset in range(0, len(data), 65536):
            client.call(
                {
                    "write": {
                        "handle": handle,
                        "offset": offset,
                        "hex": data[offset : offset + 65536].hex(),
                    }
                }
            )
        # Keep the dirty writer alive while independent smbd processes read it.
        daemon = spawn(
            [
                str(ROOT / "third_party/samba/bin/smbd"),
                "--foreground",
                "--no-process-group",
                "--debug-stdout",
                "--configfile",
                str(config),
            ],
            "process.log",
        )
        deadline = time.monotonic() + 15
        while True:
            assert daemon.poll() is None, (state / "process.log").read_text()
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                    break
            except OSError:
                assert time.monotonic() < deadline
                time.sleep(0.05)
        listing = smb("cd vfs-read; ls")
        assert "binary.dat" in listing and "empty-17" in listing, listing
        destination = directory / "vfs-download"
        smb(f"get vfs-read/binary.dat {destination}")
        assert destination.read_bytes() == data

        # Two separate smbd children share the resident core's existing session.
        def download(index):
            output = directory / f"vfs-parallel-{index}"
            smb(f"get VFS-READ/BINARY.DAT {output}")
            assert output.read_bytes() == data

        with ThreadPoolExecutor(max_workers=2) as pool:
            list(pool.map(download, range(2)))
        client.call({"write": {"handle": handle, "offset": 0, "hex": b"LIVE".hex()}})
        data = b"LIVE" + data[4:]
        smb(f"get vfs-read/binary.dat {destination}")
        assert destination.read_bytes() == data
        # The host root must never leak through the virtual root.
        smb("get etc/passwd " + str(directory / "must-not-exist"), success=False)
        assert not (directory / "must-not-exist").exists()
        assert "NT_STATUS_ACCESS_DENIED" in smb("mkdir forbidden", success=False)
        client.call({"lookup": {"parent": 1, "name": "forbidden"}}, error="NotFound")
        url = f"smb://127.0.0.1:{port}/write/vfs-read/upload.dat"
        writer = worker(url)
        call(writer, "open", flags=os.O_RDWR | os.O_CREAT | os.O_EXCL)
        upload = client.call({"lookup": {"parent": parent, "name": "upload.dat"}})[
            "attributes"
        ]["node"]["id"]
        payload = bytes(range(256)) * 600 + b"write-tail"
        assert call(writer, "write", offset=0, hex=payload.hex())["value"] == len(
            payload
        )
        reader = worker(url)
        call(reader, "open", flags=os.O_RDONLY)
        assert (
            bytes.fromhex(call(reader, "read", offset=0, length=len(payload))["hex"])
            == payload
        )
        contender = worker(url)
        # Samba maps the backend EBUSY open failure to ACCESS_DENIED.
        call(contender, "open", flags=os.O_WRONLY, error=errno.EACCES)
        client.call({"open": {"inode": upload, "writable": True}}, error="FileBusy")
        call(
            contender,
            "open",
            flags=os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            error=errno.EEXIST,
        )
        call(writer, "truncate", length=3)
        assert (
            bytes.fromhex(call(reader, "read", offset=0, length=10)["hex"])
            == payload[:3]
        )
        assert call(writer, "write", offset=4096, hex="ff")["value"] == 1
        assert (
            bytes.fromhex(call(reader, "read", offset=3, length=4094)["hex"])
            == b"\0" * 4093 + b"\xff"
        )
        call(writer, "close")
        checkpoint = client.call({"stat": {"inode": upload}})["attributes"]["node"][
            "mutable_file"
        ]
        assert checkpoint["size"] == 4097
        call(contender, "open", flags=os.O_RDWR | os.O_TRUNC)
        assert call(reader, "read", offset=0, length=10)["hex"] == ""
        call(contender, "close")
        synced = worker(url.replace("/write/", "/sync/"))
        call(synced, "open", flags=os.O_RDWR)
        assert call(synced, "write", offset=0, hex=b"synced".hex())["value"] == 6
        checkpoint = client.call({"stat": {"inode": upload}})["attributes"]["node"][
            "mutable_file"
        ]
        assert checkpoint["size"] == 6, checkpoint
        call(synced, "close")
        call(reader, "close")
        smb(f"get vfs-read/upload.dat {directory / 'vfs-written-download'}")
        assert (directory / "vfs-written-download").read_bytes() == b"synced"
        source = directory / "vfs-upload-source"
        source.write_bytes(payload)
        smb(f"put {source} vfs-read/put.dat", share="write")
        source.write_bytes(b"short")
        smb(f"put {source} vfs-read/put.dat", share="write")
        smb(f"get vfs-read/put.dat {directory / 'vfs-put-download'}")
        assert (directory / "vfs-put-download").read_bytes() == b"short"
        smb("mkdir vfs-read/namespace", share="write")
        folder = client.call({"lookup": {"parent": parent, "name": "namespace"}})[
            "attributes"
        ]["node"]["id"]
        smb(f"put {source} vfs-read/namespace/first.dat", share="write")
        original = client.call({"lookup": {"parent": folder, "name": "first.dat"}})[
            "attributes"
        ]["node"]["id"]
        smb("rmdir vfs-read/namespace", share="write", success=False)
        active = client.call({"open": {"inode": original, "writable": False}})["handle"]
        smb("rename vfs-read/namespace/first.dat vfs-read/moved.dat", share="write")
        client.call(
            {"lookup": {"parent": folder, "name": "first.dat"}}, error="NotFound"
        )
        assert (
            client.call({"lookup": {"parent": parent, "name": "moved.dat"}})[
                "attributes"
            ]["node"]["id"]
            == original
        )
        smb("rename vfs-read/moved.dat vfs-read/put.dat", share="write", success=False)
        smb(f"get vfs-read/moved.dat {directory / 'vfs-renamed'}")
        assert (directory / "vfs-renamed").read_bytes() == b"short"
        assert (
            client.call({"read": {"handle": active, "offset": 0, "length": 5}})["hex"]
            == b"short".hex()
        )
        smb("del vfs-read/moved.dat", share="write", success=False)
        assert (
            client.call({"lookup": {"parent": parent, "name": "moved.dat"}})[
                "attributes"
            ]["node"]["id"]
            == original
        )
        client.call({"close": {"handle": active}})
        smb("rename vfs-read/namespace vfs-read/renamed-dir", share="write")
        assert (
            client.call({"lookup": {"parent": parent, "name": "renamed-dir"}})[
                "attributes"
            ]["node"]["id"]
            == folder
        )
        smb("mkdir vfs-read/renamed-dir/child", share="write")
        smb(
            "rename vfs-read/renamed-dir vfs-read/renamed-dir/child/cycle",
            share="write",
            success=False,
        )
        smb("rmdir vfs-read/renamed-dir/child", share="write")
        smb("del vfs-read/moved.dat", share="write")
        client.call(
            {"lookup": {"parent": parent, "name": "moved.dat"}}, error="NotFound"
        )
        smb("rmdir vfs-read/renamed-dir", share="write")
        client.call(
            {"lookup": {"parent": parent, "name": "renamed-dir"}}, error="NotFound"
        )
        # Damage bytes covered by pending WAL, so close must reject checkpointing.
        call(writer, "open", flags=os.O_RDWR)
        call(writer, "write", offset=0, hex=b"repair".hex())
        node = client.call({"stat": {"inode": upload}})["attributes"]["node"]
        mapping = json.loads((directory / "backends.json").read_text())[1]
        replica = (
            Path(mapping["root"])
            / "mutable"
            / f"{upload}-{node['mutable_file']['generation']}"
            / "data"
        )
        with open(replica, "r+b", buffering=0) as damaged:
            damaged.write(b"!")
        # libsmbclient maps SMB IO_DEVICE_ERROR on close to EINVAL.
        call(writer, "close", error=errno.EINVAL)
        assert "NT_STATUS_IO_DEVICE_ERROR" in (state / "process.log").read_text()
        smb(f"get vfs-read/upload.dat {directory / 'vfs-close-recovered'}")
        assert (directory / "vfs-close-recovered").read_bytes() == b"repair"
        assert client.call({"stat": {"inode": file}})["attributes"]["size"] == len(data)
        node = client.call({"stat": {"inode": file}})["attributes"]["node"]
        mapping = json.loads((directory / "backends.json").read_text())[1]
        replica = (
            Path(mapping["root"])
            / "mutable"
            / f"{file}-{node['mutable_file']['generation']}"
            / "data"
        )
        with open(replica, "r+b", buffering=0) as damaged:
            damaged.write(b"!")
        rejected = smb(
            f"get vfs-read/binary.dat {directory / 'vfs-corrupt'}", success=False
        )
        assert "NT_STATUS_" in rejected
        client.call({"close": {"handle": handle}}, error="WalSessionFailed")
        # Reopen recovers the acknowledged WAL after every failed handle closes.
        smb(f"get vfs-read/binary.dat {destination}")
        assert destination.read_bytes() == data
        print(
            "PASS: native Samba VFS SMB3 reads, create/write/truncate, writer exclusion, sync/close checkpoints and corruption/close-error recovery without FUSE; host paths rejected",
            flush=True,
        )
    except BaseException:
        for name in ("core.log", "process.log", "samba.log"):
            path = state / name
            if path.exists():
                print(f"{path}:\n{path.read_text()[-12000:]}", flush=True)
        raise
    finally:
        for process in workers:
            if process.poll() is None:
                process.stdin.close()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            process.stdout.close()
        if client:
            client.close()
        for process in reversed(processes):
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
        for log in logs:
            log.close()
    process_log = (state / "process.log").read_text()
    assert "PANIC" not in process_log and "INTERNAL ERROR" not in process_log, (
        process_log[-12000:]
    )
