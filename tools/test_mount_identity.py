"""Real mount disappearance and wrong-share checks inside the E2E private namespace."""

import json
import os
import subprocess


def test_mount_identity(
    directory, roots, ports, mappings, endpoints, config, inode, version, source, run
):
    root = roots[0]
    mountpoint = root.parent
    original = run("get", endpoints, inode)
    failure_count = 0

    def command(*args):
        subprocess.run(
            ["sudo", "-n", *map(str, args)],
            check=True,
            timeout=30,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def mount(index):
        options = f"guest,username=guest,port={ports[index]},vers=3.1.1,uid={os.getuid()},gid={os.getgid()},forceuid,forcegid,nosuid,nodev,noexec,cache=none,actimeo=0"
        command("mount.cifs", f"//127.0.0.1/data{index}", mountpoint, "-o", options)

    def rejected():
        nonlocal failure_count
        failure_count += 1
        report = run("check-file", endpoints, config, inode)
        assert report["replicas"][0]["reason"] == "BackendMountMismatch", report
        assert report["replicas"][1]["status"] == "healthy", report
        for flags in ([], ["--replace-corrupt"]):
            result = run(
                "repair-file", endpoints, config, inode, 1, *flags, success=False
            )
            assert "BackendMountMismatch" in result.stdout + result.stderr
        request = {
            "request_id": 15000,
            "inode": inode,
            "version_id": 15000,
            "expected_version": version,
            "backends": [1, 2],
        }
        result = run(
            "put-file", endpoints, config, json.dumps(request), source, success=False
        )
        assert "BackendMountMismatch" in result.stdout + result.stderr
        assert run("get", endpoints, inode) == original
        assert run("file-version", endpoints, 15000) is None
        downloaded = directory / f"identity-fallback-{failure_count}"
        result = run("get-file", endpoints, config, inode, downloaded)
        assert result["backend"] == 2, result
        assert downloaded.read_bytes() == source.read_bytes()

    # Keep a descriptor to the old CIFS mount while hiding it and exposing local storage.
    pinned = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    mounted = True
    local_created = False
    try:
        command("umount", "-l", mountpoint)
        mounted = False
        root.mkdir()
        local_created = True
        rejected()
        assert list(root.iterdir()) == [], (
            "upload initialized the exposed local directory"
        )
        root.rmdir()
        local_created = False
        mount(1)
        mounted = True
        rejected()
        assert not any(
            path.name.startswith("15000-") for path in (root / "objects").iterdir()
        )
        command("umount", mountpoint)
        mounted = False
        mount(0)
        mounted = True
    finally:
        os.close(pinned)
        if local_created:
            root.rmdir()
        if not mounted:
            mount(0)
        elif (
            run("check-file", endpoints, config, inode)["replicas"][0]["status"]
            != "healthy"
        ):
            command("umount", mountpoint)
            mount(0)

    assert run("check-file", endpoints, config, inode)["all_healthy"]
    assert run("get", endpoints, inode) == original

    local_staging = directory / "local-staging-overmount"
    local_staging.mkdir()
    command("mount", "--bind", local_staging, root / "staging")
    try:
        rejected()
        assert list(local_staging.iterdir()) == []
    finally:
        command("umount", root / "staging")
    assert run("check-file", endpoints, config, inode)["all_healthy"]

    # Reject duplicate UNC/address identities even through different mapping paths.
    duplicate = json.loads(json.dumps(mappings))
    duplicate[1]["mount"] = dict(duplicate[0]["mount"])
    invalid = directory / "duplicate-mount.json"
    invalid.write_text(json.dumps(duplicate))
    result = run("check-file", endpoints, invalid, inode, success=False)
    assert "DuplicateBackendMount" in result.stdout + result.stderr
    duplicate[1]["mount"]["source"] = "//alias/data0"
    invalid.write_text(json.dumps(duplicate))
    result = run("check-file", endpoints, invalid, inode, success=False)
    assert "DuplicateBackendMount" in result.stdout + result.stderr
    legacy = directory / "missing-identity.json"
    legacy.write_text(json.dumps([{"id": 1, "root": str(root)}]))
    result = run("check-file", endpoints, legacy, inode, success=False)
    assert "BackendIdentityRequired" in result.stdout + result.stderr
    print(
        "PASS: detached CIFS/local fallback, wrong share and nested staging mount rejected; reads fall back, correct remount recovers, duplicate/missing identities rejected",
        flush=True,
    )
