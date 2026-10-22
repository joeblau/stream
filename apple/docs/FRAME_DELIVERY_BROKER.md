# Admitted frame delivery and source-buffer isolation

`CompositionEngine` publishes each Program, secondary, or clean composition through a separate `FrameDeliveryBroker`. The broker keeps two common source frames and permits one synchronous trusted transfer at a time. Together with the next render, this preserves the existing four-buffer source-pool limit. Scheduled work and recipient queues contain publication identity and sequence values; they do not capture source samples. Publication identity has its own epoch and counter because the engine deliberately resets its public frame sequence on restart.

Each independent raw destination, shared encoding group, recorder, monitor, camera, external display, or guest-return ingress needs its own admitted private bank. A single private bank before an aggregate raw publisher fanout would still couple its destinations. The publishing integration therefore registers each raw endpoint or shared encoder group separately; compressed group fanout remains shared.

The transfer worker allocates from the recipient's bounded bank, borrows one source inside a closed helper, and completes the selected copy/conversion before returning a detached `CompositedFrame`. Only that detached packet enters the recipient's independent callback queue. A full private bank drops that recipient's transfer and the worker proceeds to another recipient. An already executing callback may finish after removal; its queued backlog is cleared. Exact lease identity prevents its late removal from closing a replacement. Final counters live in the caller-owned lease, including across same-token replacement; no retired-lease history is stored globally.

Synchronous admission prepares the actual source and private pools before an output factory runs. The asynchronous engine installation ACK precedes publisher/writer activation. Source ownership moves into an engine-owned child receipt; rolling back a stale preparation receipt cannot close a source bank shared by another output. Cancellation is a per-admission shared object, without a global canceled-UUID inventory. Source-bank geometry follows the same rounding as `SceneRenderer`; proposed geometry never changes a currently active allocator before adoption.

The companion resource coordinator accounts actual stride/IOSurface storage and all admitted bank ceilings against its explicit conservative software policy. Recording uses its original queue count/decimal-byte policy plus the actual delivery/native/copy headroom, rather than an arbitrary four-buffer recipient default. Exposed generations remain charged after retirement; generic callback completion, stop ACKs, attachment removal, or an all-N pool checkout cannot prove that arbitrary surface aliases are gone. Never-exposed failed preparation is refundable only after the real pool is closed and detached. This policy can deny a new start while prior generations remain charged.

The copy contract preserves visible BGRA bytes, alpha, independent row strides, original timing and public sequence. It copies bounded color values and explicitly decodes/re-encodes `RecordingChatPaint`, whose `ShouldNotPropagate` attachment carries recording comment/page receipts. Arbitrary attachment graphs are not propagated. Sealed fit/camera conversions preserve their existing black-letterbox/sRGB/cadence semantics and finish before any SDK callback. Properly retained CV/sample or tracked-surface references pin only their recipient's storage. Bare surface aliases still require the public API's normal use-count/lifetime rules within an active generation; they do not authorize reuse across output sessions.

## Actual native regression evidence

The dated JSON receipt binds the production source, generated control sources, actual compiler graph, logs, observations and binary. The retained `53edc59` matrix ran the actual engine and renderer with owned 16-pixel shapes:

- Four independent consumers retained extracted CVPixelBuffers and IOSurfaces after callback return and removed every attachment. Each private bank held four buffers and reported eight capacity drops. All 12 compositor attempts rendered and reached the healthy recipient at the unchanged source cap of four.
- Removal and same-canvas replacement on all three planes cleared pending packets while an existing callback remained blocked. Cross-canvas token behavior, cancellation before installation, fresh storage after restart, and the old lease's final receipt after replacement passed.
- A metadata-only gate held an old transfer across actual engine stop/restart. Two public sequence-1 frames preserved their distinct timestamps and pixels. All six existing actual clock-authority cases also passed.
- Changing only the returned sample from the detached sample to the original produced four renders, eight source failures, and only healthy frames 1–4. The same healthy-continuation assertion failed.
- Changing only publication lookup back to public frame sequence failed the same restart timestamp/pixel assertion.

The `1f6db48` followup aligns admitted dimensions with the renderer's existing rounding. Its actual-engine boundary case uses a 16.5 × 17.5 canvas and requires three 17 × 18 renders and deliveries through both explicit admission and the detached compatibility registration, with one stable source request. That boundary case also passes in the final retained matrix. An initial fixture-directory environment-name mismatch reused generated-source paths; the corrected runner repeated both controls and the full suite in separate directories and preserves each exact executable. Earlier raw logs and observations remain intact.

These prove bounded storage separation and lifecycle behavior for the controlled native cases. They do not establish arbitrary SDK progress, GPU/CPU scheduling isolation, live hardware qualification, or sustained 1080p30 capacity. Existing #92 performance failures and the original 600-second/17,850-frame/80-ms gates remain in force. The new per-output copies have a cost that still needs qualification on the complete integrated workload.

Reproduce in an isolated checkout with the complete resource/converter/integration cohort present:

```sh
zsh apple/scripts/run_frame_delivery_broker_harness.zsh
# Separate generated controls; no production source is edited:
zsh apple/scripts/run_frame_delivery_broker_harness.zsh --negative-control
zsh apple/scripts/run_frame_delivery_broker_harness.zsh --sequence-negative-control
zsh apple/scripts/run_frame_delivery_broker_harness.zsh --fractional-geometry
```

The runner uses two build jobs, explicit Swift limits and a 90-second runtime process-group deadline. Synthetic pixels only: no capture device, network, personal media, output driver, UI interaction, or performance benchmark is needed. The hotpath generator was updated and generated successfully without executing another trace. Its mailbox spans now describe detached private packets; historical source-sharing traces retain their original meaning and receipts.

Audit the dated machine receipt against the retained files without executing native code:

```sh
python3 apple/scripts/verify_frame_delivery_broker_receipt.py
```

Before any future performance invocation, its healthy-recording fixture must use the admitted Q+5 recording policy instead of the generic compatibility registration's small recipient bank. That fixture wiring is separate from these ownership regressions; no new performance invocation was made here.
