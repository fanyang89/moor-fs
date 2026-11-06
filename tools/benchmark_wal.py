"""Measure warm WAL FUSE read/stat latency; emit one JSON object per case."""

import argparse
import json
import math
import os
from pathlib import Path
import platform
import re
import statistics
import time
import uuid


def trace_samples(paths, offsets):
    stages = {}
    pattern = re.compile(rb"latency op=([\w-]+) id=\d+ size=\d+ wal=\d+ ns=\{([^}]+)\}")
    for path, offset in zip(paths, offsets):
        with path.open("rb") as stream:
            stream.seek(offset)
            for operation, values in pattern.findall(stream.read()):
                stages.setdefault(operation.decode(), []).append(
                    [int(value.strip()) for value in values.split(b",")]
                )
    return stages


def benchmark_wal(mount, roots, samples=7, trace_logs=()):
    if samples < 2:
        raise ValueError("at least two samples are required")
    roots = [Path(root) / "mutable" for root in roots]
    before = [set(root.iterdir()) if root.exists() else set() for root in roots]
    path = Path(mount) / f"wal-benchmark-{uuid.uuid4().hex}"
    payload = bytes(range(256)) * 4096
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
    try:
        assert os.pwrite(fd, payload, 0) == len(payload)
        os.fsync(fd)
        leaves = []
        for root, previous in zip(roots, before):
            added = set(root.iterdir()) - previous
            if len(added) != 1:
                raise RuntimeError(
                    "benchmark requires exclusive backend namespace activity"
                )
            leaves.append(added.pop())

        def logs():
            return [
                max(leaf.glob("wal-*"), key=lambda p: int(p.name[4:])).stat().st_size
                for leaf in leaves
            ]

        def measure(phase, written):
            sizes = logs()
            assert sizes[0] == sizes[1]
            for operation, length in (
                ("stat", 0),
                ("read", 4096),
                ("read", len(payload)),
            ):

                def invoke():
                    if operation == "stat":
                        assert os.fstat(fd).st_size == len(payload)
                    else:
                        assert os.pread(fd, length, 0) == payload[:length]

                invoke()  # Warm-up is deliberately excluded from the samples.
                offsets = [path.stat().st_size for path in trace_logs]
                elapsed = []
                cpu = []
                for _ in range(samples):
                    cpu_start = time.process_time_ns()
                    start = time.perf_counter_ns()
                    invoke()
                    elapsed.append((time.perf_counter_ns() - start) / 1e6)
                    cpu.append((time.process_time_ns() - cpu_start) / 1e6)
                assert logs() == sizes, "measurement unexpectedly changed the WAL"
                print(
                    json.dumps(
                        {
                            "benchmark": "wal-fuse",
                            "phase": phase,
                            "platform": platform.platform(),
                            "samples": samples,
                            "pending_payload_bytes": written,
                            "wal_bytes_per_replica": sizes,
                            "operation": operation,
                            "read_bytes": length,
                            "latency_ms": elapsed,
                            "median_ms": statistics.median(elapsed),
                            "p95_ms": sorted(elapsed)[math.ceil(samples * 0.95) - 1],
                            "client_cpu_ms": cpu,
                            "stage_samples_ns": trace_samples(trace_logs, offsets),
                        }
                    ),
                    flush=True,
                )

        measure("clean", 0)
        written = 0
        for mib in (1, 4, 16):
            while written < mib * len(payload):
                assert os.pwrite(fd, payload, 0) == len(payload)
                written += len(payload)
            measure("dirty", written)
        os.fsync(fd)
        assert logs() == [0, 0]
        measure("checkpointed", 0)
    finally:
        os.close(fd)
        path.unlink()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mount", type=Path)
    parser.add_argument("--backend-roots", type=Path, nargs=2, required=True)
    parser.add_argument("--samples", type=int, default=7)
    parser.add_argument("--trace-logs", type=Path, nargs="*", default=[])
    args = parser.parse_args()
    benchmark_wal(args.mount, args.backend_roots, args.samples, args.trace_logs)
