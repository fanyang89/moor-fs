#!/usr/bin/env python3
"""Run one FUSE/SMB access node, stopping both services when either exits."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from serve_smb import export


def mount_record(path):
    encoded = (
        str(path)
        .replace("\\", "\\134")
        .replace(" ", "\\040")
        .replace("\t", "\\011")
        .replace("\n", "\\012")
    )
    for line in Path("/proc/self/mountinfo").read_text().splitlines():
        fields, filesystem = line.split(" - ", 1)
        if fields.split()[4] == encoded:
            return filesystem.split()[:2]
    return None


def serve(args):
    mountpoint = args.mountpoint.resolve(strict=True)
    state = args.state_directory.resolve()
    executable = args.executable.resolve(strict=True)
    config = args.backends.resolve(strict=True)
    if mount_record(mountpoint) is not None:
        raise ValueError("mountpoint is already mounted")
    if state.is_relative_to(mountpoint):
        raise ValueError("state directory must be outside the mountpoint")
    # Lock the underlying directory, not a file hidden by the subsequent mount.
    lock = os.open(mountpoint, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if mount_record(mountpoint) is not None or any(mountpoint.iterdir()):
            raise ValueError("mountpoint must be an empty, unmounted directory")
        state.mkdir(mode=0o700)
        command = [
            str(executable),
            "mount",
            args.endpoint,
            str(mountpoint),
            "--backends",
            str(config),
        ]
        if args.write_backends:
            command += ["--write-backends", args.write_backends]
        log = state / "fuse.log"
        with log.open("w") as output:
            fuse = subprocess.Popen(
                command, stdout=output, stderr=output, start_new_session=True
            )
        try:
            deadline = time.monotonic() + 30
            while mount_record(mountpoint) != ["fuse", "nas-fs"]:
                if fuse.poll() is not None:
                    raise RuntimeError(f"FUSE exited ({fuse.returncode}); see {log}")
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"FUSE mount timed out; see {log}")
                time.sleep(0.05)
            with export(
                mountpoint,
                state / "s",
                args.port,
                args.listen,
                bool(args.write_backends),
            ) as (smb, port):
                if fuse.poll() is not None:
                    raise RuntimeError(f"FUSE exited ({fuse.returncode}); see {log}")
                print(
                    json.dumps(
                        {
                            "ready": True,
                            "mountpoint": str(mountpoint),
                            "fuse_pid": fuse.pid,
                            "smb_pid": smb.pid,
                            "port": port,
                            "writable": bool(args.write_backends),
                        }
                    ),
                    flush=True,
                )
                while True:
                    for name, process in (("FUSE", fuse), ("Samba", smb)):
                        if process.poll() is not None:
                            raise RuntimeError(
                                f"{name} exited ({process.returncode}); see {state}"
                            )
                    time.sleep(0.1)
        finally:
            # export() has already stopped Samba, including its worker process group.
            try:
                if mount_record(mountpoint) == ["fuse", "nas-fs"]:
                    subprocess.run(
                        ["fusermount3", "-u", str(mountpoint)], check=True, timeout=15
                    )
            finally:
                if fuse.poll() is None:
                    fuse.terminate()
                try:
                    fuse.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    fuse.kill()
                    fuse.wait(timeout=5)
    finally:
        os.close(lock)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("endpoint", help="comma-separated metadata API endpoints")
    parser.add_argument("mountpoint", type=Path, help="existing empty directory")
    parser.add_argument(
        "state_directory",
        type=Path,
        help="new directory for this run's logs and Samba state",
    )
    parser.add_argument("--executable", type=Path, default=Path("zig-out/bin/nas-fs"))
    parser.add_argument("--backends", type=Path, required=True)
    parser.add_argument(
        "--write-backends", help="opt in to writes using two backend IDs, e.g. 1,2"
    )
    parser.add_argument("--port", type=int, default=1445)
    parser.add_argument("--listen", default="127.0.0.1")
    args = parser.parse_args()
    stopping = False

    def stop(signum, frame):
        nonlocal stopping
        if not stopping:
            stopping = True
            raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        serve(args)
    except KeyboardInterrupt:
        return 0
    except Exception as error:
        print(f"access node failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
