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
nt acl support = no
""")
    processes = []
    logs = []
    client = None

    def spawn(command, name):
        log = open(state / name, "w")
        logs.append(log)
        process = subprocess.Popen(
            command, stdout=log, stderr=log, start_new_session=True
        )
        processes.append(process)
        return process

    def smb(command, success=True):
        result = subprocess.run(
            [
                "smbclient",
                "//127.0.0.1/nas",
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
            "PASS: native Samba VFS SMB3 pagination, parallel/live reads and corruption recovery without FUSE; writes/host paths rejected",
            flush=True,
        )
    except BaseException:
        for name in ("core.log", "process.log", "samba.log"):
            path = state / name
            if path.exists():
                print(f"{path}:\n{path.read_text()[-12000:]}", flush=True)
        raise
    finally:
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
