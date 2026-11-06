"""Exercise the C ABI against controlled fragmented and invalid IPC replies."""

import ctypes as c
import errno
import json
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor


def main():
    with tempfile.TemporaryDirectory(prefix="nas-ipc-abi-") as temporary:
        directory = Path(temporary)
        shared = directory / "bridge.so"
        subprocess.run(
            [
                "cc",
                "-shared",
                "-Wl,--whole-archive",
                sys.argv[1],
                "-Wl,--no-whole-archive",
                "-o",
                str(shared),
            ],
            check=True,
        )
        lib = c.CDLL(str(shared))
        lib.nas_ipc_connect.argtypes = [c.c_char_p, c.POINTER(c.c_void_p)]
        lib.nas_ipc_connect.restype = c.c_int
        lib.nas_ipc_disconnect.argtypes = [c.c_void_p]
        lib.nas_ipc_disconnect.restype = None
        lib.nas_ipc_open.argtypes = [c.c_void_p, c.c_uint64, c.POINTER(c.c_uint64)]
        lib.nas_ipc_open.restype = c.c_int
        lib.nas_ipc_read.argtypes = [
            c.c_void_p,
            c.c_uint64,
            c.c_uint64,
            c.c_void_p,
            c.c_size_t,
            c.POINTER(c.c_size_t),
        ]
        lib.nas_ipc_read.restype = c.c_int
        lib.nas_ipc_open_write.argtypes = lib.nas_ipc_open.argtypes
        lib.nas_ipc_create_file.argtypes = [
            c.c_void_p,
            c.c_uint64,
            c.c_char_p,
            c.c_uint64,
            c.POINTER(c.c_uint64),
        ]
        lib.nas_ipc_write.argtypes = [
            c.c_void_p,
            c.c_uint64,
            c.c_uint64,
            c.c_void_p,
            c.c_size_t,
        ]
        lib.nas_ipc_truncate.argtypes = [c.c_void_p, c.c_uint64, c.c_uint64]
        lib.nas_ipc_sync.argtypes = [c.c_void_p, c.c_uint64]
        lib.nas_ipc_close.argtypes = [c.c_void_p, c.c_uint64]

        def exact(sock, count):
            result = b""
            while len(result) < count:
                chunk = sock.recv(count - len(result))
                assert chunk
                result += chunk
            return result

        def serve(listener, replies):
            connection, _ = listener.accept()
            with connection:
                connection.settimeout(5)
                for reply in replies:
                    size = struct.unpack("<I", exact(connection, 4))[0]
                    request = json.loads(exact(connection, size))
                    if isinstance(reply, tuple):
                        expected, reply = reply
                        assert request["operation"] == expected, request
                    if isinstance(reply, bytes):
                        connection.sendall(reply)
                        connection.shutdown(socket.SHUT_WR)
                    else:
                        response = {
                            "version": 1,
                            "request": request["request"],
                            "err": None,
                            "result": {},
                        }
                        response.update(reply)
                        encoded = json.dumps(response).encode()
                        frame = struct.pack("<I", len(encoded)) + encoded
                        for byte in frame:
                            connection.sendall(bytes([byte]))
                # A poisoned client must close rather than retry/reconnect.
                assert connection.recv(1) == b""

        cases = [
            b"\x01\x00",
            struct.pack("<I", 0),
            struct.pack("<I", 132097),
            struct.pack("<I", 8) + b"{}",
            struct.pack("<I", 1) + b"{",
            {"version": 2},
            {"request": 999},
            {"result": {"handle": 0}},
            {"result": {}},
        ]
        with ThreadPoolExecutor(max_workers=1) as pool:
            for index, reply in enumerate(cases):
                path = directory / f"socket-{index}"
                with socket.socket(socket.AF_UNIX) as listener:
                    listener.settimeout(5)
                    listener.bind(str(path))
                    listener.listen()
                    future = pool.submit(serve, listener, [reply])
                    client = c.c_void_p()
                    assert lib.nas_ipc_connect(str(path).encode(), c.byref(client)) == 0
                    try:
                        handle = c.c_uint64()
                        assert (
                            lib.nas_ipc_open(client, 42, c.byref(handle)) == errno.EIO
                        )
                        assert (
                            lib.nas_ipc_open(client, 42, c.byref(handle)) == errno.EIO
                        )
                    finally:
                        lib.nas_ipc_disconnect(client)
                    future.result(timeout=5)
            # An application error keeps framing synchronized; valid binary data
            # survives arbitrary fragments, but malformed payloads poison it.
            path = directory / "valid"
            with socket.socket(socket.AF_UNIX) as listener:
                listener.bind(str(path))
                listener.listen()
                future = pool.submit(
                    serve,
                    listener,
                    [
                        {"err": "NotFound"},
                        {"result": {"handle": 7}},
                        {"result": {"count": 4, "hex": "00ff0180"}},
                        {"result": {"count": 4, "hex": "00zz0180"}},
                    ],
                )
                client = c.c_void_p()
                assert lib.nas_ipc_connect(str(path).encode(), c.byref(client)) == 0
                try:
                    handle = c.c_uint64()
                    assert lib.nas_ipc_open(client, 42, c.byref(handle)) == errno.ENOENT
                    assert (
                        lib.nas_ipc_open(client, 42, c.byref(handle)) == 0
                        and handle.value == 7
                    )
                    buffer = c.create_string_buffer(4)
                    count = c.c_size_t()
                    assert (
                        lib.nas_ipc_read(client, 7, 0, buffer, 4, c.byref(count)) == 0
                    )
                    assert count.value == 4 and buffer.raw == b"\x00\xff\x01\x80"
                    assert (
                        lib.nas_ipc_read(client, 7, 0, buffer, 4, c.byref(count))
                        == errno.EIO
                    )
                    assert count.value == 0
                    assert lib.nas_ipc_open(client, 42, c.byref(handle)) == errno.EIO
                finally:
                    lib.nas_ipc_disconnect(client)
                future.result(timeout=5)
            path = directory / "writes"
            create = {
                "change": {
                    "request_id": 901,
                    "mutation": {
                        "create": {"parent": 1, "name": "file", "kind": "file"}
                    },
                }
            }
            with socket.socket(socket.AF_UNIX) as listener:
                listener.bind(str(path))
                listener.listen()
                future = pool.submit(
                    serve,
                    listener,
                    [
                        (
                            create,
                            {
                                "result": {
                                    "change": {"status": "already_exists", "inode": 0}
                                }
                            },
                        ),
                        (create, {"result": {"change": {"status": "ok", "inode": 42}}}),
                        (
                            {"open": {"inode": 42, "writable": True}},
                            {"result": {"handle": 7}},
                        ),
                        (
                            {"write": {"handle": 7, "offset": 9, "hex": "00ff80"}},
                            {"result": {"count": 3}},
                        ),
                        ({"truncate": {"handle": 7, "length": 12}}, {"result": {}}),
                        ({"sync": {"handle": 7}}, {"err": "WalSessionFailed"}),
                        ({"close": {"handle": 7}}, {"err": "WalSessionFailed"}),
                        (
                            {"write": {"handle": 7, "offset": 0, "hex": "00ff80"}},
                            {"result": {"count": 2}},
                        ),
                    ],
                )
                client = c.c_void_p()
                assert lib.nas_ipc_connect(str(path).encode(), c.byref(client)) == 0
                try:
                    inode = c.c_uint64()
                    assert (
                        lib.nas_ipc_create_file(client, 1, b"file", 901, c.byref(inode))
                        == errno.EEXIST
                    )
                    assert (
                        lib.nas_ipc_create_file(client, 1, b"file", 901, c.byref(inode))
                        == 0
                        and inode.value == 42
                    )
                    handle = c.c_uint64()
                    assert lib.nas_ipc_open_write(client, inode, c.byref(handle)) == 0
                    assert lib.nas_ipc_write(client, handle, 9, b"\x00\xff\x80", 3) == 0
                    assert lib.nas_ipc_truncate(client, handle, 12) == 0
                    assert lib.nas_ipc_sync(client, handle) == errno.EIO
                    assert lib.nas_ipc_close(client, handle) == errno.EIO
                    assert (
                        lib.nas_ipc_write(client, handle, 0, b"\x00\xff\x80", 3)
                        == errno.EIO
                    )
                    assert lib.nas_ipc_sync(client, handle) == errno.EIO
                finally:
                    lib.nas_ipc_disconnect(client)
                future.result(timeout=5)
            lib.nas_ipc_mkdir.argtypes = lib.nas_ipc_create_file.argtypes
            lib.nas_ipc_rename.argtypes = [
                c.c_void_p,
                c.c_uint64,
                c.c_uint64,
                c.c_char_p,
                c.c_uint64,
            ]
            lib.nas_ipc_remove.argtypes = [c.c_void_p, c.c_uint64, c.c_uint64]

            class Attr(c.Structure):
                _fields_ = [
                    ("inode", c.c_uint64),
                    ("parent", c.c_uint64),
                    ("size", c.c_uint64),
                    ("directory", c.c_int),
                    ("name", c.c_char * 256),
                ]

            lib.nas_ipc_rename_checked.argtypes = [
                c.c_void_p,
                c.POINTER(Attr),
                c.c_uint64,
                c.c_char_p,
                c.c_uint64,
            ]
            lib.nas_ipc_remove_checked.argtypes = [
                c.c_void_p,
                c.POINTER(Attr),
                c.c_uint64,
            ]
            source = {"inode": 42, "parent": 1, "name": "old"}
            lib.nas_ipc_rename_guarded.argtypes = [
                c.c_void_p,
                c.POINTER(Attr),
                c.c_uint64,
                c.c_char_p,
                c.POINTER(Attr),
                c.c_size_t,
                c.c_uint64,
            ]
            lib.nas_ipc_remove_guarded.argtypes = [
                c.c_void_p,
                c.POINTER(Attr),
                c.POINTER(Attr),
                c.c_size_t,
                c.c_uint64,
            ]
            ancestors = [{"inode": 2, "parent": 1, "name": "destination"}]
            lib.nas_ipc_create_guarded.argtypes = [
                c.c_void_p,
                c.c_uint64,
                c.c_char_p,
                c.c_int,
                c.POINTER(Attr),
                c.c_size_t,
                c.c_uint64,
                c.POINTER(c.c_uint64),
            ]
            lib.nas_ipc_open_guarded.argtypes = [
                c.c_void_p,
                c.POINTER(Attr),
                c.c_int,
                c.POINTER(Attr),
                c.c_size_t,
                c.POINTER(c.c_uint64),
            ]
            guarded_open = {
                "open_guarded": {
                    "path": {"source": source, "ancestors": []},
                    "writable": True,
                }
            }
            path = directory / "namespace"
            mutations = [
                (
                    {"create": {"parent": 1, "name": "dir", "kind": "directory"}},
                    "ok",
                    42,
                ),
                (
                    {"rename": {"inode": 42, "parent": 1, "name": "new"}},
                    "already_exists",
                    0,
                ),
                ({"rename": {"inode": 42, "parent": 1, "name": "new"}}, "cycle", 0),
                ({"rename": {"inode": 42, "parent": 1, "name": "new"}}, "ok", 42),
                ({"remove": {"inode": 42}}, "not_empty", 0),
                ({"remove": {"inode": 1}}, "root_protected", 0),
                ({"remove": {"inode": 42}}, "ok", 42),
                (
                    {"rename_checked": {"source": source, "parent": 2, "name": "new"}},
                    "entry_conflict",
                    0,
                ),
                ({"remove_checked": source}, "entry_conflict", 0),
                ({"remove_checked": source}, "ok", 42),
                (
                    {
                        "path_guarded": {
                            "ancestors": ancestors,
                            "mutation": {
                                "rename": {"source": source, "parent": 2, "name": "new"}
                            },
                        }
                    },
                    "entry_conflict",
                    0,
                ),
                (
                    {"path_guarded": {"ancestors": [], "mutation": {"remove": source}}},
                    "ok",
                    42,
                ),
            ]
            with socket.socket(socket.AF_UNIX) as listener:
                listener.bind(str(path))
                listener.listen()
                future = pool.submit(
                    serve,
                    listener,
                    [
                        (
                            {"change": {"request_id": 902, "mutation": mutation}},
                            {"result": {"change": {"status": status, "inode": inode}}},
                        )
                        for mutation, status, inode in mutations
                    ]
                    + [
                        (
                            {
                                "change": {
                                    "request_id": 903,
                                    "mutation": {
                                        "path_guarded": {
                                            "ancestors": ancestors,
                                            "mutation": {
                                                "create": {
                                                    "parent": 2,
                                                    "name": "new",
                                                    "kind": kind,
                                                }
                                            },
                                        }
                                    },
                                }
                            },
                            {"result": {"change": {"status": status, "inode": inode}}},
                        )
                        for kind, status, inode in [
                            ("file", "entry_conflict", 0),
                            ("directory", "ok", 43),
                        ]
                    ]
                    + [
                        (guarded_open, {"err": "EntryConflict"}),
                        (guarded_open, {"result": {"handle": 9}}),
                    ],
                )
                client = c.c_void_p()
                assert lib.nas_ipc_connect(str(path).encode(), c.byref(client)) == 0
                try:
                    inode = c.c_uint64()
                    assert (
                        lib.nas_ipc_mkdir(client, 1, b"dir", 902, c.byref(inode)) == 0
                        and inode.value == 42
                    )
                    for expected in (errno.EEXIST, errno.EINVAL, 0):
                        assert (
                            lib.nas_ipc_rename(client, 42, 1, b"new", 902) == expected
                        )
                    assert lib.nas_ipc_remove(client, 42, 902) == errno.ENOTEMPTY
                    assert lib.nas_ipc_remove(client, 1, 902) == errno.EPERM
                    assert lib.nas_ipc_remove(client, 42, 902) == 0
                    attr = Attr(inode=42, parent=1, name=b"old")
                    assert (
                        lib.nas_ipc_rename_checked(
                            client, c.byref(attr), 2, b"new", 902
                        )
                        == errno.ESTALE
                    )
                    assert (
                        lib.nas_ipc_remove_checked(client, c.byref(attr), 902)
                        == errno.ESTALE
                    )
                    assert lib.nas_ipc_remove_checked(client, c.byref(attr), 902) == 0
                    guards = (Attr * 1)(
                        Attr(inode=2, parent=1, directory=1, name=b"destination")
                    )
                    # Oversized proofs fail locally without sending or poisoning.
                    assert (
                        lib.nas_ipc_remove_guarded(
                            client, c.byref(attr), guards, 33, 902
                        )
                        == errno.ENAMETOOLONG
                    )
                    assert (
                        lib.nas_ipc_rename_guarded(
                            client, c.byref(attr), 2, b"new", guards, 1, 902
                        )
                        == errno.ESTALE
                    )
                    assert (
                        lib.nas_ipc_remove_guarded(
                            client, c.byref(attr), guards, 0, 902
                        )
                        == 0
                    )
                    assert (
                        lib.nas_ipc_create_guarded(
                            client, 2, b"new", 0, guards, 1, 903, c.byref(inode)
                        )
                        == errno.ESTALE
                    )
                    assert (
                        lib.nas_ipc_create_guarded(
                            client, 2, b"new", 1, guards, 1, 903, c.byref(inode)
                        )
                        == 0
                        and inode.value == 43
                    )
                    assert (
                        lib.nas_ipc_open_guarded(
                            client, c.byref(attr), 1, guards, 0, c.byref(inode)
                        )
                        == errno.ESTALE
                    )
                    assert (
                        lib.nas_ipc_open_guarded(
                            client, c.byref(attr), 1, guards, 0, c.byref(inode)
                        )
                        == 0
                        and inode.value == 9
                    )
                finally:
                    lib.nas_ipc_disconnect(client)
                future.result(timeout=5)
        print(
            "PASS: C IPC ABI fragmentation, error mapping, binary reads and poisoned-connection failures"
        )


if __name__ == "__main__":
    main()
