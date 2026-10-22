# Composition clock authority after stop or replacement

Canceling the tick task does not revoke an actor call that already passed the
loop's cancellation check. Such a call can enter after `stop()`, a new `run()`
or `setOutput()`. The old clock can then pull the current scene's sources,
render a frame, or add its missed deadlines to the replacement run's metrics.

Each clock now captures an opaque run token. Stop and replacement invalidate
that token; tick and missed-deadline entry require both the current token and
an uncanceled task before touching providers or metrics. This adds no wait or
join. An authorized synchronous tick still completes on the engine actor; the
scheduler, actual host-clock PTS, frame duration, geometry and render path are
unchanged. Consumer mailbox draining remains independent.

Explicit synchronous `renderValidationFrame` retains its existing authority to
render after its autonomous clock is stopped, including from a canceled fixture
caller. The clock's async gates, past initial deadline offset and exit receipt
exist only under `STREAM_NATIVE_VALIDATION`; they are absent from shipping.

The focused fixture uses the actual `CompositionEngine` task, tick, scheduler,
renderer and injected owned pixel source. Continuations pause an old clock
between its loop check and tick entry, or before applying an actual positive
skip result. The fixture then stops or replaces the run before releasing the
old task. Per-run hook capture prevents restart from redirecting old gates.
There are no sleeps, timing retries or substitute scheduler implementation.
A validation-only initial deadline one second in the past makes the unchanged
production schedule helper return a positive skip count deterministically.

The negative control removes only the two entry guard statements. All five
unchanged assertions fail, with durable observations written before each trap:

| Retired operation | Guard-only negative observation | Guarded result |
|---|---|---|
| Tick after stop | Attempts and owned source/override pulls 0 → 1 | Unchanged |
| Tick after new run | Replacement attempts and pulls 0 → 1 | Unchanged |
| Tick after output reconfiguration | Replacement attempts and pulls 0 → 1 | Unchanged |
| Missed deadlines after stop | Missed deadlines 0 → 29 | Unchanged |
| Missed deadlines after new run | Replacement missed deadlines 0 → 29 | Unchanged |

All six positive cases pass, including explicit validation. After rejection of
the retired work, the current clock renders exactly one actual owned frame,
with the requested scene, 16/32-pixel geometry and 30/60-fps nominal duration.
The [machine receipt](COMPOSITION_CLOCK_AUTHORITY_2026-10-22.json) binds source,
compiled positive/negative identities, observations and original logs.

To reproduce on a host with an owned clean vendor root, run the focused tool
under the usual native build-slot reservation:

```sh
STREAM_VENDOR_ROOT=/path/to/owned/Vendor \
  zsh apple/scripts/run_composition_clock_authority_harness.zsh --negative-control
STREAM_VENDOR_ROOT=/path/to/owned/Vendor \
  zsh apple/scripts/run_composition_clock_authority_harness.zsh
```

The negative runner succeeds only when each child fails its exact expected
invariant. The positive runner requires all six cases to pass. A process-group
deadline bounds a broken fixture; it does not drive the ordering assertions.
No camera, microphone, desktop capture, normal audio device or publisher starts.

This is lifecycle correctness. It does not prove the cause of the earlier
601-render/600-writer trace split, resolve hosted frame deficits or qualify any
throughput target. No 20-second/600-second benchmark or hosted dispatch was
performed for this fix; issue #92 remains open.
