# Guest mute, monitor solo and local names

The embedded Guests panel exposes mute and monitor solo for the current ready
connection. Both edit the existing persisted mixer document through
StudioCommandDispatcher, using the same channel as the Mixer inspector. There
is no separate guest gain, mute or solo state. Mute affects the guest channel;
solo affects private Monitor after Monitor admission and leaves Program
unchanged. A saved solo for a guest without Monitor permission grants no route
and does not suppress unrelated private audio.

The room panel displays admitted and waiting counts against the one native
media connection limit. Admission availability uses the same pending-admission
and occupied-peer gate as execution, including through the palette and local
controllers; a second waiting guest cannot displace the current connection.

Each panel/palette command captures the full room, host and guest generations,
slot, negotiation and native receive generation. Retained commands and adapter
callbacks reject a rejoined/replaced connection before changing settings. A new
authorized stable catalogue request resolves its current action normally; saved
slot Mixer configuration remains editable independently of room admission.
Local-name and message composer view identities also use that complete context,
so replacing any authority clears their transient editing state.

Save Local Name changes the project's optional `GuestSlot.localName`, used by
the panel and bound name overlays. Guest-reported `displayName` keeps its own
identity and can update without erasing the alias. Use Guest Name removes the
alias. Prepared slots may also configure an alias before arrival. Local names
persist and travel as literal public content in portable shows; they are not
sent to the Worker and never change an invite, credential or service identity.

Qualification uses the actual owned local Worker with URLSession HTTP/WebSocket,
the shipping manager/controller/dispatcher and real mixer PCM. The manager
fixture checks two independent tones: mute removes only the guest, monitor solo
excludes unrelated audio without changing Program, saved mute/solo reload through
the real settings file, and stale full-context commands/callbacks cannot edit a
rejoined guest. Actual project reload and portable reference remapping preserve
literal aliases. The slot renderer fixture checks that nested bound text equals
an independently rendered literal caption, retains its local alias when service
metadata updates, and restores reported-name pixels when cleared.

Run `apple/scripts/run_native_interview_manager_harness.zsh` with pinned
Node 24.15+/npm 12 installed in `workers/interviews`, then
`apple/scripts/run_guest_slots_harness.zsh`. The established generated fixture
boundaries isolate defaults and credentials and refuse device capture. The
manager media host is controlled; these tests do not qualify browser decoding,
deployed TURN, Internet/mobile/restricted networks or operator devices.

One native admitted media peer remains the measured limit. Private text is
implemented separately in `NATIVE_GUEST_PRIVATE_MESSAGES.md`. Addressed private
microphone talkback is described below. External browser/network/operator
qualification remains open; this change does not close issue #128.

Local software qualification on 2026-10-21 passed with Xcode 27.2 on Apple
silicon: the whole-source manager/Worker/SwiftUI fixture, standalone native
service-control fixture and slot renderer/project/H.264 fixture. The manager
also checks that pending admission immediately becomes unavailable, a second
actual guest is refused by the configured one-guest Worker room, and the active
full lease remains unchanged. This establishes the configured capacity guard;
it does not qualify multiple simultaneous native media peers.

## Addressed private microphone hold

Hold to Talk Privately uses the already running primary microphone and the
guest's current ready audio return. It never starts capture or requests consent.
The existing microphone permission must still be granted. A duplicate capture
of the same physical input is refused. The hold captures the full peer lease
and a fresh press UUID; an old press cannot start or end a replacement hold.
Mouse/Space release, focus loss, view removal, sleep/lock, source changes, guest
replacement, room end and runtime shutdown end the hold. Ten seconds is the
maximum; reconnect and wake never replay it.
The mixer and final return-send gate enforce the same deadline independently
of the UI task, including while the main actor is blocked.

Only the selected recipient's return receives the microphone at unity while
held. The microphone is hard-excluded from Program, Monitor, Aux and both
pre/post-insert isolated recording taps. Other sources keep their routes, and
private microphone levels cannot drive public music ducking. Public mixer
faders, mute, solo, sends, delays and project documents are unchanged. Private
speech bypasses microphone effects; both transitions clear the microphone's
FX/converter/ring history. Release restores its prior routing, so newly captured
speech after release or safety cancellation may be public under those settings.

Capture timestamps are retained. Transition floors reject old, invalid or
future-dated buffers and survive channel replacement. Private return work uses
the existing synchronous full-lease/revision gate; release invalidates queued
PCM and the Opus encoder discards its old partial packet and codec history.
SDK bytes accepted before revocation cannot be recalled. No private route or
hold is persisted, exported, recorded or automatically retried.

On 2026-10-21, `run_guest_return_audio_harness.zsh` passed native PCM/Opus and
real mixer checks for private-positive return, public/Monitor/Aux/pre+post ISO
exclusion, unaffected public music with an enabled mic sidechain, exact fader/
Aux/140ms delay restoration, FX bypass/reset, late captured buffers across
channel replacement, queued-return revision invalidation and stale press/lease
refusal. Actual return packets also retire the private revision at the ten-second
deadline while the main actor is deliberately blocked for 10.4 seconds.
`run_native_interview_return_audio_harness.zsh` passed with the shipping
manager/dispatcher/default receiver/controller sink, owned local Worker/Coturn
and Chrome 155.0.8059.85: native recipient PCM and actual decoded Opus carry the
private tone while actual forbidden taps exclude it; explicit/focus/deadline
release, active reconnect cancellation and deliberate new-lease holds pass.
Inputs are generated; device capture and operator permissions are refused by
the fixture. Physical microphone/AEC, signed installation, accessibility and
operator hold behavior, mobile and deployed/restricted networks remain separate
qualification gates.

`run_native_talkback_button_harness.zsh` additionally passes the exact shipping
Cocoa control in an owned window: real mouse tracking until its posted mouse-up,
Space down/repeat/up, modified-key refusal, responder loss and view removal.
It initializes no runtime, capture, credential store or permission request.

Assistive-technology activation has explicit start/stop semantics because an
accessibility Press has no matching key or pointer release. The native control
announces “Start private talkback (10 seconds maximum)” while inactive and
“Stop private talkback” with its active microphone value during the interval.
Activate again to stop early. The control releases automatically at ten seconds,
in addition to the manager and media path's existing independent safety deadlines.
It uses the same accepted press UUID and current guest lease as mouse/Space;
rejected starts do not latch. Focus loss, removal, stale lease and manager
revocation retain their cancellation paths, and reconnect never starts speech.
After release, speech may return to the microphone's prior public routes.

The small Cocoa fixture also invokes the actual public
`accessibilityPerformPress()` implementation: accepted begin/early stop, disabled
and rejected starts, native labels/values, the real ten-second automatic release,
cancelled prior timers, focus/removal, manager revocation and a fresh deliberate
start all pass. These are actual control/callback proofs; they do not claim a
spoken VoiceOver session or qualify the studio's remaining contrast/traversal
requirements in #90.
