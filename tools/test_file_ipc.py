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


def writer_process(path, inode):
    client = Client(path)
    handle = client.call({"open": {"inode": int(inode), "writable": True}})["handle"]
    data = bytes(range(256)) * 256
    client.call({"write": {"handle": handle, "offset": 0, "hex": data.hex()}})
    print(handle, flush=True)
    sys.stdin.read()  # Test parent kills this process with a dirty live handle.


def test_file_ipc(executable, directory, endpoints, run):
    config = directory / "backends.json"
    inode = run(
        "apply",
        endpoints,
        json.dumps(
            {
                "request_id": 39000,
                "command": {
                    "create": {
                        "parent": 1,
                        "name": "ipc-file",
                        "kind": "file",
                    }
                },
            }
        ),
    )["inode"]
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
        opened = recovered.call({"open": {"inode": inode, "writable": False}})
        assert opened["size"] == 8
        result = recovered.call(
            {"read": {"handle": opened["handle"], "offset": 0, "length": 16}}
        )
        assert bytes.fromhex(result["hex"]) == b"\x00\x01\x02\xff\x00\xfe\xab\xcd"
        recovered.call({"close": {"handle": opened["handle"]}})
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
