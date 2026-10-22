# Explicit live-clock sleep tolerance

The compositor now passes `tolerance: .zero` to its existing
`ContinuousClock.sleep(until:)` call. The [Swift API source](https://github.com/swiftlang/swift/blob/main/stdlib/public/Concurrency/ContinuousClock.swift)
permits wake coalescing when tolerance is unspecified. This change requests zero
additional tolerance; it does not guarantee on-time resumption or establish a
cause or fix for the hosted VM frame deficit. Deadlines, schedule arithmetic,
FPS, PTS, rendering, mailboxes, encoders and QoS remain unchanged.

Generated-only counters bracket that same call with ContinuousClock request and
return distances and system-uptime wall endpoints. Observed return lateness is
task resumption relative to the existing deadline, including runtime/host
scheduling; it is not a kernel-wake or coalescing measurement. Wall time includes
suspension, resumption and bookkeeping. No CPU delta spans the suspension. New
observer work after return precedes the next tick and is absent from the baseline.

Each generated clock captures a profile epoch before creating its Task. The
helper checks that epoch and commits its event and all successful aggregates
atomically under the existing lock. Reset rotates the epoch under the same lock,
so an old canceled or successful return cannot pollute the next case. Canceled
events stay separate from successful aggregates. Clock-loop iteration is not
asserted to be a rendered-frame ID; other existing counters retain their semantics.

The unchanged six-case actual-engine lifecycle suite passes. The CPU-only actual
helper regression rejects stale canceled/successful returns after reset and
checks canceled-point aggregate exclusion. Generated sleep code typechecks with
the actual helper, and the generated engine parses. The new generated full trace
was not built or timed locally. [The proof receipt](COMPOSITION_SLEEP_TOLERANCE_2026-10-22.json)
retains source, compiled engine identity, observations and original logs.

```sh
zsh apple/scripts/run_composition_sleep_epoch_harness.zsh
```

A separately reviewed hosted diagnostic comparison is required before claiming
any timing improvement. No new local benchmark, hosted dispatch, original
600-second workflow change or qualification-gate change accompanies this fix.
Issue #92 remains open.
