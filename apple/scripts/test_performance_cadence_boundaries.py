#!/usr/bin/env python3
"""Foundation-only cadence checks; no media, GPU or sustained workload runs."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


class PerformanceCadenceBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="stream-cadence-boundaries-")
        cls.directory = Path(cls.temporary.name)
        cls.executable = cls.directory / "cadence"
        harness = cls.directory / "cadence.swift"
        harness.write_text("""
import Foundation
@main struct CadenceBoundaryHarness {
    static func main() throws {
        struct Input: Decodable {
            var rendered: Int
            var decoded: Int
            var source: PerformanceReplayInventory
        }
        let input = try JSONDecoder().decode(Input.self,
            from: FileHandle.standardInput.readDataToEndOfFile())
        let checks = PerformanceWorkloadCheck.cadence(fps: 30, seconds: 600,
            rendered: input.rendered, decoded: input.decoded, source: input.source)
        FileHandle.standardOutput.write(try JSONEncoder().encode(checks))
    }
}
""")
        source = Path(__file__).with_name("performance_workload_evidence.swift")
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-j2",
                        "-parse-as-library", str(source), str(harness),
                        "-o", str(cls.executable)], check=True, timeout=60)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def checks(self, *, available=17_900, due=17_750, decoded=17_900,
               rendered=17_850):
        # These are explicit boundary inputs, never measured run evidence.
        value = {"rendered": rendered, "decoded": decoded, "source": {
            "availableFrames": available, "framesDueBeforeGraceEnd": due,
            "durationSeconds": 600, "monotonic": True}}
        result = subprocess.run([str(self.executable)], input=json.dumps(value),
                                text=True, capture_output=True, check=True, timeout=5)
        return {check["name"]: check for check in json.loads(result.stdout)}

    def test_original_total_input_allowance_does_not_require_perfect_rate_before_grace(self):
        checks = self.checks()
        self.assertTrue(all(check["status"] == "passed" for check in checks.values()))
        self.assertIn("17900 total frames", checks["nominalReplayInputAvailability"]["detail"])

    def test_exact_original_total_input_boundary_passes(self):
        checks = self.checks(available=17_850, due=17_700, decoded=17_850)
        self.assertTrue(all(check["status"] == "passed" for check in checks.values()))

    def test_input_below_original_total_boundary_fails_despite_actual_decode_success(self):
        checks = self.checks(available=17_849, due=17_700, decoded=17_849)
        self.assertEqual(checks["nominalReplayInputAvailability"]["status"], "failed")
        self.assertEqual(checks["actualSourceDecodeCadence"]["status"], "passed")
        self.assertEqual(checks["nominalReplayDecodeCapacity"]["status"], "failed")

    def test_decoder_missing_one_due_frame_fails_even_with_adequate_total_input(self):
        checks = self.checks(decoded=17_749)
        self.assertEqual(checks["nominalReplayInputAvailability"]["status"], "passed")
        self.assertEqual(checks["actualSourceDecodeCadence"]["status"], "failed")
        self.assertEqual(checks["nominalReplayDecodeCapacity"]["status"], "failed")

    def test_meeting_decoder_grace_does_not_claim_nominal_decode_capacity(self):
        checks = self.checks(decoded=17_750)
        self.assertEqual(checks["actualSourceDecodeCadence"]["status"], "passed")
        self.assertEqual(checks["nominalReplayDecodeCapacity"]["status"], "failed")

    def test_adequate_source_and_decode_cannot_hide_a_nominal_compositor_failure(self):
        checks = self.checks(rendered=17_849)
        self.assertEqual(checks["nominalCompositorCapacity"]["status"], "failed")
        self.assertTrue(all(check["status"] == "passed" for name, check in checks.items()
                            if name != "nominalCompositorCapacity"))


if __name__ == "__main__":
    unittest.main()
