# Generated clock-cycle diagnostics

This opt-in diagnostic separates the boundary at which whole clock opportunities
elapsed. It changes no shipping source, workload content, frame rate, timestamp,
deadline, duration, acceptance check, renderer or recipient policy. The original
performance harness still returns its original failure when a gate fails. A trace
is additional evidence, not capacity qualification or a throughput fix.

The generator copies the exact production Engine and substitutes a synchronous
wrapper around its existing `tick` call. D is the existing scheduled deadline;
S/E bracket the actual call (including its original guards, providers and defers);
C is the existing clock observation passed to `CompositionFrameSchedule.next`.
No actor await is added in the hot path. The same actual helper evaluates the
unchanged scheduled deadline at S, E and C **after sampling**, so the differences
partition the proposed skipped opportunities. A separate event after the real
guarded metrics increment distinguishes skips committed to metrics from proposals
rejected after cancellation/reconfiguration. No-self and authority-rejected calls
are explicit; an authorized call without a scene is not labeled an attempted frame.

The categories mean fully elapsed following opportunities under the existing
keep-one-due scheduling rule. They do not identify kernel wake, GPU wait, CPU work,
actor contention or host cause. Before-body elapsed slots can include executor
and actor resumption; after-body slots include continuation scheduling. Extra
observer work can affect the current sleep/yield decision and later cycles. Existing sleep request/return
endpoints bracket the same zero-tolerance call using wall instants only, including
a canceled-return event when observed. No thread CPU is subtracted across await.

Each clock run captures a distinct UUID and owns a fixed 65,536-event array. At
most eight runs are retained per Engine; overflow is explicit and prevents a
complete/reconciled result. Storage contains scalar/clock values, no source frame
or callback. The original weak-self clock Task is not assumed actor-inherited.
A per-run NSLock synchronizes bounded appends/state with actor commit/snapshot
access. Its contention/cost is diagnostic overhead, not yet measured. No executor
or capture changes, new actor awaits, I/O, renders or media/GPU waits are added.
Snapshot freezes and copies the immutable array/state under the lock, then
validates/serializes outside it. A late canceled resume can only address
its captured frozen run, never the next case's Engine. Unobserved sleep returns
at freeze remain listed as unknown, not fabricated cancellation receipts. A
whole-snapshot reconciliation compares committed categories to actual metrics;
counter resets or missing runs fail reconciliation rather than being zero-filled.
Task-start/exit observations, pending commit resolution and paired sleep records
are separate completeness gates. Math may be consistent for observed commits
while the run is explicitly incomplete. Duplicate/orphan/nonmonotonic records
invalidate structure; no pending cancellation return is manufactured.

`STUDIO_PERFORMANCE_CYCLE_TRACE=1` opts the existing runner into generated inputs
in a fresh `cycle-trace-inputs/UUID` directory. It substitutes only the generated
Engine, its helper and a generated harness that labels instrumented scope and writes
`clock-cycle-case-N.json` only after the original media shutdown, writer completion,
resource/metrics capture and first durable original case journal. It catches
supplemental export errors separately so they cannot suppress original cases or
gates. Export time still consumes the unchanged launcher deadline and is included
in later validation elapsed time; it cannot extend the original live PCM frontier.
All other source roots, tool
dependencies, arguments, workload launcher and timeouts remain as before. Default
mode remains uninstrumented. The input manifest retains exact source snapshots,
hashes, generated hashes and reversible Engine/harness edit boundaries. Every
original input is captured once, used for transformation/snapshot/hash, and checked
unchanged before manifest publication. The runner checks again after compilation
and before launching; changed originals/generated inputs fail closed. A common
generation UUID and source hashes appear in the trace and manifest. Exact generated
sources, original snapshots/manifest, binary hash and generated project/recipe
bindings are copied beneath uploaded `frames/clock-cycle-inputs/UUID`.
No binary is executed by that byte-binding step. Unknown source anchors fail
generation instead of silently changing the experiment.

Source-only checks: `python3 scripts/test_composition_cycle_trace.py` verifies
integer boundary/telescoping cases and exact reversible generation, unchanged
guards/workload and await counts. These checks neither compile nor execute Swift.

The actual helper and unchanged scheduler compiled with strict Swift 6, `-j2`
and ThreadSanitizer. One corrected owned run passed 12 outcomes covering exact
edges, real category sums, supplied rejected/no-self spans, unresolved commits,
pending startup/exit/sleep, late frozen writes, invalid/duplicate/orphan evidence,
overflow and concurrent append/snapshot. The generic exact executed fixture is
`scripts/composition_cycle_trace_harness.swift`. These supplied scalar events
exercise the actual helper; they do not execute the Engine's authority guard or
autonomous clock. The three retained generated Swift sources passed parsing;
full target typechecking remains for the actual hosted build.

The first runtime outcome is retained: the fixture cast an `Int64` pending
iteration as `Int`, returning its failure sentinel. Source review confirmed that
the helper correctly marked the unresolved state incomplete. The corrected
fixture accepts `Int` and exact `Int64` conversion, adds adapter sanity checks and
unbuffered progress, and retains every original assertion. All six owner sources
were byte-identical before/after both runs; no helper gate was relaxed. The first
failed run did not execute later cases or the generated parse.

Within the corrected run, 10,000 helper-only observer iterations averaged
1.464267 microseconds including locking, scalar stores and synthetic span
construction. That optimized, ThreadSanitizer-perturbed local loop is neither
representative frame overhead nor pure lock cost; it cannot predict hosted
throughput. No renderer, media, device, network, Core/App build or performance
workload ran. The [dated receipt](COMPOSITION_CYCLE_TRACE_2026-10-22.json) binds
both first outcomes, actual sources/executables/logs and parsing evidence. No
new runtime attribution or performance-capacity result exists yet; all original
#92 failures and gates remain unchanged.
