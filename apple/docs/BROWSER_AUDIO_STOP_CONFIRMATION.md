# Browser capture retirement confirmation

A native capture stop now returns `confirmed` or `unconfirmed`. A throwing `SCStream.stopCapture()` is unconfirmed unless the exact one-shot stream has independently delivered its actual stopped delegate callback. Prepared streams whose start was never invoked need no native stop. Successful stop after native start completion is remembered, avoiding an unnecessary second stop that could replace a real acknowledgment with an invalid-state error. A genuinely pending start still requires retirement after its completion; a thrown start is not itself stop confirmation.

Capture revokes its PCM inlet before waiting for opaque work. An unconfirmed run keeps its exact native producer, holdback and admission. A process-owned quarantine retains it even when external references disappear. New capture preparation is denied while any failed owner remains unconfirmed. A failed first stop publishes this fence before waiting for a still-pending start. Explicit retry visits retained runs once, coalesces an existing attempt, and cannot stop a different active run. Confirmed cleanup releases each admission once.

Session shutdown retains the exact old helper connection and local pages until capture retirement is confirmed. Completed-but-unconfirmed shutdown cannot be cleared by a new load. The caller can explicitly retry with `retryPendingShutdown()`; `retryRetainedShutdowns()` also reaches process-retained owners. Only confirmed capture retirement permits mixer history reset/removal and helper termination. Local files still wait for the actual owned helper process to exit. The native transport keeps its prior socket fence and session-owned termination ordering.

Admission is bounded by `BrowserWidgetAudioCommand.maximumWidgets * 2`: capture runs include preparing, active, retiring and unconfirmed owners; helper-session owners include launching, active and capture-pending shutdown. Unknown owners are never evicted to admit another. The helper-session bound is not a bound on OS processes after a termination request: `hasTerminated` remains the local-file cleanup acknowledgment. These are conservative software ownership limits, not measured hardware capacity.

Explicit retry is bounded in attempt count, not native wall-clock duration. Opaque native awaits retain their owner/admission and keep fresh loads fenced. The controlled test executable's 45-second deadline bounds the fixture; it does not manufacture a native stop acknowledgment or promise a production stop deadline.

## Controlled qualification

Run from `apple`, using a separately built matching Core framework:

```sh
BROWSER_STOP_CORE_FRAMEWORK=/immutable/StreamCore.framework \
BROWSER_STOP_BUILD_DIR=/fresh/owned/proof-directory \
zsh scripts/run_browser_stop_confirmation_harness.zsh
```

The runner snapshots production inputs, derives unchanged production identity declarations, copies the supplied Core framework and compiles with Swift 6 / two jobs. It runs the actual Capture and Session owners with controlled producer/transport edges and the actual mixer constructor, registry and holdback primitives. The mixer clock is never run. No actual helper, WebKit, SCK stream, IPC, device, output graph or network is opened. Local-file tests use fresh owned fixtures only.

The positive Capture suite includes the previous discovery/start/callback ownership tests plus completed-start single-stop, failed-stop strong ownership and admission/lease retention, stale PCM rejection, explicit retry, refusal before external preparation, pending-start failed-stop fencing and cancellation admission release. The positive Session suite preserves the previous helper close-order tests and adds native-unconfirmed file/helper retention beyond external references, staged-file cleanup across the second shutdown barrier, fresh-load refusal, global owner admission and explicit retry.

Three negative variants change only the relevant owner policy: discard the Capture stop outcome, ignore Session stop confirmation, or move helper close before capture cleanup. They must fail the unchanged assertions. This distinguishes the new stop-confirmation checks from the previously established asynchronous ordering proof.

The receipt records first and final controlled source/compile/runtime artifacts, the supplied Core framework and identity slices. Actual ScreenCaptureKit stop/delegate behavior and actual helper process termination remain source-reviewed; these controlled cases do not execute those operations. They do not establish browser audio attribution, tail behavior, Program/ISO/monitor sound, channel layout, levels, A/V timing, speech or absence of duplicate audio. The production selector remains disabled and #124 remains open.
