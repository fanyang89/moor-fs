"""Interrupt writable requests at known dual-replica publication boundaries."""

from contextlib import contextmanager
import hashlib
import json
import os
import signal
import subprocess
import sys
import time


def test_write_faults(
    executable,
    directory,
    endpoints,
    config,
    roots,
    readonly,
    run,
    smb,
    leader,
    stop,
    start,
    drop_publish_reply,
):
    original = b"old" * 1024
    content = b"new" * 1024
    source = directory / "write-fault-source"
    request_id = 16000

    @contextmanager
    def mounted(label, point=None):
        path = directory / f"fault-mount-{label}"
        path.mkdir()
        log = directory / f"fault-mount-{label}.log"
        environment = dict(os.environ)
        environment.pop("MOOR_FS_WRITE_STOP", None)
        if point:
            environment["MOOR_FS_WRITE_STOP"] = point
        with log.open("w") as output:
            process = subprocess.Popen(
                [
                    executable,
                    "mount",
                    endpoints,
                    str(path),
                    "--backends",
                    str(config),
                    "--write-backends",
                    "1,2",
                ],
                stdout=output,
                stderr=output,
                env=environment,
            )
        ready = False
        try:
            deadline = time.monotonic() + 20
            while not os.path.ismount(path):
                assert process.poll() is None, log.read_text()
                assert time.monotonic() < deadline, "fault mount timed out"
                time.sleep(0.05)
            ready = True
            yield path, process
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=15)
            # ismount() returns false for disconnected FUSE mounts after SIGKILL.
            if ready:
                subprocess.run(["fusermount3", "-u", str(path)], check=True, timeout=10)

    def wait_stopped(process):
        deadline = time.monotonic() + 45
        while True:
            pid, status = os.waitpid(process.pid, os.WUNTRACED | os.WNOHANG)
            if pid:
                if os.WIFSTOPPED(status):
                    assert os.WSTOPSIG(status) == signal.SIGSTOP, status
                    return
                process.returncode = os.waitstatus_to_exitcode(status)
                raise AssertionError(
                    f"access process exited before checkpoint: {status}"
                )
            assert time.monotonic() < deadline, "write checkpoint timed out"
            time.sleep(0.02)

    def exercise(kind, point, outage=None):
        nonlocal request_id
        label = f"{kind}-{point}"
        if outage:
            label += f"-{outage}"
        name = f"write-crash-{label}.bin"
        request_id += 1
        inode = run(
            "apply",
            endpoints,
            json.dumps(
                {
                    "request_id": request_id,
                    "command": {"create": {"parent": 1, "name": name, "kind": "file"}},
                }
            ),
        )["inode"]
        request_id += 1
        source.write_bytes(original)
        result = run(
            "put-file",
            endpoints,
            config,
            json.dumps(
                {
                    "request_id": request_id,
                    "inode": inode,
                    "version_id": request_id,
                    "expected_version": 0,
                    "backends": [1, 2],
                }
            ),
            source,
        )
        assert result["status"] == "ok", result
        old_version = request_id
        before = [set((root / "objects").iterdir()) for root in roots]
        stages_before = [set((root / "staging").iterdir()) for root in roots]
        source.write_bytes(content)
        expected = (
            content
            if point == "published"
            or kind == "disconnect"
            or outage in ("election", "reply-loss")
            else original
        )

        def interrupt(command, access):
            nonlocal expected
            log = directory / f"fault-client-{label}.log"
            with log.open("w") as output:
                client = subprocess.Popen(command, stdout=output, stderr=output)
            try:
                if point in ("staged", "first_stage_write"):
                    wait_stopped(client if point == "staged" else access)
                    assert access.poll() is None
                    assert ("WRITE_ACK" in log.read_text()) == (point == "staged")
                    assert (
                        run("get", endpoints, inode)["current_version"] == old_version
                    )
                    for i, root in enumerate(roots):
                        assert set((root / "objects").iterdir()) == before[i]
                        staged = set((root / "staging").iterdir()) - stages_before[i]
                        staged_content = (
                            original
                            if point == "first_stage_write" and i == 1
                            else content
                        )
                        assert (
                            len(staged) == 1
                            and staged.pop().read_bytes() == staged_content
                        )
                    access.kill()
                    assert access.wait(timeout=15) == -signal.SIGKILL
                    if point == "staged":
                        client.send_signal(signal.SIGCONT)
                    assert client.wait(timeout=45) != 0
                    assert "COMMIT_ACK" not in log.read_text()
                    return
                wait_stopped(access)
                assert client.poll() is None, log.read_text()
                current = run("get", endpoints, inode)["current_version"]
                record = run("file-version", endpoints, current)
                if point == "published":
                    assert record["size"] == len(content), record
                    assert record["sha256"] == list(hashlib.sha256(content).digest()), (
                        record
                    )
                else:
                    assert current == old_version, record
                staged_version = None
                for index, root in enumerate(roots):
                    additions = set((root / "objects").iterdir()) - before[index]
                    data_copies = [
                        path
                        for path in additions
                        if path.name.endswith(hashlib.sha256(content).hexdigest())
                    ]
                    expected_count = 0 if point == "first_replica" and index == 1 else 1
                    assert len(data_copies) == expected_count, (point, additions)
                    for path in data_copies:
                        assert path.read_bytes() == content
                        candidate = int(path.name.split("-", 1)[0])
                        assert staged_version in (None, candidate)
                        staged_version = candidate
                if point != "published":
                    assert run("file-version", endpoints, staged_version) is None
                else:
                    assert current == staged_version
                if outage == "quorum":
                    current_leader = leader()
                    stopped = []
                    try:
                        for voter in range(3):
                            if voter != current_leader:
                                stop(voter)
                                stopped.append(voter)
                        access.send_signal(signal.SIGCONT)
                        code = client.wait(timeout=90)
                        output = log.read_text()
                        if kind == "fuse":
                            assert code != 0 and "COMMIT_ACK" not in output, output
                        else:
                            assert code != 0 or "NT_STATUS_" in output, output
                        assert access.poll() is None
                    finally:
                        for voter in stopped:
                            start(voter)
                    leader()
                    recovered = run("get", endpoints, inode)["current_version"]
                    # A timed-out proposal can still commit after quorum returns.
                    assert recovered in (current, staged_version), recovered
                    if recovered == staged_version:
                        expected = content
                    else:
                        assert run("file-version", endpoints, staged_version) is None
                    assert run("check-file", endpoints, config, inode)["all_healthy"]
                    print(
                        f"PASS: {label} client failed without quorum; recovered version {recovered}",
                        flush=True,
                    )
                    return
                if outage in ("election", "reply-loss"):
                    old = None
                    try:
                        if outage == "reply-loss":
                            old, request = drop_publish_reply(inode, access)
                        else:
                            old = leader()
                            stop(old)
                            assert leader() != old
                            assert (
                                run("get", endpoints, inode)["current_version"]
                                == current
                            )
                            assert (
                                run("file-version", endpoints, staged_version) is None
                            )
                            access.send_signal(signal.SIGCONT)
                        code = client.wait(timeout=45)
                        output = log.read_text()
                        if outage == "reply-loss":
                            # Bounded automatic retries may expire during election.
                            # Replay the exact original request to verify its durable receipt.
                            if kind == "fuse":
                                assert (code == 0 and "COMMIT_ACK" in output) or (
                                    code != 0 and "COMMIT_ACK" not in output
                                ), output
                            else:
                                assert code == 0 or "NT_STATUS_" in output, output
                            version = run("file-version", endpoints, staged_version)
                            replay = run(
                                "apply",
                                endpoints,
                                json.dumps(
                                    {
                                        "request_id": request,
                                        "command": {
                                            "publish": {
                                                "expected_version": current,
                                                "version": version,
                                            }
                                        },
                                    }
                                ),
                            )
                            assert replay == {"status": "ok", "inode": inode}, replay
                            print(
                                f"PASS: {label} original request receipt replayed on new leader",
                                flush=True,
                            )
                        else:
                            assert code == 0, output
                            if kind == "fuse":
                                assert "COMMIT_ACK" in output, output
                            else:
                                assert "NT_STATUS_" not in output, output
                        assert (
                            run("get", endpoints, inode)["current_version"]
                            == staged_version
                        )
                        assert run("check-file", endpoints, config, inode)[
                            "all_healthy"
                        ]
                    finally:
                        if old is not None:
                            start(old)
                    return
                if kind == "disconnect":
                    client.kill()
                    assert client.wait(timeout=15) == -signal.SIGKILL
                    access.send_signal(signal.SIGCONT)
                    deadline = time.monotonic() + 45
                    while (
                        run("get", endpoints, inode)["current_version"]
                        != staged_version
                    ):
                        assert access.poll() is None
                        assert time.monotonic() < deadline, (
                            "disconnected write did not commit"
                        )
                        time.sleep(0.05)
                    assert run("check-file", endpoints, config, inode)["all_healthy"]
                    return
                access.kill()
                assert access.wait(timeout=15) == -signal.SIGKILL
                code = client.wait(timeout=45)
                output = log.read_text()
                if kind == "fuse":
                    assert code != 0 and "COMMIT_ACK" not in output, output
                else:
                    assert code != 0 or "NT_STATUS_" in output, output
            finally:
                if client.poll() is None:
                    client.kill()
                client.wait(timeout=10)

        with mounted(label, None if point == "staged" else point) as (path, access):
            if kind == "fuse":
                interrupt(
                    [
                        sys.executable,
                        "-c",
                        "import os,sys,signal; fd=os.open(sys.argv[1],os.O_RDWR); "
                        "n=os.pwrite(fd,b'new'*1024,0); print('WRITE_ACK',n,flush=True); "
                        + (
                            "os.kill(os.getpid(),signal.SIGSTOP); "
                            if point == "staged"
                            else ""
                        )
                        + "os.fsync(fd); print('COMMIT_ACK',flush=True); os.close(fd)",
                        str(path / name),
                    ],
                    access,
                )
            else:
                from serve_smb import export

                with export(path, directory / f"sf{request_id}", writable=True) as (
                    _,
                    port,
                ):
                    interrupt(
                        [
                            "smbclient",
                            "//127.0.0.1/nas",
                            "-p",
                            str(port),
                            "-N",
                            "-U",
                            "guest",
                            "--option=client min protocol=SMB3",
                            "-c",
                            f'put "{source}" "{name}"',
                        ],
                        access,
                    )

        assert (readonly / name).read_bytes() == expected
        assert run("check-file", endpoints, config, inode)["healthy_replicas"] == 2
        # A fresh access process sees the committed state and accepts a new CAS write.
        with mounted(f"restart-{label}") as (path, _):
            assert (path / name).read_bytes() == expected
            with open(path / name, "r+b", buffering=0) as writer:
                assert os.pwrite(writer.fileno(), b"Z", 0) == 1
                os.fsync(writer.fileno())
            assert (readonly / name).read_bytes() == b"Z" + expected[1:]
            assert run("check-file", endpoints, config, inode)["all_healthy"]
        print(
            f"PASS: {label}, exact committed state and writable restart",
            flush=True,
        )

    for kind in ["fuse", "smb"] if smb else ["fuse"]:
        for point in ("first_replica", "both_replicas", "published"):
            exercise(kind, point)
        exercise(kind, "both_replicas", outage="election")
        exercise(kind, "both_replicas", outage="quorum")
        exercise(kind, "both_replicas", outage="reply-loss")
    exercise("fuse", "staged")
    exercise("fuse", "first_stage_write")
    if smb:
        exercise("disconnect", "first_replica")
