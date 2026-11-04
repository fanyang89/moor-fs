#!/usr/bin/env python3
"""Export a nas-fs FUSE mount as a single-user SMB3 share (read-only by default)."""

import argparse
from contextlib import contextmanager
import ipaddress
import os
from pathlib import Path
import pwd
import signal
import socket
import subprocess
import sys
import time


@contextmanager
def export(mountpoint, directory, port=0, listen="127.0.0.1", writable=False):
    mountpoint = Path(mountpoint).resolve(strict=True)
    directory = Path(directory).resolve()
    listen = str(ipaddress.IPv4Address(listen))
    user = pwd.getpwuid(os.getuid()).pw_name
    for value in (str(mountpoint), str(directory), user):
        if any(c in value for c in "\r\n%\\"):
            raise ValueError(
                "Samba configuration values cannot contain newlines, %, or backslashes"
            )
    encoded = str(mountpoint).replace(" ", "\\040").replace("\t", "\\011")
    mounted = False
    for line in Path("/proc/self/mountinfo").read_text().splitlines():
        fields, filesystem = line.split(" - ", 1)
        if fields.split()[4] == encoded and filesystem.split()[:2] == [
            "fuse",
            "nas-fs",
        ]:
            mounted = True
            if writable and "rw" not in fields.split()[5].split(","):
                raise ValueError("writable export requires a writable nas-fs mount")
    if not mounted or mountpoint.stat().st_uid != os.getuid():
        raise ValueError("run as the owner of an existing nas-fs FUSE mount")
    if not 0 <= port <= 65535:
        raise ValueError("invalid TCP port")
    directory.mkdir(mode=0o700)
    for name in ("private", "state", "cache", "lock", "run", "ncalrpc"):
        (directory / name).mkdir()
    if port == 0:
        with socket.socket() as sock:
            sock.bind((listen, 0))
            port = sock.getsockname()[1]
    config = directory / "smb.conf"
    config.write_text(f"""[global]
server role = standalone server
workgroup = WORKGROUP
netbios name = NASFS
interfaces = {listen}
bind interfaces only = yes
smb ports = {port}
disable netbios = yes
server min protocol = SMB3
map to guest = Bad User
guest account = {user}
private dir = {directory}/private
state directory = {directory}/state
cache directory = {directory}/cache
lock directory = {directory}/lock
pid directory = {directory}/run
ncalrpc dir = {directory}/ncalrpc
log file = {directory}/samba.log
load printers = no
printing = bsd
printcap name = /dev/null
smb2 leases = no
[nas]
path = {mountpoint}
read only = {"no" if writable else "yes"}
guest ok = yes
guest only = yes
follow symlinks = no
oplocks = no
level2 oplocks = no
kernel oplocks = no
use sendfile = no
strict sync = yes
map archive = no
store dos attributes = no
""")
    # A private configuration/state tree never modifies the system Samba service.
    subprocess.run(
        ["testparm", "-s", str(config)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        timeout=15,
    )
    log = directory / "process.log"
    with log.open("w") as output:
        process = subprocess.Popen(
            [
                "smbd",
                "--foreground",
                "--no-process-group",
                "--debug-stdout",
                "--configfile",
                str(config),
            ],
            stdout=output,
            stderr=output,
            start_new_session=True,
        )
    try:
        deadline = time.monotonic() + 15
        while True:
            if process.poll() is not None:
                raise RuntimeError(log.read_text())
            try:
                with socket.create_connection((listen, port), timeout=0.2):
                    break
            except OSError:
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"SMB export did not start; see {log}")
                time.sleep(0.1)
        yield process, port
    except BaseException as error:
        if not isinstance(error, KeyboardInterrupt):
            print(f"SMB export log {log}:\n{log.read_text()[-6000:]}", file=sys.stderr)
        raise
    finally:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mountpoint", type=Path)
    parser.add_argument(
        "state_directory", type=Path, help="new directory for isolated Samba state/logs"
    )
    parser.add_argument("--port", type=int, default=1445)
    parser.add_argument(
        "--listen", default="127.0.0.1", help="local IPv4 address to bind"
    )
    parser.add_argument(
        "--writable",
        action="store_true",
        help="enable file operations on a writable nas-fs mount",
    )
    args = parser.parse_args()

    def stop(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop)
    try:
        with export(
            args.mountpoint, args.state_directory, args.port, args.listen, args.writable
        ) as (
            process,
            port,
        ):
            print(
                f"{'Writable' if args.writable else 'Read-only'} guest share: //{args.listen}/nas (TCP {port})",
                flush=True,
            )
            if process.wait() != 0:
                raise RuntimeError(f"Samba exited; see {args.state_directory}")
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
