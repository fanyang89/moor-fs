"""Linux process CPU and surviving-thread context-switch counters for benchmarks."""

import os
from pathlib import Path
import time


def stat_fields(path):
    # comm may contain spaces and closing parentheses; fields follow its last ')'.
    return path.read_text().rsplit(")", 1)[1].split()


def snapshot(processes):
    result = {}
    for label, pid in processes.items():
        root = Path("/proc") / str(pid)
        fields = stat_fields(root / "stat")
        threads = {}
        for task in (root / "task").iterdir():
            try:
                identity = (task.name, stat_fields(task / "stat")[19])
                status = dict(
                    line.split(":", 1)
                    for line in (task / "status").read_text().splitlines()
                )
                threads[identity] = (
                    int(status["voluntary_ctxt_switches"]),
                    int(status["nonvoluntary_ctxt_switches"]),
                )
            except (FileNotFoundError, ProcessLookupError):
                continue
        result[label] = {
            "pid": pid,
            "start_ticks": int(fields[19]),
            "cpu_ticks": int(fields[11]) + int(fields[12]),
            "time_ns": time.monotonic_ns(),
            "threads": threads,
        }
    return result


def difference(before, after):
    hz = os.sysconf("SC_CLK_TCK")
    result = {}
    for label, first in before.items():
        last = after[label]
        if (first["pid"], first["start_ticks"]) != (last["pid"], last["start_ticks"]):
            raise RuntimeError(f"benchmark process was replaced: {label}")
        elapsed = (last["time_ns"] - first["time_ns"]) / 1e9
        ticks = last["cpu_ticks"] - first["cpu_ticks"]
        common = first["threads"].keys() & last["threads"].keys()
        switches = [
            sum(last["threads"][tid][i] - first["threads"][tid][i] for tid in common)
            for i in range(2)
        ]
        if elapsed <= 0 or ticks < 0 or any(value < 0 for value in switches):
            raise RuntimeError(f"invalid benchmark counter delta: {label}")
        result[label] = {
            "pid": last["pid"],
            "elapsed_seconds": elapsed,
            "clock_ticks_per_second": hz,
            "cpu_ticks": ticks,
            "cpu_seconds": ticks / hz,
            "cpu_percent_one_core": ticks / hz / elapsed * 100,
            "voluntary_switches": switches[0],
            "involuntary_switches": switches[1],
            "stable_threads": len(common),
            "departed_threads": len(first["threads"].keys() - common),
            "new_threads": len(last["threads"].keys() - common),
        }
    return result
