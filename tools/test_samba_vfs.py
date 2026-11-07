"""SMB3 against the native opaque VFS, without a FUSE mount."""

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
import calendar

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
[deadline]
copy = nas
nas_fs:timeout_ms = 500
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
        assert result["errno"] in (error if isinstance(error, tuple) else (error,)), (
            op,
            result,
        )
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
            env={**os.environ, "TZ": "UTC", "LC_ALL": "C"},
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
        write_started = time.time_ns()
        smb(f"put {source} vfs-read/times.dat", share="write")
        timed_inode = client.call({"lookup": {"parent": parent, "name": "times.dat"}})[
            "attributes"
        ]["node"]["id"]

        def current_times():
            return client.call({"stat": {"inode": timed_inode}})["attributes"]["node"][
                "times"
            ]

        created_time = current_times()["birthtime"]
        created_ns = created_time["seconds"] * 1000000000 + created_time["nanoseconds"]
        assert write_started <= created_ns <= time.time_ns()

        def assert_modified_since(started):
            times = current_times()
            modified = times["mtime"]
            nanos = modified["seconds"] * 1000000000 + modified["nanoseconds"]
            assert started <= nanos <= time.time_ns(), times
            assert times["ctime"] == modified
            assert times["atime"] == times["birthtime"] == created_time
            return times

        assert_modified_since(write_started)
        directory_started = time.time_ns()
        smb("mkdir vfs-read/clock-dir", share="write")
        created_directory = client.call(
            {"lookup": {"parent": parent, "name": "clock-dir"}}
        )["attributes"]["node"]
        directory_times = created_directory["times"]
        directory_time = directory_times["birthtime"]
        assert all(value == directory_time for value in directory_times.values())
        assert (
            directory_started
            <= directory_time["seconds"] * 1000000000 + directory_time["nanoseconds"]
            <= time.time_ns()
        )
        timed_writer = worker(url.replace("upload.dat", "times.dat"))
        call(timed_writer, "open", flags=os.O_RDWR)
        write_started = time.time_ns()
        call(timed_writer, "write", offset=0, hex=b"clock".hex())
        assert_modified_since(write_started)
        truncate_started = time.time_ns()
        call(timed_writer, "truncate", length=2)
        assert_modified_since(truncate_started)
        before_read = current_times()
        read_started = time.time_ns()
        smb(f"get vfs-read/times.dat {directory / 'vfs-times-download'}")
        assert (directory / "vfs-times-download").read_bytes() == b"cl"
        accessed_node = client.call({"stat": {"inode": timed_inode}})["attributes"][
            "node"
        ]
        accessed_time = accessed_node["times"]["atime"]
        assert (
            read_started
            <= accessed_time["seconds"] * 1000000000 + accessed_time["nanoseconds"]
            <= time.time_ns()
        )
        assert accessed_node["access"]["sequence"] == 1
        for field in ("mtime", "ctime", "birthtime"):
            assert accessed_node["times"][field] == before_read[field]
        accessed_request = {
            "request_id": 0,
            "command": {
                "touch_accessed": {
                    "inode": timed_inode,
                    "access": accessed_node["access"],
                }
            },
        }

        def replay_accessed():
            result = subprocess.run(
                [executable, "apply", endpoints, json.dumps(accessed_request)],
                capture_output=True,
                text=True,
                timeout=20,
            )
            assert result.returncode == 0, result.stdout + result.stderr
            assert json.loads(result.stdout) == {"status": "ok", "inode": timed_inode}

        modified_node = client.call({"stat": {"inode": timed_inode}})["attributes"][
            "node"
        ]
        modified_request = {
            "request_id": 0,
            "command": {
                "touch_modified": {
                    "inode": timed_inode,
                    "modification": modified_node["modification"],
                }
            },
        }

        def replay_modified():
            result = subprocess.run(
                [executable, "apply", endpoints, json.dumps(modified_request)],
                capture_output=True,
                text=True,
                timeout=20,
            )
            assert result.returncode == 0, result.stdout + result.stderr
            assert json.loads(result.stdout) == {"status": "ok", "inode": timed_inode}

        dates = (
            "20:01:02-03:04:05 21:01:02-03:04:05 22:01:02-03:04:05 23:01:02-03:04:05"
        )
        smb(f"utimes vfs-read/times.dat {dates}", share="write")
        # A later explicit timestamp must survive the writer's close checkpoint.
        call(timed_writer, "close")
        replay_modified()
        replay_accessed()
        expected_times = {
            field: {"seconds": calendar.timegm((year, 1, 2, 3, 4, 5)), "nanoseconds": 0}
            for field, year in (
                ("birthtime", 2020),
                ("atime", 2021),
                ("mtime", 2022),
                ("ctime", 2023),
            )
        }
        assert (
            client.call({"stat": {"inode": timed_inode}})["attributes"]["node"]["times"]
            == expected_times
        )
        smb("utimes vfs-read/times.dat -1 -1 19:01:02-03:04:05 -1", share="write")
        expected_times["mtime"]["seconds"] = calendar.timegm((2019, 1, 2, 3, 4, 5))
        assert (
            client.call({"stat": {"inode": timed_inode}})["attributes"]["node"]["times"]
            == expected_times
        )
        smb(f"utimes vfs-read {dates}", share="write")
        assert (
            client.call({"stat": {"inode": parent}})["attributes"]["node"]["times"][
                "birthtime"
            ]
            == expected_times["birthtime"]
        )
        assert "NT_STATUS_ACCESS_DENIED" in smb(
            f"utimes vfs-read/times.dat {dates}", success=False
        )

        def time_lines():
            result = smb("allinfo vfs-read/times.dat")
            return [
                line
                for line in result.splitlines()
                if line.startswith(
                    ("create_time:", "access_time:", "write_time:", "change_time:")
                )
            ]

        saved_times = time_lines()
        assert len(saved_times) == 4
        for line, year in zip(saved_times, (2020, 2021, 2019, 2023)):
            assert str(year) in line and "03:04:05" in line, line

        # Namespace effects must be atomic with the operation, while preserving
        # file data times and directory access/birth times.
        def lookup_node(directory_inode, name):
            return client.call({"lookup": {"parent": directory_inode, "name": name}})[
                "attributes"
            ]["node"]

        def inode_times(inode):
            return client.call({"stat": {"inode": inode}})["attributes"]["node"][
                "times"
            ]

        def changed_in_window(value, started):
            assert (
                started
                <= value["seconds"] * 1000000000 + value["nanoseconds"]
                <= time.time_ns()
            )

        def parent_changed(node, started):
            times = inode_times(node["id"])
            changed_in_window(times["mtime"], started)
            assert times["mtime"] == times["ctime"]
            for field in ("atime", "birthtime"):
                assert times[field] == node["times"][field]
            return times

        smb("mkdir vfs-read/time-parent; mkdir vfs-read/time-dest", share="write")
        time_parent = lookup_node(parent, "time-parent")
        time_dest = lookup_node(parent, "time-dest")
        started = time.time_ns()
        smb(f"put {source} vfs-read/time-parent/item.dat", share="write")
        parent_changed(time_parent, started)
        item = lookup_node(time_parent["id"], "item.dat")
        started = time.time_ns()
        smb(
            "rename vfs-read/time-parent/item.dat vfs-read/time-dest/item.dat",
            share="write",
        )
        parent_changed(time_parent, started)
        parent_changed(time_dest, started)
        renamed = lookup_node(time_dest["id"], "item.dat")
        assert renamed["id"] == item["id"]
        changed_in_window(renamed["times"]["ctime"], started)
        for field in ("atime", "mtime", "birthtime"):
            assert renamed["times"][field] == item["times"][field]
        started = time.time_ns()
        smb(
            "rename vfs-read/time-dest/item.dat vfs-read/time-dest/ITEM.dat",
            share="write",
        )
        parent_changed(time_dest, started)
        renamed = lookup_node(time_dest["id"], "ITEM.dat")
        assert renamed["name"] == "ITEM.dat"
        changed_in_window(renamed["times"]["ctime"], started)
        smb(f"put {source} vfs-read/time-dest/exists.dat", share="write")
        before_failed = inode_times(time_dest["id"])
        before_file = inode_times(item["id"])
        smb(
            "rename vfs-read/time-dest/ITEM.dat vfs-read/time-dest/exists.dat",
            share="write",
            success=False,
        )
        assert inode_times(time_dest["id"]) == before_failed
        assert inode_times(item["id"]) == before_file
        started = time.time_ns()
        smb("del vfs-read/time-dest/ITEM.dat", share="write")
        parent_changed(time_dest, started)
        namespace_saved_times = {
            node["id"]: inode_times(node["id"]) for node in (time_parent, time_dest)
        }
        race = [
            worker(url.replace("upload.dat", "exclusive-race.dat")) for _ in range(2)
        ]
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(
                pool.map(
                    lambda process: call(
                        process,
                        "open",
                        error=(0, errno.EEXIST),
                        flags=os.O_RDWR | os.O_CREAT | os.O_EXCL,
                    ),
                    race,
                )
            )
        assert sorted(result["errno"] for result in results) == [0, errno.EEXIST]
        winner = next(
            process for process, result in zip(race, results) if result["errno"] == 0
        )
        loser = next(
            process for process, result in zip(race, results) if result["errno"] != 0
        )
        call(loser, "open", flags=os.O_WRONLY, error=errno.EACCES)
        call(winner, "write", offset=0, hex=b"won".hex())
        call(winner, "close")
        call(loser, "open", flags=os.O_RDONLY)
        assert call(loser, "read", offset=0, length=3)["hex"] == b"won".hex()
        call(loser, "close")
        combined_request = {
            "create_open": {
                "request_id": 51400,
                "parent": parent,
                "name": "combined.dat",
                "ancestors": [{"inode": parent, "parent": 1, "name": "vfs-read"}],
                "writable": True,
            }
        }
        combined = client.call(combined_request)
        assert combined["change"]["status"] == "ok" and combined["size"] == 0
        client.call(combined_request, error="FileBusy")
        client.call(
            {"write": {"handle": combined["handle"], "offset": 0, "hex": b"kept".hex()}}
        )
        client.call({"close": {"handle": combined["handle"]}})
        replay = client.call(combined_request)
        assert (
            replay["change"] == combined["change"]
            and replay["handle"] != combined["handle"]
            and replay["size"] == 4
        )
        client.call({"close": {"handle": replay["handle"]}})
        smb(f"get vfs-read/combined.dat {directory / 'vfs-combined'}")
        assert (directory / "vfs-combined").read_bytes() == b"kept"
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
        stale = {"inode": original, "parent": folder, "name": "first.dat"}
        client.change(
            51200,
            {
                "rename_checked": {
                    "source": stale,
                    "parent": parent,
                    "name": "wrong.dat",
                }
            },
            status="entry_conflict",
        )
        client.change(51201, {"remove_checked": stale}, status="entry_conflict")
        smb(f"put {source} vfs-read/namespace/first.dat", share="write")
        replacement = client.call({"lookup": {"parent": folder, "name": "first.dat"}})[
            "attributes"
        ]["node"]["id"]
        assert replacement != original
        client.change(51201, {"remove_checked": stale}, status="entry_conflict")
        client.change(51202, {"remove_checked": stale}, status="entry_conflict")
        assert (
            client.call({"lookup": {"parent": folder, "name": "first.dat"}})[
                "attributes"
            ]["node"]["id"]
            == replacement
        )
        assert (
            client.call({"lookup": {"parent": parent, "name": "moved.dat"}})[
                "attributes"
            ]["node"]["id"]
            == original
        )
        smb("del vfs-read/namespace/first.dat", share="write")
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
        smb(f"put {source} vfs-read/renamed-dir/child/probe.dat", share="write")
        child = client.call({"lookup": {"parent": folder, "name": "child"}})[
            "attributes"
        ]["node"]["id"]
        probe = client.call({"lookup": {"parent": child, "name": "probe.dat"}})[
            "attributes"
        ]["node"]["id"]
        guards = [
            {"inode": parent, "parent": 1, "name": "vfs-read"},
            {"inode": folder, "parent": parent, "name": "renamed-dir"},
            {"inode": child, "parent": folder, "name": "child"},
        ]
        observed = {"inode": probe, "parent": child, "name": "probe.dat"}
        guarded_reader = client.call(
            {
                "open_guarded": {
                    "path": {"source": observed, "ancestors": guards},
                    "writable": False,
                }
            }
        )["handle"]
        guarded_remove = {
            "path_guarded": {"ancestors": guards, "mutation": {"remove": observed}}
        }
        unopened = client.change(
            51214,
            {
                "path_guarded": {
                    "ancestors": guards,
                    "mutation": {
                        "create": {
                            "parent": child,
                            "name": "unopened.dat",
                            "kind": "file",
                        }
                    },
                }
            },
        )
        smb("rename vfs-read/renamed-dir vfs-read/relocated", share="write")
        client.call(
            {
                "open_guarded": {
                    "path": {
                        "source": {
                            "inode": unopened,
                            "parent": child,
                            "name": "unopened.dat",
                        },
                        "ancestors": guards,
                    },
                    "writable": True,
                }
            },
            error="EntryConflict",
        )
        assert (
            client.call({"stat": {"inode": unopened}})["attributes"]["node"][
                "mutable_file"
            ]
            is None
        )
        for writable in (False, True):
            client.call(
                {
                    "open_guarded": {
                        "path": {"source": observed, "ancestors": guards},
                        "writable": writable,
                    }
                },
                error="EntryConflict",
            )
        # A previously established handle retains inode identity after rename.
        assert (
            client.call({"read": {"handle": guarded_reader, "offset": 0, "length": 5}})[
                "hex"
            ]
            == b"short".hex()
        )
        client.call({"close": {"handle": guarded_reader}})
        for index, kind in enumerate(("file", "directory")):
            client.change(
                51212 + index,
                {
                    "path_guarded": {
                        "ancestors": guards,
                        "mutation": {
                            "create": {
                                "parent": child,
                                "name": "must-not-create",
                                "kind": kind,
                            }
                        },
                    }
                },
                status="entry_conflict",
            )
        client.call(
            {"lookup": {"parent": child, "name": "must-not-create"}}, error="NotFound"
        )
        client.change(51210, guarded_remove, status="entry_conflict")
        client.change(
            51211,
            {
                "path_guarded": {
                    "ancestors": guards,
                    "mutation": {
                        "rename": {
                            "source": observed,
                            "parent": parent,
                            "name": "wrong.dat",
                        }
                    },
                }
            },
            status="entry_conflict",
        )
        smb(
            f"get vfs-read/relocated/child/probe.dat {directory / 'vfs-ancestor-survivor'}"
        )
        assert (directory / "vfs-ancestor-survivor").read_bytes() == b"short"
        smb("rename vfs-read/relocated vfs-read/renamed-dir", share="write")
        opened = client.call(
            {
                "open_guarded": {
                    "path": {"source": observed, "ancestors": guards},
                    "writable": True,
                }
            }
        )["handle"]
        client.call({"close": {"handle": opened}})
        smb("del vfs-read/renamed-dir/child/unopened.dat", share="write")
        # Even after the path is restored, the original refusal is replayed.
        client.change(51210, guarded_remove, status="entry_conflict")
        smb("del vfs-read/renamed-dir/child/probe.dat", share="write")
        smb("rmdir vfs-read/renamed-dir/child", share="write")
        smb("del vfs-read/moved.dat", share="write")
        client.call(
            {"lookup": {"parent": parent, "name": "moved.dat"}}, error="NotFound"
        )
        smb("rmdir vfs-read/renamed-dir", share="write")
        client.call(
            {"lookup": {"parent": parent, "name": "renamed-dir"}}, error="NotFound"
        )
        # The ancestor proof exceeds the old 4 KiB Raft request ceiling while
        # the client path remains below the VFS's 4096-byte path limit.
        deep_parent, components, deep_dirs = parent, ["vfs-read"], []
        for index in range(18):
            component = "x" * 180 + str(index)
            deep_parent = client.change(
                51300 + index,
                {
                    "create": {
                        "parent": deep_parent,
                        "name": component,
                        "kind": "directory",
                    }
                },
            )
            deep_dirs.append(deep_parent)
            components.append(component)
        deep_file = client.change(
            51320,
            {"create": {"parent": deep_parent, "name": "proof.dat", "kind": "file"}},
        )
        smb(f"get {'/'.join(components)}/proof.dat {directory / 'vfs-deep-read'}")
        assert (directory / "vfs-deep-read").read_bytes() == b""
        smb(
            f"rename {'/'.join(components)}/proof.dat vfs-read/proof.dat", share="write"
        )
        assert (
            client.call({"lookup": {"parent": parent, "name": "proof.dat"}})[
                "attributes"
            ]["node"]["id"]
            == deep_file
        )
        smb("del vfs-read/proof.dat", share="write")
        for index, inode in enumerate(reversed(deep_dirs)):
            client.change(51330 + index, {"remove": {"inode": inode}})
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

        def maintain_upload(command):
            result = subprocess.run(
                [
                    executable,
                    command,
                    endpoints,
                    str(directory / "backends.json"),
                    str(upload),
                ],
                capture_output=True,
                text=True,
                timeout=30,
            )
            assert result.returncode == 0, result.stdout + result.stderr
            return json.loads(result.stdout)

        sealed = maintain_upload("seal-mutable")
        assert sealed["sealed"]
        mappings = {
            entry["id"]: entry
            for entry in json.loads((directory / "backends.json").read_text())
        }
        for bad in range(2):
            before = client.call({"stat": {"inode": upload}})["attributes"]["node"]
            binding = before["mutable_file"]
            replicas = [
                Path(mappings[backend]["root"])
                / "mutable"
                / f"{upload}-{binding['generation']}"
                / "data"
                for backend in binding["backends"]
            ]
            source_inode = replicas[1 - bad].stat().st_ino
            replicas[bad].unlink()
            smb(f"get vfs-read/upload.dat {directory / 'vfs-missing'}", success=False)
            assert not replicas[bad].exists()
            rebuilt = maintain_upload("repair-mutable")
            assert rebuilt == sealed
            assert (
                client.call({"stat": {"inode": upload}})["attributes"]["node"] == before
            )
            assert replicas[1 - bad].stat().st_ino == source_inode
            assert all(replica.read_bytes() == b"repair" for replica in replicas)
            smb(f"get vfs-read/upload.dat {directory / 'vfs-rebuilt'}")
            assert (directory / "vfs-rebuilt").read_bytes() == b"repair"
        paused = worker(url.replace("/write/", "/deadline/"))
        call(paused, "open", flags=os.O_RDONLY)
        os.kill(core.pid, signal.SIGSTOP)
        try:
            _, stopped = os.waitpid(core.pid, os.WUNTRACED)
            assert os.WIFSTOPPED(stopped)
            started = time.monotonic()
            # Samba checks the share root first and maps that failure to
            # ACCESS_DENIED, before dispatching the file's read callback.
            call(paused, "read", offset=0, length=6, error=errno.EACCES)
            assert 0.25 <= time.monotonic() - started < 5
            # The same IPC connection is poisoned: no second wait or replay.
            started = time.monotonic()
            call(paused, "read", offset=0, length=6, error=errno.EACCES)
            assert time.monotonic() - started < 0.5
        finally:
            os.kill(core.pid, signal.SIGCONT)
        call(paused, "close", error=errno.EACCES)
        assert (
            "vfs_ChDir_shareroot(/) failed: Connection timed out"
            in (state / "process.log").read_text()
        )
        smb(f"get vfs-read/upload.dat {directory / 'vfs-after-timeout'}")
        assert (directory / "vfs-after-timeout").read_bytes() == b"repair"
        client.close()
        client = None
        core.terminate()
        core.wait(timeout=10)
        (runtime / "core.sock").unlink()
        runtime.rmdir()
        core = spawn(core.args, "core-restarted.log")
        deadline = time.monotonic() + 15
        while not (runtime / "core.sock").exists():
            assert core.poll() is None and time.monotonic() < deadline
            time.sleep(0.02)
        client = Client(runtime / "core.sock")
        replay_modified()
        replay_accessed()
        assert (
            client.call({"stat": {"inode": created_directory["id"]}})["attributes"][
                "node"
            ]["times"]
            == directory_times
        )
        assert (
            client.call({"stat": {"inode": timed_inode}})["attributes"]["node"]["times"]
            == expected_times
        )
        assert time_lines() == saved_times
        for inode, times in namespace_saved_times.items():
            assert inode_times(inode) == times
        smb(f"get vfs-read/times.dat {directory / 'vfs-times-restarted-download'}")
        reopened_node = client.call({"stat": {"inode": timed_inode}})["attributes"][
            "node"
        ]
        assert reopened_node["access"]["sequence"] == 2
        for field in ("mtime", "ctime", "birthtime"):
            assert reopened_node["times"][field] == expected_times[field]
        print(
            "PASS: native Samba VFS SMB3 reads/writes, namespace mutations, writer exclusion, checkpoints, corruption recovery and paused-core deadline without FUSE; host paths rejected",
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
