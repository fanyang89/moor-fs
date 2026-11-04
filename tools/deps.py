#!/usr/bin/env python3
"""Initialize, validate, and build pinned native dependencies without root."""

import argparse
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / ".deps-build" / "libfuse"
SOURCES = {
    "samba": ("COPYING", "source3/include/vfs.h"),
    "libfuse": ("LICENSE", "include/fuse_lowlevel.h"),
    "cifs-utils": ("COPYING", "mount.cifs.c"),
    "grpc-lite": ("LICENSE", "build.zig.zon"),
    "raftz": ("LICENSE", "build.zig.zon"),
    "zookeeper-zig": ("LICENSE", "build.zig.zon"),
}


def run(*args, cwd=ROOT, capture=False):
    return subprocess.run(
        args,
        cwd=cwd,
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else None,
    )


def check():
    for name, files in SOURCES.items():
        relative = f"third_party/{name}"
        entry = run(
            "git", "ls-files", "--stage", "--", relative, capture=True
        ).stdout.split()
        if len(entry) != 4 or entry[0] != "160000":
            raise RuntimeError(f"{relative}: missing pinned gitlink")
        source = ROOT / relative
        if not (source / ".git").exists():
            raise RuntimeError(f"{relative}: run python3 tools/deps.py init")
        actual = run(
            "git", "rev-parse", "HEAD", cwd=source, capture=True
        ).stdout.strip()
        if actual != entry[1]:
            raise RuntimeError(
                f"{relative}: checkout {actual} differs from gitlink {entry[1]}"
            )
        if run("git", "status", "--porcelain", cwd=source, capture=True).stdout:
            raise RuntimeError(f"{relative}: source checkout has local changes")
        for file in files:
            if not (source / file).is_file():
                raise RuntimeError(f"{relative}: missing {file}")
        print(f"OK {relative} {actual}", flush=True)
    status = run("git", "submodule", "status", "--recursive", capture=True).stdout
    if any(line.startswith(("-", "+", "U")) for line in status.splitlines()):
        raise RuntimeError(
            "Nested submodules are uninitialized or differ from pinned commits"
        )


def build_fuse():
    check()
    BUILD.parent.mkdir(parents=True, exist_ok=True)
    args = ["meson", "setup"]
    if (BUILD / "meson-private/coredata.dat").exists():
        args.append("--reconfigure")
    run(
        *args,
        str(BUILD),
        str(ROOT / "third_party/libfuse"),
        "--backend=ninja",
        "--buildtype=debugoptimized",
        "-Dutils=false",
        "-Dexamples=false",
        "-Dtests=false",
        "-Duseroot=false",
    )
    run("meson", "compile", "-C", str(BUILD))
    probe = BUILD / "fuse-probe"
    run(
        "zig",
        "cc",
        str(ROOT / "tools/fuse_probe.c"),
        "-I",
        str(ROOT / "third_party/libfuse/include"),
        "-I",
        str(BUILD),
        "-L",
        str(BUILD / "lib"),
        f"-Wl,-rpath,{BUILD / 'lib'}",
        "-lfuse3",
        "-o",
        str(probe),
    )
    run(str(probe))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("init", "check", "build-fuse"))
    action = parser.parse_args().action
    if action == "init":
        run("git", "submodule", "update", "--init", "--recursive", "--depth", "1")
        check()
    elif action == "check":
        check()
    else:
        build_fuse()


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Dependency operation failed: {error}", file=sys.stderr)
        sys.exit(1)
