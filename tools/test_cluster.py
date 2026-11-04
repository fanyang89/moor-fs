#!/usr/bin/env python3
"""Run three real processes through election, failover, snapshots and WAL recovery."""

import json
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time


def main():
    executable = str(
        Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/nas-fs").resolve()
    )
    with tempfile.TemporaryDirectory(prefix="nas-fs-cluster-") as temporary:
        directory = Path(temporary)
        sockets = [socket.socket() for _ in range(6)]
        for sock in sockets:
            sock.bind(("127.0.0.1", 0))
        addresses = [f"127.0.0.1:{sock.getsockname()[1]}" for sock in sockets]
        for sock in sockets:
            sock.close()
        peers = ",".join(f"{i + 1}={addresses[i]}" for i in range(3))
        processes = {}
        logs = []

        def run(*args, success=True):
            result = subprocess.run(
                [executable, *map(str, args)],
                capture_output=True,
                text=True,
                timeout=12,
            )
            if success:
                assert result.returncode == 0, (args, result.stdout, result.stderr)
                return json.loads(result.stdout)
            assert result.returncode != 0, (args, result.stdout)
            return result

        def start(i):
            log = open(directory / f"node-{i}.log", "a")
            logs.append(log)
            processes[i] = subprocess.Popen(
                [
                    executable,
                    "serve",
                    "--node-id",
                    str(i + 1),
                    "--cluster-id",
                    "0123456789abcdef0123456789abcdef",
                    "--raft-listen",
                    addresses[i],
                    "--api-listen",
                    addresses[i + 3],
                    "--data-dir",
                    str(directory / f"node-{i}"),
                    "--peers",
                    peers,
                    "--snapshot-entries",
                    "8",
                ],
                stdout=log,
                stderr=log,
            )

        def stop(i, kill=True):
            process = processes.pop(i)
            process.kill() if kill else process.terminate()
            process.wait(timeout=12)
            if not kill:
                assert process.returncode == 0, (i, process.returncode)

        def eventually(check, seconds=25):
            deadline = time.monotonic() + seconds
            last = None
            while time.monotonic() < deadline:
                for i, process in processes.items():
                    assert process.poll() is None, (
                        f"node {i} exited: {process.returncode}"
                    )
                try:
                    result = check()
                    if result is not None and result is not False:
                        return result
                except (AssertionError, subprocess.TimeoutExpired) as error:
                    last = error
                time.sleep(0.1)
            raise AssertionError(f"condition timed out: {last}")

        def leader():
            def find():
                found = [
                    i
                    for i in processes
                    if run("status", addresses[i + 3])["role"] == "leader"
                ]
                return found if len(found) == 1 else None

            return eventually(find)[0]

        def apply(i, request):
            return run("apply", addresses[i + 3], json.dumps(request))

        def create(request_id, name):
            return {
                "request_id": request_id,
                "command": {"create": {"parent": 1, "name": name, "kind": "file"}},
            }

        try:
            run("unknown-command", success=False)
            run("apply", success=False)
            run("serve", "--unknown-option", success=False)
            help_output = subprocess.check_output(
                [executable, "serve", "--help"], text=True
            )
            assert "--peers" in help_output
            for i in range(3):
                start(i)
            first = leader()
            request = create(1, "original")
            result = apply(first, request)
            assert result == {"status": "ok", "inode": 2}
            assert apply(first, request) == result
            assert apply(first, create(1, "conflict"))["status"] == "request_conflict"
            run("apply", addresses[first + 3], "not-json", success=False)
            follower = next(i for i in processes if i != first)
            run(
                "apply",
                addresses[follower + 3],
                json.dumps(create(2, "rejected")),
                success=False,
            )
            run("get", addresses[follower + 3], "2", success=False)
            run(
                "metadata-show", directory / f"node-{first}" / "metadata", success=False
            )
            assert run("get", addresses[first + 3], "2")["name"] == "original"
            endpoints = ",".join(
                addresses[i + 3]
                for i in [
                    follower,
                    first,
                    next(i for i in processes if i not in (follower, first)),
                ]
            )
            assert run("lookup", endpoints, "1", "ORIGINAL")["id"] == 2
            assert run("lookup", endpoints, "1", "missing") is None
            assert run("list", endpoints, "1")["entries"][0]["name"] == "original"
            invalid = run("list", endpoints, "2", success=False)
            assert "NotDirectory" in invalid.stderr or "NotDirectory" in invalid.stdout
            run("list", endpoints, "1", "--limit", "0", success=False)
            print(
                "PASS: election, proposal, deduplication, validation, leader-only ReadIndex, store lock",
                flush=True,
            )

            stop(first)
            assert run("apply", endpoints, json.dumps(request)) == result
            elected = leader()
            assert elected != first
            assert apply(elected, request) == result
            for request_id in range(2, 30):
                assert (
                    apply(elected, create(request_id, f"file-{request_id}"))["status"]
                    == "ok"
                )
            survivors = list(processes)
            for i in survivors:
                stop(i, kill=False)
            for i in survivors:
                start(i)
            elected = leader()
            index = run("status", addresses[elected + 3])["applied_index"]
            start(first)
            eventually(
                lambda: all(
                    run("status", addresses[i + 3])["applied_index"] >= index
                    for i in processes
                )
            )
            eventually(
                lambda: (
                    "applying snapshot at index"
                    in (directory / f"node-{first}.log").read_text()
                )
            )
            print(
                "PASS: killed leader, re-election, writes with two voters, restarted follower catch-up",
                flush=True,
            )

            for i in list(processes):
                stop(i)
            states = [
                run("metadata-show", directory / f"node-{i}" / "metadata")["state"]
                for i in range(3)
            ]
            assert states[0] == states[1] == states[2]
            assert len(states[0]["nodes"]) == 30
            assert (
                "applying snapshot at index"
                in (directory / f"node-{first}.log").read_text()
            )
            run(
                "metadata-apply",
                directory / f"node-{first}" / "metadata",
                "1000",
                "1000",
                json.dumps(request),
                success=False,
            )
            for i in range(3):
                start(i)
            elected = leader()
            assert apply(elected, request) == result
            names = []
            after = None
            while True:
                args = ["list", endpoints, "1", "--limit", "3"]
                if after is not None:
                    args += ["--after", after]
                page = run(*args)
                names.extend(entry["name"] for entry in page["entries"])
                after = page["next"]
                if after is None:
                    break
            assert names == sorted(["original"] + [f"file-{i}" for i in range(2, 30)])
            print(
                "PASS: leader discovery, automatic write retry, lookup and paginated directory reads",
                flush=True,
            )
            assert run("get", addresses[elected + 3], "2")["name"] == "original"
            print("PASS: whole-cluster SIGKILL and WAL/LMDB restart", flush=True)

            follower = next(i for i in processes if i != elected)
            stop(follower)
            shutil.rmtree(directory / f"node-{follower}" / "metadata")
            start(follower)
            index = run("status", addresses[elected + 3])["applied_index"]
            eventually(
                lambda: run("status", addresses[follower + 3])["applied_index"] >= index
            )
            stop(follower, kill=False)
            rebuilt = run("metadata-show", directory / f"node-{follower}" / "metadata")
            assert rebuilt["state"] == states[0]
            assert (
                "restored local snapshot"
                in (directory / f"node-{follower}.log").read_text()
            )
            start(follower)
            print("PASS: rebuild missing LMDB from local snapshot and WAL", flush=True)

            for i in list(processes):
                if i != elected:
                    stop(i)
            run(
                "apply",
                addresses[elected + 3],
                json.dumps(create(30, "no-quorum")),
                success=False,
            )
            run("get", addresses[elected + 3], "2", success=False)
            for i in range(3):
                if i not in processes:
                    start(i)
            elected = leader()
            assert apply(elected, request) == result
            print(
                "PASS: no acknowledged write or linearizable read without quorum; cluster recovers",
                flush=True,
            )
            for i in list(processes):
                stop(i, kill=False)
        except BaseException:
            for path in sorted(directory.glob("*.log")):
                print(f"\n{path.name}:\n{path.read_text()[-10000:]}", file=sys.stderr)
            raise
        finally:
            for process in processes.values():
                if process.poll() is None:
                    process.kill()
                process.wait()
            for log in logs:
                log.close()


if __name__ == "__main__":
    main()
