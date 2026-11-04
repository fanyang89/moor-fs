#!/usr/bin/env python3
"""Run three real processes through election, failover, snapshots and WAL recovery."""

import argparse
import json
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time


def main():
    def interrupted(signum, frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", nargs="?", default="zig-out/bin/nas-fs")
    parser.add_argument("--fuse", action="store_true")
    parser.add_argument("--smb", action="store_true")
    parser.add_argument("--backend-roots", nargs=2, type=Path)
    parser.add_argument("--backend-server-roots", nargs=2, type=Path)
    parser.add_argument("--smb-ports", nargs=2, type=int)
    options = parser.parse_args()
    executable = str(Path(options.executable).resolve())
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

        def publication(request_id, version_id, expected, backends=(1, 2)):
            return {
                "request_id": request_id,
                "command": {
                    "publish": {
                        "expected_version": expected,
                        "version": {
                            "id": version_id,
                            "inode": 2,
                            "size": 123,
                            "sha256": [7] * 32,
                            "backends": list(backends),
                        },
                    }
                },
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
            for backend_id, domain in [(1, 10), (2, 20), (3, 10)]:
                assert (
                    apply(
                        first,
                        {
                            "request_id": 100 + backend_id,
                            "command": {
                                "register_backend": {
                                    "id": backend_id,
                                    "failure_domain": domain,
                                }
                            },
                        },
                    )["status"]
                    == "ok"
                )
            assert run("backend", endpoints, "2") == {"id": 2, "failure_domain": 20}
            assert (
                apply(first, publication(104, 10, 0, (1, 3)))["status"]
                == "same_failure_domain"
            )
            assert (
                apply(first, publication(105, 10, 0, (1, 0)))["status"]
                == "replica_mismatch"
            )
            initial_publication = publication(106, 10, 0)
            assert apply(first, initial_publication) == result
            version = run("file-version", endpoints, "10")
            assert version == initial_publication["command"]["publish"]["version"], (
                version
            )
            assert run("get", endpoints, "2")["current_version"] == 10
            print(
                "PASS: election, proposal, deduplication, validation, leader-only ReadIndex, store lock",
                flush=True,
            )

            stop(first)
            # A split election may outlast the client's bounded retry window.
            replay = subprocess.run(
                [executable, "apply", endpoints, json.dumps(request)],
                capture_output=True,
                text=True,
                timeout=12,
            )
            if replay.returncode:
                assert replay.stdout.strip() == "error: ClusterUnavailable", (
                    replay.stdout,
                    replay.stderr,
                )
                print(
                    "INFO: election exceeded retry window; replaying after leader recovery",
                    flush=True,
                )
            else:
                assert json.loads(replay.stdout) == result
            elected = leader()
            assert elected != first
            assert run("apply", endpoints, json.dumps(request)) == result
            assert apply(elected, request) == result
            assert run("apply", endpoints, json.dumps(initial_publication)) == result
            competing = [publication(107, 11, 10), publication(108, 12, 10)]
            with ThreadPoolExecutor(max_workers=2) as workers:
                outcomes = list(
                    workers.map(
                        lambda request: run("apply", endpoints, json.dumps(request)),
                        competing,
                    )
                )
            assert sorted(outcome["status"] for outcome in outcomes) == [
                "ok",
                "version_conflict",
            ]
            winner = next(
                i for i, outcome in enumerate(outcomes) if outcome["status"] == "ok"
            )
            assert run("get", endpoints, "2")["current_version"] == 11 + winner
            assert run("file-version", endpoints, str(12 - winner)) is None
            assert run("apply", endpoints, json.dumps(competing[winner])) == result
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
            assert run("file-version", endpoints, "10") == version
            assert run("get", endpoints, "2")["current_version"] == 11 + winner
            print(
                "PASS: backend domains, strict replica declarations, concurrent version CAS and retained version recovery",
                flush=True,
            )
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
            from test_data import test_data

            test_data(
                executable,
                directory,
                endpoints,
                run,
                leader,
                stop,
                start,
                roots=options.backend_roots,
                server_roots=options.backend_server_roots,
                smb_ports=options.smb_ports,
            )
            if options.fuse or options.smb:
                from test_fuse import test_mounts

                test_mounts(
                    executable,
                    directory,
                    endpoints,
                    run,
                    leader,
                    stop,
                    start,
                    smb=options.smb,
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
