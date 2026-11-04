"""Mounted-directory object I/O checks against the real metadata cluster."""

import hashlib
import json
import subprocess
from concurrent.futures import ThreadPoolExecutor


def test_data(executable, directory, endpoints, run, leader, stop, start):
    roots = [directory / "nas-a", directory / "nas-b"]
    for root in roots:
        root.mkdir()
    config = directory / "backends.json"
    config.write_text(
        json.dumps([{"id": i + 1, "root": str(root)} for i, root in enumerate(roots)])
    )
    source = directory / "source.bin"
    content = bytes(range(256)) * 5000 + b"tail"
    source.write_bytes(content)
    inode = run(
        "apply",
        endpoints,
        json.dumps(
            {
                "request_id": 2000,
                "command": {
                    "create": {"parent": 1, "name": "data-file", "kind": "file"}
                },
            }
        ),
    )["inode"]

    def upload(request, version, expected, path=source, backends=(1, 2), **kwargs):
        return run(
            "put-file",
            endpoints,
            config,
            json.dumps(
                {
                    "request_id": request,
                    "inode": inode,
                    "version_id": version,
                    "expected_version": expected,
                    "backends": list(backends),
                }
            ),
            path,
            **kwargs,
        )

    def object_path(root, version, data):
        return root / "objects" / f"{version}-{hashlib.sha256(data).hexdigest()}"

    def download(name, expected, backend):
        target = directory / name
        result = run("get-file", endpoints, config, inode, target)
        assert result["backend"] == backend, result
        assert target.read_bytes() == expected
        return target

    # A failed second replica must not publish or overwrite its corrupt object.
    for child in ("objects", "staging"):
        (roots[1] / child).mkdir()
    bad = object_path(roots[1], 200, content)
    bad.write_bytes(b"corrupt")
    failure = upload(2001, 200, 0, success=False)
    assert "ChecksumMismatch" in failure.stdout + failure.stderr, (
        failure.stdout,
        failure.stderr,
    )
    assert bad.read_bytes() == b"corrupt"
    assert run("get", endpoints, inode)["current_version"] == 0
    assert run("file-version", endpoints, 200) is None
    assert object_path(roots[0], 200, content).read_bytes() == content
    assert all(not list((root / "staging").iterdir()) for root in roots)
    bad.unlink()
    assert upload(2001, 200, 0)["status"] == "ok"
    assert upload(2001, 200, 0)["status"] == "ok"
    version = run("file-version", endpoints, 200)
    assert version["size"] == len(content)
    assert version["sha256"] == list(hashlib.sha256(content).digest())
    for root in roots:
        assert object_path(root, 200, content).read_bytes() == content
    target = download("read.bin", content, 1)
    run("get-file", endpoints, config, inode, target, success=False)
    assert target.read_bytes() == content
    offline = directory / "nas-a-offline"
    roots[0].rename(offline)
    try:
        download("unavailable-fallback.bin", content, 2)
    finally:
        offline.rename(roots[0])

    first = object_path(roots[0], 200, content)
    first.write_bytes(b"corrupt")
    download("fallback.bin", content, 2)
    second = object_path(roots[1], 200, content)
    second.write_bytes(b"corrupt")
    missing = directory / "unreadable.bin"
    run("get-file", endpoints, config, inode, missing, success=False)
    assert not missing.exists()
    # Readers reject symlinks rather than following a substituted object.
    first.unlink()
    first.symlink_to(source)
    run("get-file", endpoints, config, inode, missing, success=False)
    first.unlink()
    first.write_bytes(content)
    second.write_bytes(content)

    empty = directory / "empty.bin"
    empty.write_bytes(b"")
    assert upload(2002, 201, 200, empty)["status"] == "ok"
    download("empty-read.bin", b"", 1)
    assert run("file-version", endpoints, 200) == version
    assert first.read_bytes() == content
    # Preflight rejects stale CAS and mismatched replica policy before copying.
    upload(2003, 202, 200, success=False)
    upload(2004, 202, 201, backends=(1, 0), success=False)
    assert not object_path(roots[0], 202, content).exists()

    # Concurrent uploads may leave an unpublished object, never overwrite the winner.
    def competing(i):
        result = subprocess.run(
            [
                executable,
                "put-file",
                endpoints,
                str(config),
                json.dumps(
                    {
                        "request_id": 2010 + i,
                        "inode": inode,
                        "version_id": 210 + i,
                        "expected_version": 201,
                        "backends": [1, 2],
                    }
                ),
                str(source),
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode:
            assert "publication preflight: version_conflict" in result.stderr, (
                result.stderr
            )
            return {"status": "version_conflict"}
        return json.loads(result.stdout)

    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(competing, i) for i in range(2)]
        outcomes = [future.result() for future in futures]
    assert sorted(item["status"] for item in outcomes) == ["ok", "version_conflict"]
    winner = 210 + next(
        i for i, result in enumerate(outcomes) if result["status"] == "ok"
    )
    assert run("get", endpoints, inode)["current_version"] == winner
    old = leader()
    stop(old)
    leader()
    download("after-failover.bin", content, 1)
    start(old)

    run(
        "apply",
        endpoints,
        json.dumps(
            {
                "request_id": 2020,
                "command": {"set_replicas": {"id": inode, "replicas": "one"}},
            }
        ),
    )
    assert upload(2021, 220, winner, empty, backends=(1, 0))["status"] == "ok"
    assert not object_path(roots[1], 220, b"").exists()
    download("single.bin", b"", 1)
    for i in range(3):
        stop(i)
    for i in range(3):
        start(i)
    leader()
    download("after-restart.bin", b"", 1)
    assert run("file-version", endpoints, 200) == version
    assert all(not list((root / "staging").iterdir()) for root in roots)
    print(
        "PASS: object copy/readback, failed replica atomicity, immutable retry, verified read fallback, empty/single replicas and publication race",
        flush=True,
    )
