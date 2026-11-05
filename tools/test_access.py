"""Exercise the access-node CLI lifecycle with real FUSE and SMB clients."""

from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time

from serve_access import mount_record


def test_access(executable, directory, endpoints, config, run):
    mount = directory / "access-mount"
    mount.mkdir()
    script = Path(__file__).with_name("serve_access.py")
    content = b"supervised SMB recovery\n" * 128
    source = directory / "access-source"
    source.write_bytes(content)

    def command(state, *flags):
        return [
            sys.executable,
            str(script),
            endpoints,
            str(mount),
            str(state),
            "--executable",
            executable,
            "--backends",
            str(config),
            "--port",
            "0",
            *flags,
        ]

    def client(status, operation, success=True):
        result = subprocess.run(
            [
                "smbclient",
                "//127.0.0.1/nas",
                "-p",
                str(status["port"]),
                "-N",
                "-U",
                "guest",
                "--option=client min protocol=SMB3",
                "-c",
                operation,
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )
        output = result.stdout + result.stderr
        if success:
            assert result.returncode == 0 and "NT_STATUS_" not in output, output
        else:
            assert result.returncode != 0 or "NT_STATUS_" in output, output

    def stopped(status):
        assert mount_record(mount) is None, "supervisor left a FUSE mount"
        for key in ("fuse_pid", "smb_pid"):
            try:
                os.kill(status[key], 0)
            except ProcessLookupError:
                pass
            else:
                raise AssertionError(f"supervisor left {key} alive")
        with socket.socket() as probe:
            probe.settimeout(1)
            assert probe.connect_ex(("127.0.0.1", status["port"])) != 0

    @contextmanager
    def running(index, writable):
        log = directory / f"access-{index}.log"
        flags = ["--write-backends", "1,2"] if writable else []
        with log.open("w") as output:
            process = subprocess.Popen(
                command(directory / f"ac{index}", *flags), stdout=output, stderr=output
            )
        try:
            deadline = time.monotonic() + 60
            while True:
                assert process.poll() is None, log.read_text()
                lines = [
                    line
                    for line in log.read_text().splitlines()
                    if line.startswith('{"ready":')
                ]
                if lines:
                    status = json.loads(lines[0])
                    assert status["ready"] and status["writable"] == writable, status
                    break
                assert time.monotonic() < deadline, log.read_text()
                time.sleep(0.05)
            yield process, status
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=45)

    # Refuse a nonempty underlying directory without hiding or changing its contents.
    sentinel = mount / "keep"
    sentinel.write_bytes(b"keep")
    result = subprocess.run(
        command(directory / "ac-refused"), capture_output=True, text=True, timeout=15
    )
    assert result.returncode != 0 and sentinel.read_bytes() == b"keep", result
    assert not (directory / "ac-refused").exists()
    sentinel.unlink()

    lock = os.open(mount, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = subprocess.run(
            command(directory / "ac-locked"), capture_output=True, text=True, timeout=15
        )
        assert result.returncode != 0 and not (directory / "ac-locked").exists()
        assert mount_record(mount) is None
    finally:
        os.close(lock)

    for index, failure in enumerate((None, "fuse_pid", "smb_pid", None)):
        with running(index, writable=index in (0, 2)) as (process, status):
            if index == 0:
                client(status, f'put "{source}" supervised.bin')
                inode = run("lookup", endpoints, 1, "supervised.bin")["id"]
                assert run("check-file", endpoints, config, inode)["all_healthy"]
                duplicate = subprocess.run(
                    command(directory / "ac-duplicate"),
                    capture_output=True,
                    text=True,
                    timeout=15,
                )
                assert (
                    duplicate.returncode != 0
                    and not (directory / "ac-duplicate").exists()
                )
            download = directory / f"access-download-{index}"
            client(status, f'get supervised.bin "{download}"')
            assert download.read_bytes() == content
            if not status["writable"]:
                client(status, f'put "{source}" denied.bin', success=False)
                assert run("lookup", endpoints, 1, "denied.bin") is None
            if failure:
                os.kill(status[failure], signal.SIGKILL)
            else:
                process.terminate()
            code = process.wait(timeout=45)
            assert (code != 0) if failure else (code == 0), code
            stopped(status)

    # A post-mount export configuration failure must unwind FUSE as well.
    result = subprocess.run(
        command(directory / "ac-invalid", "--listen", "invalid"),
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert result.returncode != 0, result
    assert mount_record(mount) is None
    assert (directory / "ac-invalid/fuse.log").is_file()
    assert run("check-file", endpoints, config, inode)["all_healthy"]
    print(
        "PASS: access CLI ordered startup/shutdown, child SIGKILL cleanup, same-mount restart, read-only default and startup refusal/failure cleanup",
        flush=True,
    )
