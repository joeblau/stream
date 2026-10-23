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
access. Its contention/cost is diagnostic overhead, not isolated on the actual
frame path. No executor or capture changes, new actor awaits, I/O, renders or media/GPU waits are added.
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
at that stage, full target typechecking remained for the actual hosted build.
The hosted outcome below now supplies that build evidence for both architectures.

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
both first outcomes, actual sources/executables/logs and parsing evidence. The
hosted result below adds actual runtime evidence; all original #92 failures and
gates remain unchanged.

## Hosted outcome: both jobs failed, four traces complete

The single [manual run 39880680658](https://github.com/joeblau/stream/actions/runs/39880680658)
at `f7d161a9343f65fdf1ab7c1785b193ff4089349f` used `cycle_trace=true` and the
unchanged two 600s, 12-layer 1920×1080/30fps workloads on ARM and Intel. Both actual
generated targets built successfully. All four traces are complete, structurally
valid and reconciled with their original missed-deadline metrics. Those facts
are distinct from the original job outcomes: **both jobs failed**, and #92 remains
open. The [hosted receipt](HOSTED_COMPOSITION_CYCLE_TRACE_2026-10-22.json) retains
portable archive-member/hash bindings and the independent analyses; full event
arrays are retained in the original artifacts rather than duplicated here.

| Actual original counter | ARM static | ARM replay | Intel static | Intel replay |
|---|---:|---:|---:|---:|
| Rendered, required 17850 |17215|17026|17103|17223|
| Missed opportunities |786|975|897|777|
| Before/during/after threshold crossings |92/694/0|188/787/0|73/823/1|25/752/0|
| Committed-skip cycles |772|935|748|676|
| Skip cycles with body ≥33.333333 ms / their skipped opportunities |2/10|5/33|321/460|451/542|
| Original media inspection |complete|complete|complete|pending at 1380s deadline|

All cycles have a real Engine, passed authority and attempted a frame; there are
no nil-self/rejected zero spans in these distributions. ARM skip-cycle means for
S−D/E−S/C−E are 58.342/17.642/.00551 ms and 60.335/17.789/.00544 ms. Entry lateness
exceeds body duration in 771 of 772 and 930 of 935 skip cycles. Respectively,
771 and 932 skip cycles immediately follow an observed successful sleep return;
median return→S is .01825/.01871 ms.
This narrows most accumulated ARM lateness before the observed sleep-return point;
it does not identify timer delivery, executor scheduling, host contention or
kernel wake. A during-body threshold crossing can follow substantial pre-entry
lateness, so the category majority is not a render-cause count.

Intel differs: skip-cycle means S−D/E−S are 38.815/47.854 ms and 29.710/55.061 ms,
and long bodies account for 460 of 897 and 542 of 777 skipped opportunities. The body
bracket includes the entire actual tick call and elapsed waits/scheduling, not
pure CPU or CI-kernel work. A single common scheduler/renderer fix is not proved.
Per-phase CPU-versus-elapsed and ready-versus-running observations are still
needed to distinguish these boundaries. Diagnostic locking/stores can affect
current and later cycles; these are instrumented observations rather than an
uninstrumented capacity comparison.

ARM's first recorded movie supplies 17214 available replay frames, all 17214 decoded;
Intel's supplies 17103 available, all 17103 decoded. The nominal replay input/decode
failures depend on the first output deficit. Actual-source decoding passes but
does not qualify nominal 30fps. Writer audio/video drops are 0 in all four cases;
Intel replay separately records 1 retired ingress intent. Both Intel writers finish,
but the original 1380s deadline fires with the second media inspection still
pending. Its persisted .218495s is pre-inspection bookkeeping, not a completed
inspection duration. Neither complete clock traces nor completed writer metadata
resolve that pending inspection. No supplementary decode or workload rerun was
performed for this documentation.

Each architecture's 12 original source inputs match the exact published blobs and
both retained snapshot copies; the 3 generated files and reversible Engine/harness
edits, source-set digest, generation UUID, manifest and compiled project bindings
match. The raw binaries were not retained: their byte counts/SHA256 values are
post-build/prelaunch **receipt-only**, not independent rehashes of archived
executable bytes. Both full generated-target builds are separately evidenced by
the original logs. None of this converts the failed 17850-frame gates into passes
or establishes a production cause, repair, universal hardware capacity or waveform
A/V-sync qualification.
