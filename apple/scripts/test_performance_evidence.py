#!/usr/bin/env python3
"""Exercise the same Swift journal/cadence logic and real sparse H.264 replay."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


class PerformanceEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="stream-performance-evidence-")
        cls.directory = Path(cls.temporary.name)
        cls.executable = cls.directory / "evidence"
        sources = Path(__file__).resolve().parent
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-j2", "-parse-as-library",
            str(sources / "performance_workload_evidence.swift"),
            str(sources / "performance_owned_replay.swift"),
            str(sources / "performance_evidence_harness.swift"), "-o", str(cls.executable)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_failed_nominal_qualification_retains_both_cases_and_nonzero_exit(self):
        artifacts = self.directory / "failed"
        result = subprocess.run([str(self.executable), str(artifacts), "--failed-qualification"], timeout=10)
        self.assertEqual(result.returncode, 1)
        report = json.loads((artifacts / "performance.json").read_text())
        self.assertEqual(report["status"], "failed")
        self.assertEqual(len(report["workloads"]), 2)
        first = json.loads((artifacts / "case-0.json").read_text())
        second = {check["name"]: check for check in json.loads((artifacts / "case-1.json").read_text())}
        self.assertEqual(first[0]["status"], "failed")
        self.assertEqual(second["actualSourceDecodeCadence"]["status"], "passed")
        for name in ("nominalCompositorCapacity", "nominalReplayInputAvailability", "nominalReplayDecodeCapacity"):
            self.assertEqual(second[name]["status"], "failed")
        self.assertIn("17850", second["nominalReplayDecodeCapacity"]["detail"])

    def test_real_sparse_h264_source_and_decoder_do_not_claim_nominal_capacity(self):
        subprocess.run([str(self.executable), str(self.directory / "actual")], timeout=20, check=True)


if __name__ == "__main__":
    unittest.main()
