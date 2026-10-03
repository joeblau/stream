# Native guest audio return (#127)

The native host can send the public show audio to its single admitted guest,
with that guest excluded before clamping. Return listening is independent of
permission to enter Program or Monitor. Monitor-only material and all private
Aux material are excluded; addressed talkback is not implemented.

The receiver prototype stays receive-only unless its explicit return-audio
option is enabled. The production adapter enables that option only after the
public native Opus converter is available. Unsupported codecs/OS configurations
report return unavailable while retaining the incoming-media path. No room,
credential, permission or device is created automatically.

## Routing, ownership and bounds

Each return tap belongs to a complete `GuestReceiveLease`: stable slot, peer,
negotiation and monotonically admitted generation. It sums actual post-fader,
post-insert, post-duck Program contributions, omits its recipient, then applies
Program master gain and clamps once. It never subtracts from clipped Program.
A denied guest cannot enter another recipient's public mix.

Return policy defaults off. Synchronous revoke, replacement and retirement
invalidate full-lease/revision receipts, including queued work after an immediate
reopen. Mixer reset and Program master silence invalidate older return receipts.
Callbacks already accepted before a policy change remain accepted; later queued
PCM and final SDK sends recheck authority. The sink gate orders the final send
against close. SDK bytes already accepted for transmission cannot be recalled.

The mixer emits its original 48 kHz host-clock 512-frame chunks. Each return
mailbox holds at most eight chunks and drops oldest independently of Program,
Monitor, recording or another consumer. The serial encoder assembles at most
1,472 pending stereo frames into real 960-frame/20 ms Opus packets. Codec priming
is read from the native converter (312 frames on the qualified OS) and reflected
in packet source timestamps. A source discontinuity resets codec history and
counts the un-emitted source tail; it neither pads revoked audio nor rebases a
new source to network arrival. Native PCM/packet validation remains bounded.

The sender rejects source chunks older than 250 ms. It retains no application
outbound byte queue or retry backlog. Each send requires the current lease,
revision, open control/track, connected SDK peer, at most 16 KiB SDK buffered
bytes and an actually selected local TURN-relay candidate. Each real Opus packet
is at most 1,275 bytes. RTP advances on the original 48 kHz grid; compound RTCP
SR/SDES reports the same source host-to-NTP mapping every 25 packets.

The guest page accepts only the negotiated audio/camera return MIDs and retains
at most one track of each kind in the current negotiation. Reset clears the
return stream; obsolete track callbacks cannot replace it. Its Opus answer
explicitly requests stereo, as defined by [RFC 7587](https://www.rfc-editor.org/rfc/rfc7587.html#section-7.1).
Without that preference, the tested Chrome answer downmixed a real stereo
native return into identical channels despite the host's stereo offer.

A replacement host generation resets prior guest admissions and public
Program/recording status before publishing its new roster. The actual
`host-disconnected` event clears old browser media, and the new host must
explicitly readmit the guest. A late close from the superseded host cannot
revoke that new admission. This also covers takeover before the old socket's
close callback, which otherwise left the guest on air without a usable session.

## Actual native qualification (2026-10-03)

Apple Silicon Mac15,8, macOS 27.0.1 (26A434), Xcode 26.6 (17F113),
Chrome 154.0.8037.95, Node 24.15.0 and the pinned public libdatachannel 0.24.0
UDP-relay build were exercised. These are actual controlled native/browser
fixtures, not physical-device or deployed-service qualification.

`run_guest_return_audio_harness.zsh` builds/reuses an owned Core-only framework;
its sources do not initialize credential stores, input capture, permissions or
network services. It exercises actual native stereo Opus encode/decode, original
nanosecond PCM grid, packet count/duration, declared priming cue, genuine
2,400-frame discontinuity and truthful un-emitted-tail count. It also exercises
the real mixer: Program actually clips while the recipient keeps the unclipped
local contribution; own guest and an actually active private Aux tone are
absent; source PTS/count match Program; mute and nonunity restoration work;
slow bounded delivery drops; revoke/reopen, replacement and permanent retirement
fence queued receipts.

`run_native_interview_receiver_harness.zsh` additionally holds the actual mix
actor during return-tap preparation, closes the return sender before completion,
and proves its retained tap is removed while the incoming guest lease stays
registered. Its existing held screen/control-close and SDK lifetime checks remain
intact. The return-close seam is compiled only for this native validation tool.

`run_native_interview_return_audio_harness.zsh` builds the entire shipping desktop
source graph with the existing generated fixture boundaries. Keychain and
operator defaults/storage are isolated, the automatic microphone entry refuses
capture, and the App entry is replaced by an owned bounded CLI. Manager,
Dispatcher, Controller-issued sink, receiver factory, mixer, converter, SDK and
guest page remain shipping code. Only signaling/TURN credentials and media
producers are owned fixtures.

An owned self-origin AudioWorklet asset measures actual decoded PCM in bounded
2,048-frame Hann spectral windows and emits only compact count/RMS/tone receipts.
It runs under the real guest page CSP, with no CSP bypass; the shipping assets
are copied byte-for-byte into the owned local fixture asset folder. This avoids
main-thread capture disturbance and does not assume phase stays constant across
adaptive WebRTC playout. Native source/RTP clock assertions remain separate.

That fixture runs the actual Worker locally and actual Coturn, and connects an
isolated Chrome profile to the real guest page. Both peers select local relay
candidates. Chrome actually decodes the stereo Opus return: local 1000/1700 Hz
signals survive while the guest's real 440/880 Hz signals are first measured
positively in Program and then excluded from its return. Local mute produces
zero decoded PCM, nonunity fader restoration changes both channels, rejoin
requires a newer full lease and a fresh actual remote track object, and removal
clears/ends the prior return. Only spawned owned children are terminated; their
private capability/configuration IPC is not logged and is cleaned afterward.

The host-generation regression failed against the previous Worker and passed
after the admission reset using actual workerd WebSockets. All 19 Worker tests
and 11 reference-host client tests passed. The final native/Chrome fixture
also passed immediate host replacement, old-stream cleanup, explicit admission
and a new full-lease return. The existing reference browser fixture passed
with both optional audio and video return from its controlled browser host;
that compatibility check does not qualify native video return.

Run the mixer/codec fixture from the repository root:

```sh
zsh apple/scripts/run_guest_return_audio_harness.zsh
```

Run the full browser fixture after installing the pinned `workers/interviews`
lockfile dependencies with Node >=24.15 <25. Set `STREAM_INTERVIEW_NODE` to that
Node executable, `STREAM_INTERVIEW_TURN_SERVER` to the pinned owned Coturn
executable and `STREAM_GUEST_RTC_INCLUDE` to the **same runner-derived** SDK
include path (`.../Build/Products/Debug/include/libdatachannel`); it is populated
by the real package build. The runner verifies/reconstructs transport artifacts
through `repair_desktop_transport_archives.py --require-relay-policy`. Optional
`STREAM_VENDOR_ROOT` and `STREAM_INTERVIEW_REFERENCE_ARTIFACTS` supply read-only
qualified dependencies; all generated/build files remain under
`STREAM_INTERVIEW_RETURN_DIR` / `STREAM_INTERVIEW_RETURN_BUILD_PATH`.

```sh
zsh apple/scripts/run_native_interview_return_audio_harness.zsh
```

The bounded video target policy and its hysteresis fixture can be exercised
without a relay or browser:

```sh
zsh apple/scripts/run_native_guest_return_video_budget.zsh
```

## Remaining acceptance

Issue #127 stays open. This implementation has one native admitted guest, not a
qualified multi-guest product. Selectable Program/clean/secondary video return,
outgoing video encoding/routing, addressed private talkback and audio/video
return synchronization are not implemented. A bounded video target policy now
defines three profiles (320x180@15/250 kbps, 640x360@24/650 kbps and
1280x720@30/1.5 Mbps), rejects out-of-range/stale observations, steps down
after three congested windows and steps up after eight stable windows over at
least three seconds. Its fixture validates those transitions and the profile
ceiling. It consumes caller-supplied estimates and queue/drop observations; it
does not measure network capacity, select a return source, encode video or send
video. Thus bounded adaptive video bandwidth is not yet integrated into the
guest connection. Browser AEC is requested by device
check, but physical acoustic AEC/headphones behavior is unqualified. Mobile,
restricted networks, deployed TURN broker, other codec/OS/architecture variants
and signed app installation need their actual qualification. The local Worker
and owned relay prove the real software route; they do not establish those
additional capabilities.
