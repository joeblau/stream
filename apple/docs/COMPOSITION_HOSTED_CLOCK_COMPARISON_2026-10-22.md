# Hosted clock-tolerance comparison (#92)

Both [baseline run 39757372776](https://github.com/joeblau/stream/actions/runs/39757372776)
at `a9cfd98` and [zero-tolerance run 39762992882](https://github.com/joeblau/stream/actions/runs/39762992882)
at `a4d0122` completed successfully **as diagnostics**. Each architecture ran
one invocation with two 20-second cases. All original short checks pass their
**450-frame allowance**. This is not the original 600-second / 17,850-frame
qualification, and #92 remains open.

The sole app/Core production difference is the existing sleep call's explicit
`tolerance: .zero` plus comments. Renderer/workload source is unchanged. The new
generated observer adds work absent the baseline, which has no sleep-boundary
trace. Advertised host classes/toolchains match per architecture, but these are
separate hosted VMs, not a controlled same-instance experiment or physical
hardware certification. The [machine receipt](PERFORMANCE_HOSTED_ATTRIBUTION_39762992882.json)
binds exact sources, original logs/ZIPs, case metrics and independent audits.

## Output and loss counters

| Host/case | Baseline → zero-tolerance rendered frames | Writer audio-chunk drops |
| --- | ---: | ---: |
| ARM static | 553 → 551 | 0 → 10 |
| ARM replay | 574 → 562 | 0 → 0 |
| Intel static | 528 → 553 | 16 → 0 |
| Intel replay | 565 → 569 | 0 → 0 |

ARM shows no output gain; Intel has higher counts in this execution. These
observations establish neither causation nor a general throughput improvement.
The first static measured tick also changes markedly:

| Host | Baseline cold tick / whole skips | Zero-tolerance cold tick / whole skips |
| --- | ---: | ---: |
| ARM | 247.656 ms / 6 | 783.011 ms / 22 |
| Intel | 1,018.380 ms / 29 | 418.638 ms / 11 |

Much of Intel's static difference coincides with the shorter cold tick, while
ARM moves in the opposite direction. Long bodies and late entries coexist;
body-duration classifications are not exclusive causal attribution.

Healthy video posts, deliveries and writer samples equal rendered counts in
all cases, with no healthy-video mailbox loss. Candidate post-warmup counters
are **539/532 ARM** and **535/539 Intel**, after 12/30 and 18/30 successful warmup
frames respectively. Candidate replay inputs decode **551/551 ARM** and
**553/553 Intel**, distinct from 562/569 compositor outputs. Each replay uses
its own first-case movie, so baseline and candidate source inventories differ.
Attempts, failed pool allocations, whole skips, warmup, input decoding and
writer samples must not be substituted for one another. Sampled opportunity
totals are 600 or 601; they need not be forced to 601.

The deliberate slow mailbox accounts separately for dropped video deliveries.
ARM static reports 2,004 PCM chunks produced = 1,994 written + 10 dropped;
Intel writes all 2,001/2,002 chunks in its candidate cases. No retained per-chunk
reason/timeline proves why other runs dropped audio. Recording finalization and
original movie inspections complete; endpoint agreement is not waveform drift.

## Sleep, epoch and observer boundaries

| Candidate case | Successful sleeps | Mean / max observed return lateness | Mean return → next dispatch |
| --- | ---: | ---: | ---: |
| ARM static | 443 | 14.554 / 66.909 ms | 0.051 ms |
| ARM replay | 409 | 18.144 / 82.769 ms | 0.065 ms |
| Intel static | 365 | 11.877 / 66.904 ms | 0.072 ms |
| Intel replay | 309 | 8.406 / 71.361 ms | 0.108 ms |

Return lateness measures task resumption against the existing deadline,
including runtime/executor/host scheduling, not kernel wake alone. Small mean
gaps after observed return do not identify the earlier cause. Zero tolerance
requests no extra coalescing allowance and does not guarantee on-time resumption.
No baseline sleep marker permits a direct before/after sleep-lateness comparison.

Each case retains one distinct profile epoch. Both static cases have one
canceled return, excluded from successful aggregates; replay has none. The
[source regression](COMPOSITION_SLEEP_TOLERANCE.md) separately proves atomic
reset fencing for new sleep events/aggregates. No CPU delta crosses suspension;
loop iteration is not a rendered-frame identity.

Intel static retains **568 entry observations but 567 actual attempts**. Entry
568 is rejected by shipping authority/cancellation checks before providers,
attempt metrics, rendering or fanout. The legacy generated entry observer runs
before that guard. Mean entry lateness is 11.600 ms including the rejected point,
11.616 ms for actual bodies, versus 10.015 ms in the baseline. The last
successful sleep pairs with that rejected
entry, and its canceled iteration stays outside successful sleep aggregates.
It is not an extra rendered frame or a broken production fence.

Nested wall/thread-CPU spans overlap; wall minus caller CPU is not isolated GPU
wait. Maximum healthy callbacks contain the profiler-only warm pixel hash and
are not shipping recorder costs. Calibration samples are not universal overhead
corrections. There are no omitted events or measured synchronous thread migrations.

Both candidate audits verify 444 bindings each and have independent recording
review: original archives/logs, 323 checkout blobs, 22 inventory files, tool and
command pins, generated sources and raw counter correlations. Consolidation
checks source identities, archive/log hashes and audited case projections;
resource samples remain in the original artifacts. No new run, retry, build,
decode, capture or production change accompanies these documents. Original
600-second gates, failed receipts, resource limits and qualification gaps remain
unchanged; this evidence establishes no further performance fix or closure.
