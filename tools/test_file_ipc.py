"""Local IPC against a real Raft cluster, with an independent writer process."""

import json
import signal
import socket
import struct
import subprocess
import sys
import time

MAX_DATA = 65536
MAX_FRAME = 2 * MAX_DATA + 1024


class Client:
    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(15)
        self.socket.connect(str(path))
        self.sequence = 0

    def close(self):
        self.socket.close()

    def receive(self):
        def exact(length):
            result = bytearray()
            while len(result) < length:
                chunk = self.socket.recv(length - len(result))
                if not chunk:
                    raise EOFError("IPC disconnected")
                result.extend(chunk)
            return bytes(result)

        length = struct.unpack("<I", exact(4))[0]
        assert 0 < length <= MAX_FRAME, length
        return json.loads(exact(length))

    def call(self, operation, *, error=None, version=1, fragmented=False):
        self.sequence += 1
        data = json.dumps(
            {"version": version, "request": self.sequence, "operation": operation}
        ).encode()
        frame = struct.pack("<I", len(data)) + data
        if fragmented:
            for byte in frame:
                self.socket.sendall(bytes([byte]))
        else:
            self.socket.sendall(frame)
        response = self.receive()
        assert response["version"] == 1 and response["request"] == self.sequence
        assert response["err"] == error, response
        return response["result"]

    def change(self, request_id, mutation, status="ok"):
        result = self.call(
            {"change": {"request_id": request_id, "mutation": mutation}}
        )["change"]
        assert result["status"] == status, result
        return result["inode"]


def namespace_checks(client):
    directory = client.change(
        41000, {"create": {"parent": 1, "name": "ipc-directory", "kind": "directory"}}
    )
    create = {"create": {"parent": directory, "name": "ipc-file", "kind": "file"}}
    inode = client.change(41001, create)
    assert client.change(41001, create) == inode
    client.change(
        41001,
        {"create": {"parent": directory, "name": "different", "kind": "file"}},
        "request_conflict",
    )
    client.change(
        41002,
        {"create": {"parent": directory, "name": "IPC-FILE", "kind": "file"}},
        "already_exists",
    )
    attributes = client.call({"lookup": {"parent": directory, "name": "IPC-FILE"}})[
        "attributes"
    ]
    assert attributes["node"]["id"] == inode and attributes["size"] == 0
    assert attributes["node"]["replicas"] == "two"
    client.call({"lookup": {"parent": directory, "name": "missing"}}, error="NotFound")
    client.call(
        {"lookup": {"parent": directory, "name": "../escape"}}, error="InvalidName"
    )
    client.call({"stat": {"inode": 2**63}}, error="NotFound")
    client.call({"list": {"parent": directory, "limit": 0}}, error="InvalidLimit")
    client.call({"list": {"parent": directory, "limit": 17}}, error="InvalidLimit")
    client.change(41003, {"remove": {"inode": directory}}, "not_empty")
    client.change(
        41004,
        {"rename": {"inode": directory, "parent": directory, "name": "cycle"}},
        "cycle",
    )
    client.change(41005, {"remove": {"inode": 1}}, "root_protected")
    for index, name in enumerate(("", ".", "..", "a/b", "x" * 256)):
        client.change(
            41010 + index,
            {"create": {"parent": directory, "name": name, "kind": "file"}},
            "invalid_name",
        )
    expected = {inode}
    unicode_name = "文" * 85
    unicode_inode = client.change(
        41150, {"create": {"parent": directory, "name": unicode_name, "kind": "file"}}
    )
    expected.add(unicode_inode)
    assert (
        client.call({"lookup": {"parent": directory, "name": unicode_name}})[
            "attributes"
        ]["node"]["id"]
        == unicode_inode
    )
    for index in range(18):
        expected.add(
            client.change(
                41100 + index,
                {
                    "create": {
                        "parent": directory,
                        "name": f"entry-{index:02}",
                        "kind": "file",
                    }
                },
            )
        )
    after = None
    actual = []
    while True:
        page = client.call({"list": {"parent": directory, "after": after, "limit": 7}})[
            "page"
        ]
        assert 0 < len(page["entries"]) <= 7
        actual.extend(node["id"] for node in page["entries"])
        if page["next"] is None:
            break
        assert page["next"] != after
        after = page["next"]
    assert len(actual) == len(set(actual)) and set(actual) == expected
    destination = client.change(
        41200, {"create": {"parent": 1, "name": "ipc-destination", "kind": "directory"}}
    )
    occupied = client.change(
        41201, {"create": {"parent": destination, "name": "occupied", "kind": "file"}}
    )
    client.change(
        41202,
        {"rename": {"inode": inode, "parent": destination, "name": "occupied"}},
        "already_exists",
    )
    client.change(41203, {"remove": {"inode": occupied}})
    assert (
        client.call({"stat": {"inode": inode}})["attributes"]["node"]["parent"]
        == directory
    )
    print(
        "PASS: IPC namespace lookup/stat, bounded pagination, validation and mutation receipts",
        flush=True,
    )
    return inode, directory, destination


def writer_process(path, inode):
    client = Client(path)
    handle = client.call({"open": {"inode": int(inode), "writable": True}})["handle"]
    data = bytes(range(256)) * 256
    client.call({"write": {"handle": handle, "offset": 0, "hex": data.hex()}})
    print(handle, flush=True)
    sys.stdin.read()  # Test parent kills this process with a dirty live handle.


def test_file_ipc(executable, directory, endpoints, run):
    config = directory / "backends.json"
    runtime = directory / "ipc"
    path = runtime / "core.sock"
    command = [
        executable,
        "serve-files",
        endpoints,
        str(config),
        str(runtime),
        "1",
        "2",
    ]
    process = None
    child = None
    clients = []
    log = open(directory / "file-service.log", "w+")

    def connect():
        client = Client(path)
        clients.append(client)
        return client

    def start():
        nonlocal process
        process = subprocess.Popen(command, stdout=log, stderr=log)
        deadline = time.monotonic() + 15
        while not path.exists():
            if process.poll() is not None:
                log.seek(0)
                raise AssertionError(log.read())
            if time.monotonic() > deadline:
                raise TimeoutError("file service did not listen")
            time.sleep(0.02)
        assert runtime.stat().st_mode & 0o777 == 0o700

    def acquire(client):
        # EOF cleanup is asynchronous with respect to the other connection.
        deadline = time.monotonic() + 15
        while True:
            try:
                return client.call({"open": {"inode": inode, "writable": True}})[
                    "handle"
                ]
            except AssertionError as exc:
                if "FileBusy" not in str(exc) or time.monotonic() > deadline:
                    raise
                time.sleep(0.02)

    try:
        start()
        control = connect()
        inode, parent, destination = namespace_checks(control)
        immutable = control.change(
            41400,
            {"create": {"parent": destination, "name": "immutable", "kind": "file"}},
        )
        source = directory / "ipc-immutable-source"
        source.write_bytes(b"immutable-baseline")
        published = run(
            "put-file",
            endpoints,
            config,
            json.dumps(
                {
                    "request_id": 41401,
                    "inode": immutable,
                    "version_id": 41401,
                    "expected_version": 0,
                    "backends": [1, 2],
                }
            ),
            source,
        )
        assert published["status"] == "ok"
        attr = control.call({"stat": {"inode": immutable}})["attributes"]
        assert attr["size"] == len(b"immutable-baseline")
        assert (
            attr["node"]["current_version"] == 41401
            and attr["node"]["mutable_file"] is None
        )
        assert run("get", endpoints, immutable)["mutable_file"] is None
        duplicate = subprocess.run(command, capture_output=True, timeout=15)
        assert duplicate.returncode != 0 and path.exists()
        child = subprocess.Popen(
            [sys.executable, __file__, "writer", str(path), str(inode)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        )
        # Bound readiness without a blocking readline on a crashed worker.
        import select

        assert select.select([child.stdout], [], [], 30)[0], "writer not ready"
        foreign = int(child.stdout.readline())
        reader = connect()
        handle = reader.call(
            {"open": {"inode": inode, "writable": False}}, fragmented=True
        )["handle"]
        reader.call({"open": {"inode": inode, "writable": True}}, error="FileBusy")
        reader.call({"close": {"handle": foreign}}, error="InvalidHandle")
        reader.call(
            {"write": {"handle": handle, "offset": 0, "hex": "00"}},
            error="ReadOnlyHandle",
        )
        data = bytes(range(256)) * 256
        result = reader.call(
            {"read": {"handle": handle, "offset": 0, "length": MAX_DATA}}
        )
        assert result["count"] == MAX_DATA and bytes.fromhex(result["hex"]) == data
        assert (
            control.call({"stat": {"inode": inode}})["attributes"]["size"] == MAX_DATA
        )
        control.call(
            {"change": {"request_id": 41300, "mutation": {"remove": {"inode": inode}}}},
            error="FileBusy",
        )
        rename = {"rename": {"inode": inode, "parent": destination, "name": "renamed"}}
        control.change(41301, rename)
        control.call(
            {"lookup": {"parent": parent, "name": "ipc-file"}}, error="NotFound"
        )
        moved = control.call({"lookup": {"parent": destination, "name": "RENAMED"}})[
            "attributes"
        ]
        assert moved["node"]["id"] == inode and moved["size"] == MAX_DATA
        reader.call(
            {"read": {"handle": handle, "offset": 0, "length": MAX_DATA + 1}},
            error="InvalidRange",
        )
        reader.call({"size": {"handle": handle}}, version=2, error="UnsupportedVersion")
        # Concatenated frames must produce separate ordered responses.
        frames = []
        for request in (900, 901):
            encoded = json.dumps(
                {
                    "version": 1,
                    "request": request,
                    "operation": {"size": {"handle": handle}},
                }
            ).encode()
            frames.append(struct.pack("<I", len(encoded)) + encoded)
        reader.socket.sendall(b"".join(frames))
        for request in (900, 901):
            response = reader.receive()
            assert response["request"] == request and response["err"] is None
            assert response["result"]["size"] == MAX_DATA
        child.kill()
        assert child.wait(timeout=15) == -signal.SIGKILL
        replacement = acquire(reader)
        reader.call(
            {"write": {"handle": replacement, "offset": 0, "hex": "zz"}},
            error="InvalidCharacter",
        )
        reader.call(
            {"read": {"handle": handle, "offset": 2**64 - 1, "length": 2}},
            error="InvalidRange",
        )
        reader.call({"truncate": {"handle": replacement, "length": 3}})
        assert reader.call({"size": {"handle": handle}})["size"] == 3
        assert control.call({"stat": {"inode": inode}})["attributes"]["size"] == 3
        reader.call({"write": {"handle": replacement, "offset": 3, "hex": "ff00fe"}})
        reader.call({"sync": {"handle": replacement}})
        reader.call({"close": {"handle": replacement}})
        # A malformed frame disconnects its writer and releases ownership.
        malformed = connect()
        stale = malformed.call({"open": {"inode": inode, "writable": True}})["handle"]
        malformed.socket.sendall(struct.pack("<I", MAX_FRAME + 1))
        assert malformed.socket.recv(1) == b""
        replacement = acquire(reader)
        reader.call({"size": {"handle": stale}}, error="InvalidHandle")
        reader.call({"write": {"handle": replacement, "offset": 6, "hex": "abcd"}})
        for payload in (
            struct.pack("<I", 0),
            struct.pack("<I", 1) + b"{",
            b"\x10\x00",
            struct.pack("<I", 20) + b"{",
        ):
            broken = connect()
            broken.socket.sendall(payload)
            broken.socket.shutdown(socket.SHUT_WR)
            assert broken.socket.recv(1) == b""
        # Kill the whole core without close/fsync; restart must replay both WALs.
        process.kill()
        assert process.wait(timeout=15) == -signal.SIGKILL
        for client in clients:
            client.close()
        clients.clear()
        # Only remove our known test socket after its owner has exited.
        path.unlink()
        runtime.rmdir()
        start()
        recovered = connect()
        assert (
            recovered.change(
                41001,
                {"create": {"parent": parent, "name": "ipc-file", "kind": "file"}},
            )
            == inode
        )
        assert recovered.change(41301, rename) == inode
        recovered.call(
            {"lookup": {"parent": parent, "name": "ipc-file"}}, error="NotFound"
        )
        # stat without a live handle recovers dirty mutable state as well.
        assert recovered.call({"stat": {"inode": inode}})["attributes"]["size"] == 8
        opened = recovered.call({"open": {"inode": inode, "writable": False}})
        assert opened["size"] == 8
        result = recovered.call(
            {"read": {"handle": opened["handle"], "offset": 0, "length": 16}}
        )
        assert bytes.fromhex(result["hex"]) == b"\x00\x01\x02\xff\x00\xfe\xab\xcd"
        recovered.call({"close": {"handle": opened["handle"]}})
        recovered.change(41300, {"remove": {"inode": inode}})
        recovered.change(41300, {"remove": {"inode": inode}})
        recovered.call({"stat": {"inode": inode}}, error="NotFound")
        fresh = recovered.change(
            41302,
            {"create": {"parent": destination, "name": "renamed", "kind": "file"}},
        )
        assert fresh != inode
        recovered.change(41300, {"remove": {"inode": inode}})
        assert (
            recovered.call({"lookup": {"parent": destination, "name": "renamed"}})[
                "attributes"
            ]["node"]["id"]
            == fresh
        )
        print(
            "PASS: IPC multiprocess sharing, ownership, bounds, disconnect and core SIGKILL recovery",
            flush=True,
        )
    finally:
        for client in clients:
            client.close()
        for worker in (child, process):
            if worker is not None and worker.poll() is None:
                worker.kill()
                worker.wait(timeout=15)
        if child is not None:
            child.stdin.close()
            child.stdout.close()
        log.close()


if __name__ == "__main__":
    assert sys.argv[1] == "writer"
    writer_process(*sys.argv[2:])
