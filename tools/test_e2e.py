#!/usr/bin/env python3
"""Run the metadata/object E2E suite against two isolated real Samba/CIFS backends."""

import argparse
import hashlib
import os
from pathlib import Path
import pwd
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time


REPO = Path(__file__).resolve().parent.parent


def run(*args, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, timeout=30, **kwargs)


def stop_group(process):
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        pass
    finally:
        # The group leader can exit before its children (including timed-out CLIs).
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)


def worker(args):
    def interrupted(signum, frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, interrupted)
    directory = args.directory
    account = pwd.getpwuid(args.uid)
    servers = []
    mounted = []
    success = False

    def mkdir(path):
        path.mkdir()
        os.chown(path, args.uid, args.gid)
        return path

    def start(server):
        log = open(server["log"], "a")
        try:
            server["process"] = subprocess.Popen(
                [
                    "smbd",
                    "--foreground",
                    "--no-process-group",
                    "--debug-stdout",
                    "--configfile",
                    str(server["config"]),
                ],
                stdout=log,
                stderr=log,
                start_new_session=True,
            )
        finally:
            log.close()
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if server["process"].poll() is not None:
                raise RuntimeError(server["log"].read_text())
            try:
                with socket.create_connection(
                    ("127.0.0.1", server["port"]), timeout=0.2
                ):
                    return
            except OSError:
                time.sleep(0.1)
        raise TimeoutError("Samba did not listen within 15 seconds")

    def stop(server):
        process = server.get("process")
        if process is None:
            return
        stop_group(process)
        server["process"] = None

    def mount(server):
        # A named guest maps to the configured account; an empty username is anonymous.
        options = (
            f"guest,username=guest,port={server['port']},vers=3.1.1,uid={args.uid},gid={args.gid},"
            "forceuid,forcegid,nosuid,nodev,noexec,cache=none,actimeo=0"
        )
        run("mount.cifs", server["source"], server["mount"], "-o", options)
        mounted.append(server["mount"])
        lines = Path("/proc/self/mountinfo").read_text().splitlines()
        assert any(
            f" {server['mount']} " in line and " - cifs " in line for line in lines
        )
        server["mountinfo"] = next(
            line
            for line in lines
            if f" {server['mount']} " in line and " - cifs " in line
        )

    def unmount_all():
        while mounted:
            run("umount", mounted[-1])
            mounted.pop()

    try:
        for i in range(2):
            base = mkdir(directory / f"samba-{i}")
            export = mkdir(base / "export")
            target = mkdir(base / "mount")
            for name in ("private", "state", "cache", "lock", "run", "ncalrpc"):
                mkdir(base / name)
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", 0))
                port = sock.getsockname()[1]
            config = base / "smb.conf"
            config.write_text(f"""[global]
server role = standalone server
log level = 1
workgroup = WORKGROUP
netbios name = NASE2E{i}
interfaces = 127.0.0.1
bind interfaces only = yes
hosts allow = 127.0.0.1
smb ports = {port}
disable netbios = yes
server min protocol = SMB3
map to guest = Bad User
guest account = {account.pw_name}
private dir = {base}/private
state directory = {base}/state
cache directory = {base}/cache
lock directory = {base}/lock
pid directory = {base}/run
ncalrpc dir = {base}/ncalrpc
log file = {base}/samba.log
load printers = no
printing = bsd
printcap name = /dev/null
[data{i}]
path = {export}
read only = no
guest ok = yes
follow symlinks = no
""")
            server = {
                "source": f"//127.0.0.1/data{i}",
                "config": config,
                "log": base / "process.log",
                "port": port,
                "mount": target,
                "export": export,
            }
            servers.append(server)
            start(server)
            mount(server)
        print(
            "PASS: two loopback Samba servers and real SMB 3.1.1 CIFS mounts",
            flush=True,
        )

        def drop_privileges():
            os.setgroups([])
            os.setgid(args.gid)
            os.setuid(args.uid)

        for server in servers:
            run(
                sys.executable,
                "-c",
                "import os,sys; p=sys.argv[1]; os.mkdir(p+'/probe'); os.rmdir(p+'/probe')",
                server["mount"],
                preexec_fn=drop_privileges,
            )

        command = [
            sys.executable,
            str(REPO / "tools/test_cluster.py"),
            args.executable,
            "--backend-roots",
            *(str(s["mount"] / "nas-fs") for s in servers),
            "--backend-server-roots",
            *(str(s["export"] / "nas-fs") for s in servers),
            "--smb-ports",
            *(str(s["port"]) for s in servers),
        ]
        if args.fuse:
            command.append("--fuse")
        if args.smb:
            command.append("--smb")
        if args.repair_faults:
            command.append("--repair-faults")
        environment = dict(os.environ, HOME=account.pw_dir, TMPDIR=str(directory))
        # Metadata processes and file operations run as the original ordinary user.
        cluster = subprocess.Popen(
            command,
            cwd=REPO,
            env=environment,
            preexec_fn=drop_privileges,
            start_new_session=True,
        )
        try:
            if cluster.wait(timeout=600 if args.smb else 360) != 0:
                raise RuntimeError("cluster E2E failed")
        finally:
            stop_group(cluster)

        # Drop CIFS mounts/client caches, restart the servers, and verify all objects.
        unmount_all()
        for server in servers:
            stop(server)
            start(server)
            mount(server)
            paths = list((server["mount"] / "nas-fs/objects").iterdir())
            assert len(paths) >= 3, paths
            for path in paths:
                assert (
                    hashlib.sha256(path.read_bytes()).hexdigest()
                    == path.name.split("-", 1)[1]
                )
        print(
            "PASS: Samba restart and cold CIFS remount preserve all object hashes",
            flush=True,
        )
        success = True
    finally:
        try:
            unmount_all()
        except BaseException:
            success = False
            raise
        finally:
            for server in reversed(servers):
                stop(server)
            if success:
                shutil.rmtree(directory)
            else:
                for server in servers:
                    print(server.get("mountinfo", "mount not reached"), file=sys.stderr)
                    if server["log"].exists():
                        print(
                            f"\n{server['log']}:\n{server['log'].read_text()[-6000:]}",
                            file=sys.stderr,
                        )
                print(f"E2E artifacts retained: {directory}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", nargs="?", default="zig-out/bin/nas-fs")
    parser.add_argument("--fuse", action="store_true")
    parser.add_argument("--smb", action="store_true")
    parser.add_argument("--repair-faults", action="store_true")
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--directory", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--uid", type=int, help=argparse.SUPPRESS)
    parser.add_argument("--gid", type=int, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.worker:
        if (
            os.geteuid() != 0
            or args.directory is None
            or args.uid is None
            or args.gid is None
        ):
            parser.error("worker requires root and explicit workspace/identity")
        worker(args)
        return
    for name in ("smbd", "smbclient", "mount.cifs", "umount", "unshare", "sudo"):
        if shutil.which(name) is None:
            parser.error(f"required executable not found: {name}")
    if args.smb:
        for name in ("testparm", "fusermount3"):
            if shutil.which(name) is None:
                parser.error(f"required executable not found: {name}")
    executable = str(Path(args.executable).resolve(strict=True))
    run("sudo", "-n", "true")
    run("sudo", "-n", "unshare", "--mount", "--propagation", "private", "true")
    base = Path(os.environ.get("TMPDIR", "/tmp/opencode"))
    base.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="nas-fs-e2e-", dir=base)).resolve()
    command = [
        "sudo",
        "-n",
        "unshare",
        "--mount",
        "--propagation",
        "private",
        sys.executable,
        str(Path(__file__).resolve()),
        executable,
        "--worker",
        "--directory",
        str(directory),
        "--uid",
        str(os.getuid()),
        "--gid",
        str(os.getgid()),
    ]
    if args.fuse:
        command.append("--fuse")
    if args.smb:
        command.append("--smb")
    if args.repair_faults:
        command.append("--repair-faults")
    result = subprocess.run(command)
    if result.returncode:
        print(f"E2E failed; workspace: {directory}", file=sys.stderr)
    else:
        assert not directory.exists(), "successful E2E did not clean up"
    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
