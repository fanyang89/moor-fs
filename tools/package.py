#!/usr/bin/env python3
"""Build a native Linux runtime bundle in a new directory, without system installation."""

import argparse
import hashlib
import json
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent


def run(*args, cwd=ROOT):
    return subprocess.run(
        list(map(str, args)), cwd=cwd, check=True, text=True, capture_output=True
    ).stdout.strip()


def dynamic(path, tag):
    return re.findall(rf"\((?:{tag})\).*?\[(.*?)\]", run("readelf", "-d", path))


def package(destination):
    if sys.platform != "linux":
        raise RuntimeError("native Linux packaging is required")
    destination = destination.resolve()
    destination.mkdir(mode=0o755)
    subprocess.run(
        [sys.executable, str(ROOT / "tools/deps.py"), "build-fuse"],
        cwd=ROOT,
        check=True,
    )
    subprocess.run(
        [
            "zig",
            "build",
            "-Dfuse=true",
            "-Doptimize=safe",
            "-Dfault-injection=false",
            "-Drelocatable=true",
            "--prefix",
            str(destination),
        ],
        cwd=ROOT,
        check=True,
    )
    binary = destination / "bin/moor-fs"
    if any(
        selector in binary.read_bytes()
        for selector in (
            b"MOOR_FS_REPAIR_STOP",
            b"MOOR_FS_WRITE_STOP",
            b"MOOR_FS_PUBLISH_STOP",
        )
    ):
        raise RuntimeError("instrumented binary cannot be packaged")
    if dynamic(binary, "RUNPATH|RPATH") != ["$ORIGIN/../lib"]:
        raise RuntimeError("binary does not have the expected relocatable library path")

    library = (ROOT / ".deps-build/libfuse/lib/libfuse3.so").resolve(strict=True)
    names = dynamic(library, "SONAME")
    if len(names) != 1 or not re.fullmatch(r"libfuse3\.so\.\d+", names[0]):
        raise RuntimeError(f"unexpected libfuse SONAME: {names}")
    soname = names[0]
    (destination / "lib").mkdir(exist_ok=True)
    shutil.copy2(library, destination / "lib" / soname)
    for folder in ("tools", "docs", "licenses"):
        (destination / folder).mkdir()
    for script in sorted((ROOT / "tools").glob("test_*.py")) + [
        ROOT / "tools/serve_access.py",
        ROOT / "tools/serve_smb.py",
    ]:
        shutil.copy2(script, destination / "tools" / script.name)
    for document in (ROOT / "docs").glob("*.md"):
        shutil.copy2(document, destination / "docs" / document.name)
    shutil.copy2(ROOT / "README.md", destination / "README.md")
    shutil.copy2(
        ROOT / "third_party/README.md", destination / "licenses/DEPENDENCIES.md"
    )
    for dependency in (ROOT / "third_party").iterdir():
        if dependency.is_dir():
            for notice in (
                "LICENSE",
                "COPYING",
                "COPYING.LIB",
                "LGPL2.txt",
                "GPL2.txt",
                "libraries/liblmdb/LICENSE",
            ):
                source = dependency / notice
                if source.is_file():
                    shutil.copy2(
                        source,
                        destination
                        / "licenses"
                        / f"{dependency.name}-{Path(notice).name}",
                    )

    launcher = destination / "bin/moor-fs-access"
    launcher.write_text(
        '#!/bin/sh\nset -eu\nROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)\nexec python3 -B "$ROOT/tools/serve_access.py" --executable "$ROOT/bin/moor-fs" "$@"\n'
    )
    launcher.chmod(0o755)
    with tempfile.TemporaryDirectory(
        prefix="nas-package-check-", dir=destination.parent
    ) as working:
        loaded = run("ldd", binary, cwd=working)
        if "not found" in loaded:
            raise RuntimeError(loaded)
        fuse_lines = [
            line
            for line in loaded.splitlines()
            if line.strip().startswith(soname + " => ")
        ]
        if len(fuse_lines) != 1:
            raise RuntimeError(f"packaged libfuse not loaded: {loaded}")
        resolved = fuse_lines[0].split("=>", 1)[1].rsplit(" (", 1)[0].strip()
        if Path(resolved).resolve() != destination / "lib" / soname:
            raise RuntimeError(f"libfuse resolved outside the bundle: {resolved}")
        run(binary, "--help", cwd=working)
        run(launcher, "--help", cwd=working)
    dependencies = {
        line.strip().split(" => ", 1)[0]
        for line in loaded.splitlines()
        if " => " in line
    } - {soname}
    manifest = {
        "format": 1,
        "git_commit": run("git", "rev-parse", "HEAD"),
        "source_tree_dirty": bool(run("git", "status", "--porcelain")),
        "submodules": run("git", "submodule", "status", "--recursive").splitlines(),
        "zig": run("zig", "version"),
        "architecture": platform.machine(),
        "libc": list(platform.libc_ver()),
        "optimize": "safe",
        "fault_injection": False,
        "bundled_library": soname,
        "system_libraries": sorted(dependencies),
    }
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    files = sorted(path for path in destination.rglob("*") if path.is_file())
    (destination / "SHA256SUMS").write_text(
        "".join(
            f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.relative_to(destination).as_posix()}\n"
            for path in files
        )
    )
    run("sha256sum", "-c", "SHA256SUMS", cwd=destination)
    print(f"Bundle ready: {destination}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "destination", type=Path, help="new output directory; parent must exist"
    )
    args = parser.parse_args()
    try:
        package(args.destination)
    except subprocess.CalledProcessError as error:
        print(error.stderr or str(error), file=sys.stderr)
        return 1
    except Exception as error:
        print(f"packaging failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
