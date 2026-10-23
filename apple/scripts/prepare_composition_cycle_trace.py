#!/usr/bin/env python3
"""Generate D/S/E/C diagnostics without editing shipping code or workload gates.

Only two generated inputs replace production inputs: the Engine and performance
harness. The harness exports after media completion and marks diagnostic scope.
No compilation, workload execution or toolchain/API invocation occurs here.
"""
import argparse
import hashlib
import json
import uuid
from pathlib import Path


def substitute(source, old, new):
    if source.count(old) != 1:
        raise ValueError(f"Expected exactly one approved source boundary: {old!r}")
    return source.replace(old, new)


def generate(apple, output):
    apple = apple.resolve()
    output = output.resolve()
    if output == apple or apple in output.parents and not (apple / "build") in output.parents:
        raise ValueError("Generated inputs must live outside shipping sources (or under owned build)")
    output.mkdir(parents=True, exist_ok=False)
    engine_path = apple / "StreamMac/CompositionEngine.swift"
    harness_path = apple / "scripts/studio_performance_harness.swift"
    helper = apple / "scripts/composition_cycle_trace.swift"
    source_paths = [engine_path, harness_path, helper,
                    apple / "StreamMac/CompositionFrameSchedule.swift", Path(__file__).resolve(),
                    apple / "project.yml", apple / "scripts/run_studio_performance_harness.zsh",
                    apple / "scripts/run_studio_performance_workloads.py",
                    apple / "scripts/program_recording_fixtures.swift",
                    apple / "scripts/performance_owned_replay.swift",
                    apple / "scripts/performance_workload_evidence.swift",
                    apple / "scripts/retain_composition_cycle_trace_inputs.py"]
    captured = {path: path.read_bytes() for path in source_paths}
    source_hashes = {str(path.relative_to(apple)): hashlib.sha256(data).hexdigest()
                     for path, data in captured.items()}
    source_set_digest = hashlib.sha256(json.dumps(source_hashes, sort_keys=True).encode()).hexdigest()
    generation_id = str(uuid.uuid4())
    source_binding = "[" + ", ".join(json.dumps(k) + ": " + json.dumps(v)
                                      for k, v in source_hashes.items()) + "]"
    engine = captured[engine_path].decode()
    edits = []

    def edit(old, new):
        nonlocal engine
        engine = substitute(engine, old, new)
        edits.append({"old": old, "new": new})

    edit("    private var clockAuthority = UUID()", """    private var clockAuthority = UUID()
    private var diagnosticTickPassedAuthority = false
    private var diagnosticClockRuns: [CompositionCycleTraceRun] = []
    private var diagnosticOmittedRuns = 0
    private func diagnosticClockRun(authority: UUID, interval: Duration) -> CompositionCycleTraceRun? {
        guard diagnosticClockRuns.count < 8 else { diagnosticOmittedRuns += 1; return nil }
        let run = CompositionCycleTraceRun(authority: authority, interval: interval)
        diagnosticClockRuns.append(run)
        return run
    }
    func diagnosticClockTraceSnapshot() throws -> Data {
        let runs = diagnosticClockRuns.map { $0.snapshot() }
        let committed = runs.reduce(0) { $0 + ($1["committedSkips"] as? Int ?? 0) }
        let reconciled = diagnosticOmittedRuns == 0
            && runs.allSatisfy { $0["observedCommittedCategoriesConsistent"] as? Bool == true }
            && committed == metrics.missedDeadlines
        let complete = reconciled && !runs.isEmpty
            && runs.allSatisfy { $0["traceComplete"] as? Bool == true }
        return try JSONSerialization.data(withJSONObject: [
            "generationID": "GENERATION_ID", "sourceSetSHA256": "SOURCE_SET_DIGEST", "sourceSHA256": SOURCE_BINDING,
            "scope": "Generated diagnostic only. D=existing deadline; S/E=actual tick-call boundary; C=existing schedule observation. Categories are elapsed opportunities, not CPU/GPU/wake causes. Sleep endpoints include suspension and executor/actor resumption; no kernel-wake claim. Per-run observer locking/stores can alter the current sleep/yield decision and later cycles. Original weak-self Task/executor/captures are preserved, not assumed actor-inherited. No workload/gate/scheduler change.",
            "omittedRuns": diagnosticOmittedRuns, "runs": runs,
            "traceComplete": complete,
            "traceStatus": complete ? "complete" : "incomplete-or-invalid",
            "committedSkipsReconcileWithMetrics": reconciled,
            "metricsMissedDeadlinesAtSnapshot": metrics.missedDeadlines
        ], options: [.prettyPrinted, .sortedKeys])
    }
    private func diagnosticClockTick(clockAuthority: UUID) -> CompositionCycleTraceRun.TickSpan {
        diagnosticTickPassedAuthority = false
        let beforeAttempts = metrics.attempts
        let started = ContinuousClock.now
        tick(clockAuthority: clockAuthority)
        let ended = ContinuousClock.now
        return .init(started: started, ended: ended,
            passedAuthority: diagnosticTickPassedAuthority, attempted: metrics.attempts > beforeAttempts)
    }""".replace("GENERATION_ID", generation_id).replace("SOURCE_SET_DIGEST", source_set_digest).replace("SOURCE_BINDING", source_binding))
    edit("        tickTask = Task { [weak self] in", """        let diagnosticRun = diagnosticClockRun(authority: authority, interval: interval)
        tickTask = Task { [weak self] in
            diagnosticRun?.started()
            defer { diagnosticRun?.exited() }""")
    edit("            var deadline = clock.now", """            var deadline = clock.now
            var diagnosticIteration: Int64 = 0""")
    edit("            while !Task.isCancelled {", """            while !Task.isCancelled {
                diagnosticIteration += 1""")
    edit("""                await self?.tick(clockAuthority: authority)
                let next = CompositionFrameSchedule.next(after: deadline, interval: interval, completedAt: clock.now)""", """                let diagnosticSpan = await self?.diagnosticClockTick(clockAuthority: authority)
                let diagnosticCheck = clock.now
                let next = CompositionFrameSchedule.next(after: deadline, interval: interval, completedAt: diagnosticCheck)
                diagnosticRun?.cycle(iteration: diagnosticIteration, deadline: deadline,
                    span: diagnosticSpan, checkedAt: diagnosticCheck, skipped: next.skipped)""")
    sleep = "try await clock.sleep(until: deadline, tolerance: .zero)"
    edit("                    do { " + sleep + " } catch { break }", """                    diagnosticRun?.sleep(iteration: diagnosticIteration, deadline: deadline, requestedAt: clock.now)
                    do {
                        """ + sleep + """
                        diagnosticRun?.resumed(iteration: diagnosticIteration, deadline: deadline, at: clock.now, completed: true)
                    } catch {
                        diagnosticRun?.resumed(iteration: diagnosticIteration, deadline: deadline, at: clock.now, completed: false)
                        break
                    }""")
    edit("        metrics.missedDeadlines += count", """        metrics.missedDeadlines += count
        diagnosticClockRuns.first { $0.authority == clockAuthority }?.committed(count)""")
    edit("                if deadline <= clock.now {", """                diagnosticRun?.resolvedCommit(iteration: diagnosticIteration)
                if deadline <= clock.now {""")
    edit("""            guard permitsClockOperation(clockAuthority) else { return } // CLOCK_AUTHORITY_GUARD
        }
        let override = frameOverrideProvider()""", """            guard permitsClockOperation(clockAuthority) else { return } // CLOCK_AUTHORITY_GUARD
            diagnosticTickPassedAuthority = true
        }
        let override = frameOverrideProvider()""")
    harness = captured[harness_path].decode()
    harness_edits = []
    def edit_harness(old, new):
        nonlocal harness
        harness = substitute(harness, old, new)
        harness_edits.append({"old": old, "new": new})
    # All original media shutdown, CPU/resource capture and first durable case
    # result occur before this supplemental work. Never extend the PCM frontier.
    edit_harness("            if result.completed {\n                do {", """            do {
                let cycleTraceData = try await engine.diagnosticClockTraceSnapshot()
                try cycleTraceData.write(to: directory.appendingPathComponent("clock-cycle-case-\\(caseIndex).json"))
            } catch {
                let failure = "INCOMPLETE supplemental clock trace generation GENERATION_ID case \\(caseIndex): \\(error)\\n"
                FileHandle.standardError.write(Data(failure.utf8))
            }
            if result.completed {
                do {""".replace("GENERATION_ID", generation_id))
    edit_harness("        let limitations = sustained", """        let limitations = "INSTRUMENTED CLOCK-CYCLE DIAGNOSTIC generation GENERATION_ID; observer cost and trace export are included in process/deadline behavior; original numeric gates retained but this is not uninstrumented capacity qualification. " + (sustained""".replace("GENERATION_ID", generation_id))
    edit_harness("        func persist() throws {", "        )\n        func persist() throws {")
    generated = {"CompositionEngine.swift": engine.encode(),
                 "studio_performance_harness.swift": harness.encode(),
                 "CompositionCycleTrace.swift": captured[helper]}
    for name, data in generated.items():
        (output / name).write_bytes(data)
    snapshots = output / "source-snapshots"
    snapshots.mkdir()
    for path, data in captured.items():
        key = str(path.relative_to(apple))
        target = snapshots / key
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    unchanged = all(path.read_bytes() == data for path, data in captured.items())
    if not unchanged:
        raise ValueError("Source changed during generation; generated inputs must not be compiled")
    manifest = {"generationID": generation_id, "sourceRoot": str(apple),
                "sourceSetSHA256": source_set_digest,
                "scope": "Instrumented diagnostics; original performance workload, checks, arguments and deadlines retained. No performance qualification follows from trace generation.",
                "sourceSHA256": source_hashes,
                "generatedSHA256": {name: hashlib.sha256(data).hexdigest() for name, data in generated.items()},
                "engineEdits": edits,
                "harnessEdits": harness_edits,
                "harnessEdit": "Supplemental export after media completion/resource capture and initial original case journal; annotate diagnostic limitations only. No new await in clock hot path.",
                "capacity": {"runs": 8, "eventsPerRun": 65_536, "overflow": "explicit omissions; category checks cannot pass"},
                "sleepCall": sleep, "shippingInputsUnmodified": unchanged}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    generate(args.source_root, args.output)
    print(args.output.resolve())


if __name__ == "__main__":
    main()
