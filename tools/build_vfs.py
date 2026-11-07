#!/usr/bin/env python3
"""Build the pinned Samba daemon and moor_fs module without installation."""

import argparse
import json
import os
from pathlib import Path
import subprocess
from deps import check

ROOT = Path(__file__).resolve().parent.parent
SAMBA = ROOT / "third_party/samba"


def run(*command, cwd=ROOT, **kwargs):
    subprocess.run(command, cwd=cwd, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    check()
    # Generated includes and the PIDL rules require Samba's standard bin layout.
    if (SAMBA / "bin").is_symlink():
        raise RuntimeError("Samba bin must be a normal build directory")
    if not (SAMBA / "bin/default/include/config.h").exists():
        run(
            "./configure",
            f"--prefix={ROOT / '.deps-build/samba-install'}",
            "--without-ad-dc",
            "--without-ads",
            "--without-ldap",
            "--without-pam",
            "--without-winbind",
            "--without-json",
            "--without-libarchive",
            "--without-regedit",
            "--without-systemd",
            "--without-quotas",
            "--disable-python",
            cwd=SAMBA,
        )
    run(
        "./buildtools/bin/waf",
        "build",
        "--targets=smbd/smbd,vfs_audit",
        f"-j{args.jobs}",
        cwd=SAMBA,
        env=dict(os.environ, PYTHONHASHSEED="1"),
    )
    run("zig", "build", "ipc-bridge", "-Doptimize=safe")
    database = json.loads((SAMBA / "bin/default/compile_commands.json").read_text())
    source = next(item for item in database if item["file"].endswith("/vfs_default.c"))
    # Reuse the exact generated include/config flags for this pinned VFS ABI.
    flags = [
        arg
        for arg in source["arguments"][1:]
        if arg.startswith(("-I", "-D", "-f", "-W", "-O", "-g"))
        and not any(
            value in arg for value in ("STATIC_", "samba_init_module", "vfs_audit_init")
        )
    ]
    module = ROOT / "zig-out/lib/moor_fs.so"
    run(
        source["arguments"][0],
        *flags,
        f"-I{ROOT / 'src'}",
        "-shared",
        str(ROOT / "src/vfs_moor_fs.c"),
        str(ROOT / "zig-out/lib/libmoor-ipc.a"),
        "-o",
        str(module),
        cwd=source["directory"],
    )
    link = SAMBA / "bin/modules/vfs/moor_fs.so"
    if link.is_symlink() and link.resolve() == module:
        pass
    elif link.exists() or link.is_symlink():
        raise RuntimeError(f"Refusing to replace unrelated module: {link}")
    else:
        link.symlink_to(module)
    print(f"Built {module}; use only with {SAMBA / 'bin/smbd'}")


if __name__ == "__main__":
    main()
