#!/usr/bin/env python3
"""Bounded launcher regression checks; no capture, codecs or native build."""
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


RUNNER = Path(__file__).with_name("run_studio_performance_workloads.py")
spec = importlib.util.spec_from_file_location("performance_workloads", RUNNER)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class PerformanceWorkloadLauncherTests(unittest.TestCase):
    def invoke(self, seconds, process):
        with mock.patch.dict(os.environ, {"STUDIO_PERFORMANCE_SECONDS": seconds}), \
             mock.patch.object(sys, "argv", [str(RUNNER), "owned-harness", "owned-artifacts", "--sustained"]), \
             mock.patch.object(runner.subprocess, "Popen", return_value=process):
            return runner.main()

    def test_two_bounded_sampling_windows_and_child_exit_propagation(self):
        for seconds, deadline in (("120", 420), ("600", 1380)):
            with self.subTest(seconds=seconds):
                process = mock.Mock()
                process.wait.return_value = 7
                process.poll.return_value = 7
                self.assertEqual(self.invoke(seconds, process), 7)
                process.wait.assert_called_once_with(timeout=deadline)

    def test_invalid_durations_never_launch_a_workload(self):
        for seconds in ("119", "601", "nan", "inf", "-inf", "600; exit 0"):
            with self.subTest(seconds=seconds), \
                 mock.patch.dict(os.environ, {"STUDIO_PERFORMANCE_SECONDS": seconds}), \
                 mock.patch.object(sys, "argv", [str(RUNNER), "unused", "unused", "--sustained"]), \
                 mock.patch.object(runner.subprocess, "Popen") as launch:
                with self.assertRaises((SystemExit, ValueError)):
                    runner.main()
                launch.assert_not_called()

    def test_deadline_terminates_then_kills_only_the_owned_group(self):
        process = mock.Mock(pid=31415)
        process.poll.return_value = None
        process.wait.side_effect = [subprocess.TimeoutExpired("owned", 420),
                                    subprocess.TimeoutExpired("owned", 5), -signal.SIGKILL]
        original = {kind: signal.getsignal(kind) for kind in (signal.SIGINT, signal.SIGTERM)}
        with mock.patch.object(runner.os, "killpg") as kill:
            with self.assertRaisesRegex(SystemExit, "original media remain at owned-artifacts"):
                self.invoke("120", process)
        self.assertEqual(kill.call_args_list, [mock.call(31415, signal.SIGTERM), mock.call(31415, signal.SIGKILL)])
        for kind, handler in original.items():
            self.assertEqual(signal.getsignal(kind), handler)

    def test_process_exit_race_preserves_deadline_failure(self):
        process = mock.Mock(pid=31415)
        process.poll.return_value = None
        process.wait.side_effect = subprocess.TimeoutExpired("owned", 420)
        with mock.patch.object(runner.os, "killpg", side_effect=ProcessLookupError):
            with self.assertRaisesRegex(SystemExit, "exceeded its deadline"):
                self.invoke("120", process)

    def test_real_interrupts_reap_the_detached_owned_child(self):
        for kind in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory(prefix="stream-performance-launcher-") as temporary:
                folder = Path(temporary)
                child = folder / "owned-child"
                child.write_text("#!" + sys.executable + "\nimport os, pathlib, sys, time\n"
                                 "pathlib.Path(sys.argv[1], 'ready').write_text(str(os.getpid()))\n"
                                 "time.sleep(60)\n")
                child.chmod(0o700)
                process = subprocess.Popen([sys.executable, str(RUNNER), str(child), str(folder), "--sustained"],
                    env={"PATH": os.defpath, "STUDIO_PERFORMANCE_SECONDS": "120", "PYTHONDONTWRITEBYTECODE": "1"},
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                owned_pid = None
                try:
                    deadline = time.monotonic() + 5
                    while not (folder / "ready").exists():
                        self.assertIsNone(process.poll(), "Launcher exited before the child was ready")
                        self.assertLess(time.monotonic(), deadline, "Owned child did not start")
                        time.sleep(0.01)
                    owned_pid = int((folder / "ready").read_text())
                    process.send_signal(kind)
                    stdout, stderr = process.communicate(timeout=7)
                    self.assertEqual(process.returncode, 128 + kind, (stdout, stderr))
                    with self.assertRaises(ProcessLookupError):
                        os.kill(owned_pid, 0)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.communicate(timeout=3)
                    if owned_pid is not None:
                        try:
                            os.killpg(owned_pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass


if __name__ == "__main__":
    unittest.main()
