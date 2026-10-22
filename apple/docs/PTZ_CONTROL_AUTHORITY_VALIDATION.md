# PTZ native controls and ordered Stop authority

This fixes runtime and keyboard-control regressions associated with #165,
which is closed; this change makes no new closure decision for that issue.
#90 remains open. Physical PTZ and keyboard/accessibility delivery remain
unqualified by these controlled fixtures.

The previous movement pad consisted of gesture-only images; the zoom buttons
had empty target actions. The replacement uses genuine `NSButton` controls.
The native target action requests a 250 ms nudge through two dispatcher
commands with the existing target and speed validation. Mouse down begins
continuous driving and returns immediately, allowing asynchronous sends to
run while held. Local mouse up ends only that input's exact motion lease,
without invoking the nudge action. No nested AppKit tracking loop, global
event monitor, invented AX role or synthetic accessibility action is used.

Each button retains its input's original Stop callback and lease. Callback
replacement, a stale timer, a stale mouse release, or dismantling an unrelated
button cannot stop newer motion. Focus/disable/dismantle retires that button's
input; owning-window/app deactivation and whole-section disappearance stop
the controller's outstanding interactive motion. Timers cannot survive those
revocations and stop a later pointer/external command or replacement connection.

The controller owns immutable target snapshots and an ordered operation tail
per transport generation. Queued superseded movement is discarded. An already
entered send finishes before the exact old-address pan/tilt and zoom Stops,
which finish before disconnect. Reconfiguration never sends old cleanup to a
replacement address, and late connection callbacks cannot overwrite replacement
state. Preset recall retires manual motion before the recall command.

The Network transport now awaits `.contentProcessed` or its owned two-second
failure deadline; it does not claim a device acknowledgment. Apple's
[send completion contract](https://developer.apple.com/documentation/network/nwconnection/send(content:contentcontext:iscomplete:completion:)-5ecuz)
reports local processing of sent content. Failure/timeout can leave physical
camera motion unconfirmed. A 250 ms nudge bounds the controller's intent;
network processing and camera behavior remain best effort and unqualified.
Connection identity guards prevent old cancellation/error callbacks from
clearing a replacement connection. Explicit disconnect is terminal for that
transport instance.

## Controlled evidence

Run `zsh apple/scripts/run_ptz_control_authority_harness.zsh`, using the shared
native build-slot wrapper when sharing a host. Compilation uses `-j2`. The
fixture compiles the actual PTZ controller, transport, native button, preset
store and VISCA codec. Only unused storage identities are supplied locally;
`PTZPresetStore(documentStore: nil)` performs no app-container/document IO.
An injected in-memory transport holds exact send edges. No actual network,
camera, visible window, global input, capture, TCC or system setting is used.

The unmodified controller from `44c078e` reproducibly fails with a held drive:
Disconnect completes before that drive and the Stop pair finish. Preserved
source: `/tmp/stream-wave6-ptz-controller-before-20261022.swift`.
The before log is `/tmp/stream-wave6-ptz-authority-before-20261022.log` (exit133).
It is actual controller code, with no extracted lifecycle replacement.

The frozen after log is
`/tmp/stream-wave6-ptz-native-authority-frozen-20261022.log`. Controlled checks cover:

- Held drive completion followed by old-target Stop pair and disconnect.
- Stale timer and pointer leases versus newer motion; expiry behind a held send.
- Focus cleanup canceling unsent movement before Stop.
- Immutable old address, replacement connection and stale state callbacks.
- Actual `NSButton.performClick` target-action issuing nudge and automatic Stop.
- Local pointer down returning so the async drive runs, followed by exactly one
  release Stop and no release pulse, including replaced callback ownership.
- Stale/uninvolved native-button teardown preserving a newer external motion.

The plain native positive control and PTZ button both return `AXUnknown` in
this host's offscreen context. The fixture records `UNQUALIFIED77` for platform
keyboard/AX delivery and makes no AX override or further locked-session/window
attempt. Its successful exit applies to the controlled ownership/native
target-action cases only. A real studio keyboard traversal, VoiceOver/AX
delivery, held-pointer window lifecycle and physical VISCA motion remain
unqualified. #90 remains open; these fixtures do not change #165's closed state.
