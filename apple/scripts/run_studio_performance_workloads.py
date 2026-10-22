#!/usr/bin/env python3
"""Run only the owned native workload process, with a wall-clock deadline."""
import math
import os
import signal
import subprocess
import sys

def stop_owned_process(process):
    """Bound teardown to the process group this invocation just created."""
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def interrupted(signum, _frame):
    raise SystemExit(128 + signum)


def main():
    executable, artifacts, *arguments = sys.argv[1:]
    seconds = float(os.environ.get("STUDIO_PERFORMANCE_SECONDS", "180"))
    if "--sustained" in arguments and (not math.isfinite(seconds) or not 120 <= seconds <= 600):
        raise SystemExit("Sustained workload duration must be 120–600 seconds per case.")
    workload_seconds = seconds * 2 if "--sustained" in arguments else (10 if "--4k-only" in arguments else 40)
    previous = {kind: signal.signal(kind, interrupted) for kind in (signal.SIGINT, signal.SIGTERM)}
    process = None
    try:
        process = subprocess.Popen([executable, artifacts, *arguments], start_new_session=True)
        try:
            return process.wait(timeout=workload_seconds + 180)
        except subprocess.TimeoutExpired:
            raise SystemExit("FAIL: owned workload exceeded its deadline; original media remain at " + artifacts)
    finally:
        # A second interrupt must not abandon the bounded teardown itself.
        for kind in previous:
            signal.signal(kind, signal.SIG_IGN)
        try:
            if process is not None:
                stop_owned_process(process)
        finally:
            for kind, handler in previous.items():
                signal.signal(kind, handler)


if __name__ == "__main__":
    raise SystemExit(main())
