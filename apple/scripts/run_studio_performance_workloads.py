#!/usr/bin/env python3
"""Run only the owned native workload process, with a wall-clock deadline."""
import math
import os
import signal
import subprocess
import sys

executable, artifacts, *arguments = sys.argv[1:]
seconds = float(os.environ.get("STUDIO_PERFORMANCE_SECONDS", "180"))
if "--sustained" in arguments and (not math.isfinite(seconds) or not 120 <= seconds <= 600):
    raise SystemExit("Sustained workload duration must be 120–600 seconds per case.")
workload_seconds = seconds * 2 if "--sustained" in arguments else (10 if "--4k-only" in arguments else 40)
process = subprocess.Popen([executable, artifacts, *arguments], start_new_session=True)
try:
    raise SystemExit(process.wait(timeout=workload_seconds + 180))
except subprocess.TimeoutExpired:
    # No operator/system process lookup: only this newly owned process group.
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    raise SystemExit("FAIL: owned workload exceeded its deadline; original media remain at " + artifacts)
