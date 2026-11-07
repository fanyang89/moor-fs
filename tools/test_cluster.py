#!/usr/bin/env python3
"""Run three real processes through election, failover, snapshots and WAL recovery."""

import argparse
import json
import os
import re
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
    parser.add_argument("--repair-faults", action="store_true")
    parser.add_argument("--mutable-access")
    parser.add_argument("--file-ipc", action="store_true")
    parser.add_argument("--samba-vfs", action="store_true")
    parser.add_argument("--wal-fuse", action="store_true")
    parser.add_argument("--wal-smb", action="store_true")
    parser.add_argument("--wal-faults", action="store_true")
    parser.add_argument("--wal-benchmark", action="store_true")
    parser.add_argument("--backend-roots", nargs=2, type=Path)
    parser.add_argument("--backend-server-roots", nargs=2, type=Path)
    parser.add_argument("--smb-ports", nargs=2, type=int)
    options = parser.parse_args()
    if options.wal_benchmark and not (options.wal_fuse or options.wal_smb):
        parser.error("--wal-benchmark requires --wal-fuse or --wal-smb")
    if options.wal_faults and not (options.wal_fuse or options.wal_smb):
        parser.error("--wal-faults requires --wal-fuse or --wal-smb")
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
        publish_stops = directory / "publish-stops"
        if options.repair_faults:
            publish_stops.mkdir()

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
            environment = dict(os.environ)
            environment.pop("NAS_FS_PUBLISH_STOP_DIR", None)
            if options.repair_faults:
                environment["NAS_FS_PUBLISH_STOP_DIR"] = str(publish_stops)
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
                env=environment,
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

        def drop_publish_reply(inode, access):
            marker = publish_stops / str(inode)
            marker.touch(exist_ok=False)
            try:
                access.send_signal(signal.SIGCONT)
                deadline = time.monotonic() + 45
                while True:
                    for i, process in list(processes.items()):
                        pid, status = os.waitpid(process.pid, os.WUNTRACED | os.WNOHANG)
                        if not pid:
                            continue
                        if not os.WIFSTOPPED(status):
                            process.returncode = os.waitstatus_to_exitcode(status)
                            raise AssertionError(
                                f"metadata node {i} exited before reply checkpoint: {status}"
                            )
                        assert os.WSTOPSIG(status) == signal.SIGSTOP
                        assert not marker.exists(), (
                            "metadata checkpoint did not consume marker"
                        )
                        receipt = re.findall(
                            rf"NAS_FS_PUBLISH_STOP inode={inode} request=(\d+)",
                            (directory / f"node-{i}.log").read_text(),
                        )
                        assert len(receipt) == 1, receipt
                        stop(i)
                        try:
                            assert leader() != i
                        except BaseException:
                            start(i)
                            raise
                        return i, int(receipt[0])
                    assert time.monotonic() < deadline, (
                        "metadata reply checkpoint timed out"
                    )
                    time.sleep(0.02)
            finally:
                marker.unlink(missing_ok=True)

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
            creation_started = time.time_ns()
            result = apply(first, request)
            assert result == {"status": "ok", "inode": 2}
            original_times = run("get", addresses[first + 3], "2")["times"]
            born = original_times["birthtime"]
            assert all(value == born for value in original_times.values())
            assert (
                creation_started
                <= born["seconds"] * 1000000000 + born["nanoseconds"]
                <= time.time_ns()
            )
            assert apply(first, request) == result
            assert run("get", addresses[first + 3], "2")["times"] == original_times
            forged = {
                **create(99, "forged-time"),
                "creation_time": {"seconds": 123, "nanoseconds": 0},
            }
            run("apply", addresses[first + 3], json.dumps(forged), success=False)
            forged["namespace_time"] = forged.pop("creation_time")
            run("apply", addresses[first + 3], json.dumps(forged), success=False)
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
            mutable_inode = apply(first, create(200, "wal-metadata"))["inode"]
            binding = {
                "request_id": 0,
                "command": {
                    "attach_mutable": {
                        "inode": mutable_inode,
                        "expected_version": 0,
                        "file": {
                            "generation": 7,
                            "next_sequence": 1,
                            "size": 0,
                            "backends": [1, 2],
                        },
                    }
                },
            }

            def mutable_checkpoint(request_id, expected, next_sequence, size):
                return {
                    "request_id": request_id,
                    "command": {
                        "mutable_file": {
                            "checkpoint": {
                                "inode": mutable_inode,
                                "generation": 7,
                                "expected_sequence": expected,
                                "next_sequence": next_sequence,
                                "size": size,
                            }
                        }
                    },
                }

            checkpoint_request = mutable_checkpoint(202, 1, 4, 123)
            mutable_result = {"status": "ok", "inode": mutable_inode}
            assert apply(first, binding) == mutable_result
            automatic_time = {
                "request_id": 0,
                "command": {
                    "touch_modified": {
                        "inode": mutable_inode,
                        "modification": {
                            "generation": 7,
                            "next_sequence": 2,
                            "time": {"seconds": 123, "nanoseconds": 456700},
                        },
                    }
                },
            }
            assert apply(first, automatic_time) == mutable_result
            explicit_time = {
                "request_id": 207,
                "command": {
                    "set_times": {
                        "inode": mutable_inode,
                        "mtime": {"seconds": 456, "nanoseconds": 0},
                    }
                },
            }
            assert apply(first, explicit_time) == mutable_result
            assert apply(first, checkpoint_request) == mutable_result
            root_times_before_retry = run("get", endpoints, "1")["times"]
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
            assert run("get", endpoints, "2")["times"] == original_times
            assert run("get", endpoints, "1")["times"] == root_times_before_retry
            assert apply(elected, automatic_time) == mutable_result
            assert (
                run("get", endpoints, mutable_inode)["times"]["mtime"]["seconds"] == 456
            )
            assert run("apply", endpoints, json.dumps(initial_publication)) == result
            assert run("apply", endpoints, json.dumps(binding)) == mutable_result
            assert (
                run("apply", endpoints, json.dumps(checkpoint_request))
                == mutable_result
            )
            checkpoints = [
                mutable_checkpoint(203, 4, 5, 20),
                mutable_checkpoint(204, 4, 6, 30),
            ]
            with ThreadPoolExecutor(max_workers=2) as workers:
                results = list(
                    workers.map(
                        lambda value: run("apply", endpoints, json.dumps(value)),
                        checkpoints,
                    )
                )
            assert sorted(value["status"] for value in results) == [
                "ok",
                "sequence_conflict",
            ]
            mutable_winner = next(
                i for i, value in enumerate(results) if value["status"] == "ok"
            )
            mutable_state = run("get", endpoints, mutable_inode)["mutable_file"]
            assert mutable_state["next_sequence"] == 5 + mutable_winner
            sequence_checkpoint = {
                "request_id": 0,
                "command": {
                    "checkpoint_mutable": {
                        "inode": mutable_inode,
                        "generation": 7,
                        "expected_sequence": mutable_state["next_sequence"],
                        "next_sequence": mutable_state["next_sequence"] + 1,
                        "size": 40,
                    }
                },
            }
            assert (
                run("apply", endpoints, json.dumps(sequence_checkpoint))
                == mutable_result
            )
            assert (
                run("apply", endpoints, json.dumps(sequence_checkpoint))
                == mutable_result
            )
            mutable_state = run("get", endpoints, mutable_inode)["mutable_file"]
            assert mutable_state["size"] == 40
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
            root_final_times = run("get", endpoints, "1")["times"]
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
            assert len(states[0]["nodes"]) == 31
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
            assert names == sorted(
                ["original", "wal-metadata"] + [f"file-{i}" for i in range(2, 30)]
            )
            assert run("get", endpoints, mutable_inode)["mutable_file"] == mutable_state
            assert (
                run("apply", endpoints, json.dumps(checkpoint_request))
                == mutable_result
            )
            assert run("get", endpoints, mutable_inode)["mutable_file"] == mutable_state
            assert apply(elected, automatic_time) == mutable_result
            restored_time = run("get", endpoints, mutable_inode)
            assert apply(elected, binding) == mutable_result
            assert (
                run("get", endpoints, mutable_inode)["attachment"]
                == binding["command"]["attach_mutable"]
            )
            assert apply(elected, sequence_checkpoint) == mutable_result
            assert run("get", endpoints, mutable_inode)["mutable_file"] == mutable_state
            assert (
                restored_time["modification"]
                == automatic_time["command"]["touch_modified"]["modification"]
            )
            assert restored_time["times"]["mtime"]["seconds"] == 456
            assert run("get", endpoints, "2")["times"] == original_times
            assert run("get", endpoints, "1")["times"] == root_final_times
            print(
                "PASS: mutable checkpoint CAS and timestamp watermark replay preserve explicit times across leader change, snapshot and whole-cluster restart",
                flush=True,
            )
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

            assert (
                run(
                    "apply",
                    endpoints,
                    json.dumps(
                        {
                            "request_id": 205,
                            "command": {"remove": {"id": mutable_inode}},
                        }
                    ),
                )
                == mutable_result
            )

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
                repair_faults=options.repair_faults,
            )
            if options.samba_vfs:
                from test_samba_vfs import test_samba_vfs

                test_samba_vfs(executable, directory, endpoints)
            if options.file_ipc:
                from test_file_ipc import test_file_ipc

                test_file_ipc(executable, directory, endpoints, run)
            if options.mutable_access:
                from test_mutable_access import test_mutable_access

                test_mutable_access(
                    options.mutable_access,
                    directory,
                    endpoints,
                    run,
                    leader,
                    stop,
                    start,
                )
            if options.wal_fuse or options.wal_smb:
                from test_wal_fuse import test_wal_fuse

                test_wal_fuse(
                    executable,
                    directory,
                    endpoints,
                    run,
                    smb=options.wal_smb,
                    server_roots=options.backend_server_roots,
                    faults=options.wal_faults,
                    benchmark=options.wal_benchmark,
                    benchmark_voters={
                        f"voter-{i + 1}": process.pid
                        for i, process in processes.items()
                    },
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
                    write_faults=options.repair_faults,
                    drop_publish_reply=drop_publish_reply,
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
