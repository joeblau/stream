# Hosted composition lateness and sleep tolerance

The ARM diagnostic from run `39757372776`, job `119752695002`, measured exact
source `a9cfd98e56af023738db95113b17120fe8951d04` on VirtualMac2,1 / M1 Virtual,
three CPUs, macOS 26.6.2, Xcode 26.6 / Swift 6.3.3 and Apple Paravirtual Metal.
Both fixed 20-second cases completed. Their duration-dependent 450-frame checks
passed; this is not the original 17,850-frame / 600-second qualification.

| Actual counter | Static | Replay |
|---|---:|---:|
| Tick attempts | 561 | 574 |
| Whole skipped opportunities | 40 | 27 |
| Rendered / recorder posts / writer video samples | 553 | 574 |
| Failed renders | 8 | 0 |
| Post-warmup arrival count | 531 | 544 |
| Slow sink deliveries / drops | 129 / 424 | 137 / 437 |
| Mean measured tick wall / thread CPU | 12.176 / 4.558 ms | 10.359 / 4.838 ms |
| Mean deadline-start lateness | 17.827 ms | 18.295 ms |
| Maximum actor-entry delay | 0.028 ms | 0.038 ms |

Attempts plus skipped opportunities total 601 in each case. Static allocation
threshold failures all occur at sequences 5–12. Its first cold tick takes
247.656 ms and accounts for six skipped slots. The remaining 34 static slots
and all 27 replay slots occur on ticks whose render interval stays below
33.333 ms but starts 47.487–80.668 ms and 41.047–76.678 ms late, respectively.
The timeline locates these deficits before tick entry rather than in the
mailbox handoff. It does not identify the underlying timer or host cause.

Healthy posts equal deliveries and writer video samples; the valid warmup
counts are 22/30, explaining 531/544 post-warmup arrivals. Replay actually
decodes 553 of 553 available source frames, with 409 due before grace ends;
574 output renders are a different counter. All subscriber drops belong to
the deliberate slow sink. Its nominal synchronous 80 ms sleep callbacks take
154.317/147.441 ms wall on average, with about 0.034 ms caller thread CPU.
This corroborates broad wake/scheduling delay without proving a shared cause.

Maximum fanout wall is 0.617/0.797 ms and drop-removal/release 0.159/0.219 ms.
The largest healthy callbacks contain the profiler-only sequence-31 pixel hash
(23.837/51.608 ms); those peaks are not shipping recorder callback costs.
Full-record calibration averages 0.002213/0.002257 ms. Nested spans overlap,
and observer work adds cost. Kernel timings are actual sampled execution time,
not utilization. All 20 resource samples per case report nominal thermal state.
The [ARM baseline receipt](PERFORMANCE_HOSTED_ATTRIBUTION_39757372776_ARM.json)
retains the source identities, original digests, raw checks, spans and detailed
skip correlations. Original media and traces remain unchanged.

The production clock previously called `sleep(until:)` with unspecified
tolerance. The [Swift ContinuousClock API source](https://github.com/swiftlang/swift/blob/main/stdlib/public/Concurrency/ContinuousClock.swift)
documents that unspecified tolerance permits the system to adjust deadlines
for wake coalescing. The compositor now passes `tolerance: .zero` to the same
sleep call, requesting zero additional tolerance for live cadence. The executor,
OS or host can still resume late. No deadline, frame rate, PTS, schedule helper,
render path, mailbox, encoder, QoS or process-wide setting changes.

Generated diagnostics now capture the existing sleep's requested remaining
delay, observed task-resumption lateness against that deadline and wall
endpoints. They add no timer, wait or CPU delta across suspension. Wall time
includes suspension, executor resumption and bookkeeping; resumption lateness
does not isolate kernel wake latency or coalescing. Observer work after return
precedes the next tick. Canceled points remain distinct from successful
aggregates, and the clock-local iteration is not a rendered-frame identifier.
A profile epoch captured before clock task creation atomically fences all new
sleep events and aggregates against case reset. Existing counters retain their
previous behavior. The manifest records the exact call and `default(nil)` versus
`zero` tolerance; phase files still require completed case validation.

The unchanged six-case actual-engine lifecycle suite passes with the production
change. A focused actual-helper regression rejects stale canceled and successful
sleep records after reset and checks aggregate/event separation. Generated Swift
parsing and exact sleep-block type checking pass. These checks establish source,
recording and lifecycle behavior, not an improvement in hosted timing. The
[change receipt](COMPOSITION_SLEEP_TOLERANCE_2026-10-22.json) retains the proof.

The baseline has no sleep request/return markers. Permitted coalescing, runtime
scheduling, host descheduling and other sleep-adjacent delays remain distinct
possibilities. A reviewed future hosted comparison is required before claiming
an improvement. No new 20-second/600-second timing run or hosted dispatch was
performed for this change. Earlier 600-second failures and all original gates
remain unchanged; issue #92 remains open.
