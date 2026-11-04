"""SMB clients exercise independent access nodes backed by the same metadata."""

from contextlib import ExitStack
import hashlib
import json
import subprocess

from serve_smb import export


def test_exports(directory, mounts, endpoints, config, roots, run, leader, stop, start):
    request_id = 4000

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

    folder = apply({"create": {"parent": 1, "name": "smb-files", "kind": "directory"}})
    inode = apply({"create": {"parent": folder, "name": "report.bin", "kind": "file"}})
    source = directory / "smb-source.bin"
    content = bytes(range(256)) * 5000 + b"SMB-tail"

    def publish(version, expected, data):
        source.write_bytes(data)
        result = run(
            "put-file",
            endpoints,
            config,
            json.dumps(
                {
                    "request_id": 5000 + version,
                    "inode": inode,
                    "version_id": version,
                    "expected_version": expected,
                    "backends": [1, 2],
                }
            ),
            source,
        )
        assert result["status"] == "ok", result

    publish(400, 0, content)
    with ExitStack() as stack:
        ports = [
            stack.enter_context(export(path, directory / f"smb-export-{i}"))[1]
            for i, path in enumerate(mounts)
        ]

        def smb(i, command, errors=()):
            result = subprocess.run(
                [
                    "smbclient",
                    "//127.0.0.1/nas",
                    "-p",
                    str(ports[i]),
                    "-N",
                    "-U",
                    "guest",
                    "--option=client min protocol=SMB3",
                    "-c",
                    command,
                ],
                capture_output=True,
                text=True,
                timeout=45,
            )
            output = result.stdout + result.stderr
            if errors:
                assert any(error in output for error in errors), output
            else:
                assert result.returncode == 0 and "NT_STATUS_" not in output, output
            return output

        def download(i, expected, name="report.bin"):
            target = directory / f"smb-download-{i}.bin"
            target.unlink(missing_ok=True)
            smb(i, f'get "smb-files/{name}" "{target}"')
            assert target.read_bytes() == expected

        for i in range(2):
            listing = smb(i, 'ls "smb-files/*"')
            assert "report.bin" in listing and str(len(content)) in listing, listing
            download(i, content)
        denied = ("NT_STATUS_ACCESS_DENIED", "NT_STATUS_MEDIA_WRITE_PROTECTED")
        smb(0, f'put "{source}" "smb-files/forbidden.bin"', denied)
        smb(0, 'del "smb-files/report.bin"', denied)
        smb(1, 'rename "smb-files/report.bin" "smb-files/forbidden.bin"', denied)
        smb(1, 'mkdir "forbidden"', denied)
        assert run("lookup", endpoints, folder, "forbidden.bin") is None
        assert run("lookup", endpoints, 1, "forbidden") is None
        download(0, content)

        # Same-size replacement must not reuse bytes from the old version.
        replacement = b"r" * len(content)
        publish(401, 400, replacement)
        for i in range(2):
            download(i, replacement)
        apply({"rename": {"id": inode, "parent": folder, "name": "renamed.bin"}})
        for i in range(2):
            listing = smb(i, 'ls "smb-files/*"')
            assert "renamed.bin" in listing and "report.bin" not in listing, listing
            download(i, replacement, "renamed.bin")

        name = f"401-{hashlib.sha256(replacement).hexdigest()}"
        copies = [root / "objects" / name for root in roots]
        try:
            copies[0].write_bytes(b"corrupt")
            download(0, replacement, "renamed.bin")
            copies[1].write_bytes(b"corrupt")
            smb(
                1,
                f'get "smb-files/renamed.bin" "{directory / "bad-download"}"',
                (
                    "NT_STATUS_IO_DEVICE_ERROR",
                    "NT_STATUS_UNSUCCESSFUL",
                    "NT_STATUS_INTERNAL_ERROR",
                ),
            )
        finally:
            for copy in copies:
                copy.write_bytes(replacement)
        old = leader()
        stop(old)
        try:
            leader()
            download(1, replacement, "renamed.bin")
        finally:
            start(old)
        publish(402, 401, b"")
        download(0, b"", "renamed.bin")
        apply({"remove": {"id": inode}})
        assert "renamed.bin" not in smb(1, 'ls "smb-files/*"')
    print(
        "PASS: two read-only SMB exports over FUSE, listing/download, denied mutations, version/rename visibility, corruption fallback and metadata failover",
        flush=True,
    )
