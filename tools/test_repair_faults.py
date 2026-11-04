"""Deterministic repair process-death and namespace-race checks (test-only build)."""

from contextlib import contextmanager
import hashlib
import json
import os
import signal
import subprocess
import time


def test_repair_faults(executable, directory, endpoints, config, roots, run):
    request_id = 12000
    version_id = 12000
    sequence = 0
    content = b"repair checkpoint payload" * 1000
    source = directory / "repair-fault-source"

    def apply(command):
        nonlocal request_id
        request_id += 1
        result = run(
            "apply",
            endpoints,
            json.dumps({"request_id": request_id, "command": command}),
        )
        assert result["status"] == "ok", result
        return result["inode"]

    def publish(inode, expected, data):
        nonlocal request_id, version_id
        request_id += 1
        version_id += 1
        source.write_bytes(data)
        result = run(
            "put-file",
            endpoints,
            config,
            json.dumps(
                {
                    "request_id": request_id,
                    "inode": inode,
                    "version_id": version_id,
                    "expected_version": expected,
                    "backends": [1, 2],
                }
            ),
            source,
        )
        assert result["status"] == "ok", result
        return version_id

    def damaged(name):
        inode = apply({"create": {"parent": 1, "name": name, "kind": "file"}})
        version = publish(inode, 0, content)
        target = (
            roots[0] / "objects" / f"{version}-{hashlib.sha256(content).hexdigest()}"
        )
        target.write_bytes(b"broken")
        return inode, version, target

    @contextmanager
    def stopped(inode, point):
        nonlocal sequence
        sequence += 1
        log = directory / f"repair-stop-{sequence}.log"
        with log.open("w") as output:
            process = subprocess.Popen(
                [
                    executable,
                    "repair-file",
                    endpoints,
                    str(config),
                    str(inode),
                    "1",
                    "--replace-corrupt",
                ],
                stdout=output,
                stderr=output,
                env={**os.environ, "NAS_FS_REPAIR_STOP": point},
            )
        try:
            deadline = time.monotonic() + 30
            while True:
                pid, status = os.waitpid(process.pid, os.WUNTRACED | os.WNOHANG)
                if pid:
                    if os.WIFSTOPPED(status):
                        assert os.WSTOPSIG(status) == signal.SIGSTOP, status
                        break
                    process.returncode = os.waitstatus_to_exitcode(status)
                    raise AssertionError(
                        f"repair missed checkpoint {point}: {log.read_text()}"
                    )
                assert time.monotonic() < deadline, f"checkpoint timed out: {point}"
                time.sleep(0.02)
            yield process, log
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=10)

    def resume(process, log):
        process.send_signal(signal.SIGCONT)
        assert process.wait(timeout=30) == 0, log.read_text()
        result = json.loads(log.read_text())
        assert result["status"] == "repaired", result
        return result

    for point in ("before_replace", "after_replace", "after_sync"):
        inode, version, target = damaged(f"repair-crash-{point}")
        record = run("file-version", endpoints, version)
        before = set((roots[0] / "staging").iterdir())
        with stopped(inode, point) as (process, _):
            expected = b"broken" if point == "before_replace" else content
            assert target.read_bytes() == expected
            process.kill()
            assert process.wait(timeout=10) == -signal.SIGKILL
        assert target.read_bytes() == expected
        assert run("get", endpoints, inode)["current_version"] == version
        assert run("file-version", endpoints, version) == record
        result = run("repair-file", endpoints, config, inode, 1, "--replace-corrupt")
        assert result["status"] == (
            "repaired" if point == "before_replace" else "already_healthy"
        ), result
        assert target.read_bytes() == content
        assert run("check-file", endpoints, config, inode)["healthy_replicas"] == 2
        # The test owns these paths; production repair never garbage-collects unknown staging.
        orphaned = set((roots[0] / "staging").iterdir()) - before
        assert len(orphaned) == (1 if point == "before_replace" else 0), orphaned
        for path in orphaned:
            assert path.read_bytes() == content
            path.unlink()
    print(
        "PASS: repair SIGKILL before/after replacement and after directory sync; retries restore two healthy copies",
        flush=True,
    )

    inode, old_version, target = damaged("repair-publish-race")
    with stopped(inode, "before_replace") as (process, log):
        new_version = publish(inode, old_version, b"new version")
        assert resume(process, log)["version"] == old_version
    assert target.read_bytes() == content
    assert run("get", endpoints, inode)["current_version"] == new_version
    assert run("check-file", endpoints, config, inode)["version"] == new_version

    inode, old_version, target = damaged("repair-unlink-race")
    with stopped(inode, "before_replace") as (process, log):
        apply({"remove": {"id": inode}})
        replacement = apply(
            {"create": {"parent": 1, "name": "repair-unlink-race", "kind": "file"}}
        )
        replacement_version = publish(replacement, 0, b"reused name")
        assert resume(process, log)["version"] == old_version
    assert target.read_bytes() == content
    assert run("get", endpoints, inode) is None
    node = run("lookup", endpoints, 1, "repair-unlink-race")
    assert (
        node["id"] == replacement and node["current_version"] == replacement_version
    ), node
    assert run("check-file", endpoints, config, replacement)["all_healthy"]

    inode, version, target = damaged("repair-replacement-race")
    with stopped(inode, "before_replace") as (process, log):
        run("repair-file", endpoints, config, inode, 1, "--replace-corrupt")
        with target.open("rb", buffering=0) as healthy:
            assert resume(process, log)["version"] == version
            assert healthy.read() == content
    assert target.read_bytes() == content
    assert run("check-file", endpoints, config, inode)["all_healthy"]
    print(
        "PASS: paused repair cannot overwrite a newer metadata version, resurrect an unlinked/reused name or damage a concurrent healthy replacement",
        flush=True,
    )
