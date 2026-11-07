"""Receipt retirement, retry fencing and optional native bridge integration."""

import ctypes as c
import errno
import json
import subprocess
import time


def test_receipt_epochs(
    executable, directory, endpoints, run, leader, stop, start, processes, bridge=None
):
    epoch = run("receipts", endpoints)["epoch"]
    old = {
        "request_id": 99001,
        "receipt_epoch": epoch,
        "command": {
            "create": {"parent": 1, "name": "receipt-retired", "kind": "directory"}
        },
    }
    created = run("apply", endpoints, json.dumps(old))
    assert created["status"] == "ok"
    core = None
    clients = []
    log = None
    try:
        if bridge:
            shared = directory / "receipt-bridge.so"
            subprocess.run(
                [
                    "cc",
                    "-shared",
                    "-Wl,--whole-archive",
                    bridge,
                    "-Wl,--no-whole-archive",
                    "-o",
                    str(shared),
                ],
                check=True,
            )
            lib = c.CDLL(str(shared))
            lib.nas_ipc_connect.argtypes = [c.c_char_p, c.POINTER(c.c_void_p)]
            lib.nas_ipc_disconnect.argtypes = [c.c_void_p]
            lib.nas_ipc_disconnect.restype = None
            lib.nas_ipc_mkdir.argtypes = [
                c.c_void_p,
                c.c_uint64,
                c.c_char_p,
                c.c_uint64,
                c.POINTER(c.c_uint64),
            ]
            lib.nas_ipc_remove.argtypes = [c.c_void_p, c.c_uint64, c.c_uint64]
            config = directory / "receipt-backends.json"
            config.write_text(
                json.dumps(
                    [
                        {
                            "id": i,
                            "root": str(directory / f"receipt-nas-{i}"),
                            "allow_local": True,
                        }
                        for i in (1, 2)
                    ]
                )
            )
            runtime = directory / "receipt-core"
            log = (directory / "receipt-core.log").open("w")
            core = subprocess.Popen(
                [
                    executable,
                    "serve-files",
                    endpoints,
                    str(config),
                    str(runtime),
                    "1",
                    "2",
                ],
                stdout=log,
                stderr=log,
            )
            deadline = time.monotonic() + 15
            while not (runtime / "core.sock").exists():
                assert core.poll() is None and time.monotonic() < deadline
                time.sleep(0.02)
            from test_file_ipc import Client

            probe = Client(runtime / "core.sock")
            try:
                assert probe.call({"receipt_state": {}})["receipts"]["epoch"] == epoch
            finally:
                probe.close()

            def connect():
                client = c.c_void_p()
                assert (
                    lib.nas_ipc_connect(
                        str(runtime / "core.sock").encode(), c.byref(client)
                    )
                    == 0
                )
                clients.append(client)
                return client

            pinned = connect()
            inode = c.c_uint64()
            assert (
                lib.nas_ipc_mkdir(pinned, 1, b"receipt-pinned", 99002, c.byref(inode))
                == 0
            )

        assert run("rotate-receipts", endpoints, epoch) == {"status": "ok", "inode": 0}
        assert run("receipts", endpoints) == {
            "epoch": epoch + 1,
            "count": 0,
            "capacity": 8192,
        }
        assert (
            run("apply", endpoints, json.dumps(old))["status"]
            == "receipt_epoch_conflict"
        )
        if bridge:
            # Even a fresh request ID on an already pinned connection must fail.
            assert lib.nas_ipc_remove(pinned, inode.value, 99003) == errno.ESTALE
            fresh = connect()
            assert lib.nas_ipc_remove(fresh, inode.value, 99003) == 0
            assert (
                lib.nas_ipc_mkdir(fresh, 1, b"receipt-new", 99004, c.byref(inode)) == 0
            )
            from test_file_ipc import Client

            ipc = Client(runtime / "core.sock")
            try:
                assert ipc.call({"receipt_state": {}})["receipts"]["epoch"] == epoch + 1
                change = {
                    "request_id": 99005,
                    "mutation": {
                        "create": {
                            "parent": 1,
                            "name": "receipt-ipc",
                            "kind": "directory",
                        }
                    },
                }
                assert (
                    ipc.call({"change": change})["change"]["status"]
                    == "receipt_epoch_conflict"
                )
                change["receipt_epoch"] = epoch + 1
                assert ipc.call({"change": change})["change"]["status"] == "ok"
            finally:
                ipc.close()

        removal = {
            "request_id": 99001,
            "receipt_epoch": epoch + 1,
            "command": {"remove": {"id": created["inode"]}},
        }
        assert run("apply", endpoints, json.dumps(removal)) == created
        for i in range(20):
            request = {
                "request_id": 99100 + i,
                "receipt_epoch": epoch + 1,
                "command": {"remove": {"id": 2**63}},
            }
            assert run("apply", endpoints, json.dumps(request))["status"] == "not_found"
        saved = run("receipts", endpoints)
        first = leader()
        stop(first)
        leader()
        assert run("rotate-receipts", endpoints, epoch)["status"] == "ok"
        assert run("receipts", endpoints) == saved
        assert (
            run("apply", endpoints, json.dumps(old))["status"]
            == "receipt_epoch_conflict"
        )
        assert run("apply", endpoints, json.dumps(removal)) == created
        start(first)
        leader()
        for i in list(processes):
            stop(i)
        for i in range(3):
            start(i)
        leader()
        assert run("receipts", endpoints) == saved
        assert run("rotate-receipts", endpoints, epoch)["status"] == "ok"
        assert run("receipts", endpoints) == saved
        assert (
            run("apply", endpoints, json.dumps(old))["status"]
            == "receipt_epoch_conflict"
        )
        assert run("lookup", endpoints, 1, "receipt-retired") is None
        assert run("rotate-receipts", endpoints, epoch + 1)["status"] == "ok"
        assert (
            run("rotate-receipts", endpoints, epoch)["status"]
            == "receipt_epoch_conflict"
        )
        assert (
            run("apply", endpoints, json.dumps(removal))["status"]
            == "receipt_epoch_conflict"
        )
        assert run("receipts", endpoints) == {
            "epoch": epoch + 2,
            "count": 0,
            "capacity": 8192,
        }
        print(
            "PASS: receipt epoch retirement fences old retries across leader change, snapshots and restart; exact rotation replay retains new receipts",
            flush=True,
        )
    finally:
        for client in clients:
            lib.nas_ipc_disconnect(client)
        if core is not None:
            core.terminate()
            try:
                core.wait(timeout=10)
            except subprocess.TimeoutExpired:
                core.kill()
                core.wait(timeout=5)
        if log is not None:
            log.close()
