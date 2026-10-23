#!/usr/bin/env python3
"""Source-generation and integer-boundary tests only; no Swift/native execution."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("cycle_generator", HERE / "prepare_composition_cycle_trace.py")
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


def skipped(deadline, interval, now):
    # Integer model of the exact existing Swift while-condition. This is a
    # diagnostic boundary check, not a claim to have executed the Swift helper.
    deadline += interval
    result = 0
    while deadline + interval <= now:
        deadline += interval
        result += 1
    return result


def categories(d, interval, s, e, c):
    if not s <= e <= c:
        raise ValueError("unordered boundaries")
    at_s, at_e, at_c = [skipped(d, interval, value) for value in (s, e, c)]
    return at_s, at_e - at_s, at_c - at_e


class CycleTraceTests(unittest.TestCase):
    def test_exact_boundaries(self):
        t = 33_333_333
        self.assertEqual([skipped(0, t, x) for x in [-1, 0, t, 2*t-1, 2*t, 3*t-1, 3*t]],
                         [0, 0, 0, 0, 1, 1, 2])

    def test_preentry_only(self):
        self.assertEqual(categories(0, 10, 45, 46, 47), (3, 0, 0))

    def test_body_only(self):
        self.assertEqual(categories(0, 10, 0, 55, 56), (0, 4, 0))

    def test_continuation_only(self):
        self.assertEqual(categories(0, 10, 0, 1, 55), (0, 0, 4))

    def test_combined_and_offsets(self):
        for d in [-1_000_000, 0, 1_000_000]:
            self.assertEqual(categories(d, 10, d+25, d+45, d+65), (1, 2, 2))

    def test_telescopes_many_boundaries(self):
        for s in range(-2, 70, 3):
            for e in range(s, 90, 7):
                for c in range(e, 110, 11):
                    values = categories(0, 10, s, e, c)
                    self.assertTrue(all(x >= 0 for x in values))
                    self.assertEqual(sum(values), skipped(0, 10, c))

    def test_unordered_is_not_classified(self):
        with self.assertRaises(ValueError):
            categories(0, 10, 20, 10, 30)

    def test_generation_reversible_and_original_gates(self):
        apple = HERE.parent
        original_engine = (apple / "StreamMac/CompositionEngine.swift").read_text()
        original_harness = (HERE / "studio_performance_harness.swift").read_text()
        with tempfile.TemporaryDirectory(prefix="stream-cycle-source-test-") as temporary:
            output = Path(temporary) / "generated"
            manifest = generator.generate(apple, output)
            engine = (output / "CompositionEngine.swift").read_text()
            for edit in reversed(manifest["engineEdits"]):
                self.assertEqual(engine.count(edit["new"]), 1)
                engine = engine.replace(edit["new"], edit["old"])
            self.assertEqual(engine, original_engine)
            harness = (output / "studio_performance_harness.swift").read_text()
            for edit in reversed(manifest["harnessEdits"]):
                self.assertEqual(harness.count(edit["new"]), 1)
                harness = harness.replace(edit["new"], edit["old"])
            self.assertEqual(harness, original_harness)
            generated_harness = (output / "studio_performance_harness.swift").read_text()
            self.assertLess(generated_harness.index("let result = await withCheckedContinuation"),
                            generated_harness.index("let cycleTraceData"))
            self.assertLess(generated_harness.index("var after = StudioDiagnosticSnapshot()"),
                            generated_harness.index("let cycleTraceData"))
            self.assertLess(generated_harness.index('try journal.write(results[caseIndex]'),
                            generated_harness.index("let cycleTraceData"))
            self.assertEqual((apple / "StreamMac/CompositionEngine.swift").read_text(), original_engine)
            self.assertEqual((HERE / "studio_performance_harness.swift").read_text(), original_harness)
            self.assertTrue(manifest["shippingInputsUnmodified"])
            self.assertEqual(manifest["sleepCall"], "try await clock.sleep(until: deadline, tolerance: .zero)")
            generated = (output / "CompositionEngine.swift").read_text()
            # One replaced actor call, unchanged count of actual await sites.
            self.assertEqual(generated.count("await "), original_engine.count("await "))
            self.assertEqual(generated.count("tick(clockAuthority: clockAuthority)"), 1)
            self.assertIn("diagnosticSpan = await self?.diagnosticClockTick", generated)
            self.assertIn("diagnosticClockRuns.first { $0.authority == clockAuthority }?.committed(count)", generated)
            self.assertIn("span: diagnosticSpan", generated)  # nil self stays explicit
            self.assertEqual(json.loads((output / "manifest.json").read_text()), manifest)

    def test_capture_rejects_changed_input(self):
        apple = HERE.parent
        engine = apple / "StreamMac/CompositionEngine.swift"
        read_bytes = Path.read_bytes
        calls = 0
        def changing_read(path):
            nonlocal calls
            data = read_bytes(path)
            if path == engine:
                calls += 1
                if calls > 1:
                    return data + b"\n// simulated concurrent change (never written)\n"
            return data
        with tempfile.TemporaryDirectory(prefix="stream-cycle-source-mutation-") as temporary:
            output = Path(temporary) / "generated"
            with patch.object(Path, "read_bytes", changing_read):
                with self.assertRaisesRegex(ValueError, "Source changed"):
                    generator.generate(apple, output)
            self.assertFalse((output / "manifest.json").exists())

    def test_generation_refuses_unknown_anchors(self):
        with self.assertRaises(ValueError):
            generator.substitute("x x", "x", "new")

    def test_cancellation_and_epoch_source_fences(self):
        helper = (HERE / "composition_cycle_trace.swift").read_text()
        self.assertIn("guard !frozen else { return }", helper)
        self.assertIn("frozen = true", helper)
        self.assertIn("let authority: UUID", helper)
        self.assertIn('"hasSelf": event.hasSelf', helper)
        self.assertIn('"committedSkips": committed', helper)
        self.assertIn("checksPass && omitted == 0", helper)
        self.assertIn("sleepRequestsWithoutObservedReturnAtFreeze", helper)
        self.assertIn('"taskExitObserved": taskExited', helper)
        self.assertIn('"traceComplete": complete', helper)
        # This is source-order evidence only; native cancellation/race behavior
        # must not be labeled tested by the Python integer-boundary model.
        source = (HERE.parent / "StreamMac/CompositionEngine.swift").read_text()
        guard = "guard permitsClockOperation(clockAuthority) else { return } // CLOCK_AUTHORITY_GUARD"
        self.assertLess(source.index(guard, source.index("private func noteMissedDeadlines")),
                        source.index("metrics.missedDeadlines += count"))


if __name__ == "__main__":
    unittest.main()
