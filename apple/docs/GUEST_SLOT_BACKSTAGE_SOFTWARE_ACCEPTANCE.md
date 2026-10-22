# Guest slots and backstage: bounded software acceptance

The original #129 feature requirements have native software evidence for stable
slots and reconnect identity, configurable offline cards, all five ordinary
editable layout families, bound names/titles, Take/source loss and project reload.
The original #128 feature requirements have native evidence for embedded roster,
health/capacity/errors, shared host commands, rename/mute/private Monitor solo,
scene placement, addressed private talkback and guest messages. See
[PERSISTENT_GUEST_SLOTS.md](PERSISTENT_GUEST_SLOTS.md),
[NATIVE_GUEST_PANEL_CONTROLS.md](NATIVE_GUEST_PANEL_CONTROLS.md) and
[NATIVE_GUEST_PRIVATE_MESSAGES.md](NATIVE_GUEST_PRIVATE_MESSAGES.md).

## Actual browser plus saved-slot lifecycle

`run_native_interview_return_audio_harness.zsh --slot-lifecycle` runs the shipping
manager, Dispatcher, default native SDK receiver, controller-issued sink and real
mixer against the actual owned Worker, UDP-only Coturn and shipping Chrome guest.
The fixture creates two saved slots before browser arrival, deliberately assigns
the second while waiting, and checks stable distinct camera/screen source IDs,
public reconnect identity and local name/title metadata. It reopens the actual
project document and source definitions before and after full-lease replacement.
Real decoded guest audio becomes positive in Program only after On Air; Backstage
removes it. Actual host/browser rejoin preserves the saved position while
requiring new admission and never replaying Program permission. Removal, room
end and permanent native cleanup retain their existing fences.

The fixture uses generated capture media. Its explicit `--slot-lifecycle` mode
uses real `AudioContext({sinkId:{type:'none'}})` contexts and verifies each
returned `sinkId`, with only the owned HTML player muted. This is a documented
[Chrome silent-sink API](https://developer.chrome.com/blog/audiocontext-setsinkid).
Both selected relay candidates are read from Chrome's real peer statistics;
native received guest PCM crosses the real Program routing gate. The muted
HTML receiver is not forced to consume return audio; optional codec/count stats
are reported as metadata, not a decoded-return PCM positive control. No fake media factory, synthetic ready receipt or fake
AudioContext replaces those paths. This mode **does not qualify normal HTML
output, speaker playback, acoustic/browser AEC or return-video synchronization**.
The default full audio fixture and its numerical gates remain separate.

On this locked/headless host, the real null-sink constructor can synchronously
block for over ten seconds. The focused mode schedules the actual preparation
handler outside a CDP request and waits for its real completion receipt; every
individual CDP request retains its original ten-second deadline. Failed original
and direct-null attempts remain failed. The native generated tool explicitly
models an unlocked studio through the existing injected resilience constructor;
it neither unlocks the host nor changes the production conservative default.
VoicePolish is configured Off in this synthetic routing fixture to avoid an
unrelated offline-effects graph initializing HAL. This does not qualify FX.

## Original validation and separate limits

The shared validation text permits a validated SDK. It does not require universal
mobile/desktop support, every acoustic device, more than one simultaneous native
peer, every return mode, endurance or signed installation as extra slot/backstage
feature requirements. The existing actual manager/browser Program/ISO fixture
measures incoming and recorded guest flash/tone within 6.1 ms around rejoin,
with zero rational Program/ISO cue difference and identical decoded audio:
[NATIVE_INTERVIEW_PROGRAM_ISO.md](NATIVE_INTERVIEW_PROGRAM_ISO.md).
Actual return routing, own-signal exclusion, private-message receipts and
addressed talkback PCM/Opus are separately documented and tested.

A TCP-only/no-UDP-listener local TURN case runs the actual full manager/media
route using the separately pinned, packaged/relinked optional SDK artifact:
[NATIVE_GUEST_TCP_PORTABILITY.md](NATIVE_GUEST_TCP_PORTABILITY.md).
That is restricted-network evidence within its declared validated-SDK scope; it
does not silently add TCP/TLS to shipping UDP defaults or qualify Internet/mobile
and deployed TURN. Qualified scopes can be combined without requiring all of
those consumers and environments in one fixture.

The separate #127 raw-return recording exceeded its unchanged 100 ms bound
(105.104 ms); later bounded passes do not establish a fix for that variable
failure. Normal-rendered output remains unqualified:
[GUEST_RETURN_AV_ORACLES.md](GUEST_RETURN_AV_ORACLES.md).
Neither incoming-sync evidence nor a silent-sink route pass relabels that result.

The focused run passed on macOS 27.2/ARM64, Chrome 155.0.8059.85 and Node 24.15.0
on 2026-10-22. Its exact source/artifact hashes, bounded final transcript and
failed-attempt distinctions are retained in
[GUEST_SLOT_BACKSTAGE_2026-10-22.json](GUEST_SLOT_BACKSTAGE_2026-10-22.json).
The final selected-pair receipt reported 133 Opus packets and 0 consumed samples,
consistent with muted/unconsumed HTML; it is not a PCM-output proof.
