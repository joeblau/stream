# Native interview tested capacity gate

The published native gate is **one admitted media peer** on the exact tested
configuration below. A second peer is refused without replacing the current
lease. This is a conservative tested gate, **not a measured maximum,
resource-derived hardware/network budget, or qualification of ten guests**.
The backend's configurable 1–10 ceiling and sixteen saved preparation slots do
not increase native media capacity. No new media run accompanies this document.

## Default UDP SDK

Tested host: 16-core Apple M3 Max **Mac15,8**, ARM64, **macOS 27.2 (26B118)**,
**Xcode 27.2 (27B5038j)**, **Chrome 155.0.8059.85**, **Node 24.15.0**. Fixtures
use the actual local Worker and owned Coturn, generated camera/screen/stereo PCM,
isolated storage and explicit local TURN provisioning.

[Program/ISO qualification](NATIVE_INTERVIEW_PROGRAM_ISO.md) runs the shipping
Manager, default SDK receiver, controller sink, compositor, mixer and recorders.
Both endpoints selected UDP relay around full-lease rejoin. Recorded segments
had 158,473/147,195 stereo PCM frames with bit-identical Program/ISO audio,
flash/tone differences within 6.1 ms and zero rational Program/ISO cue difference.
On Air needs acknowledgment; Backstage revokes Program; rejoin resets grants.

The separate actual-Worker [manager fixture](../scripts/native_interview_manager_harness.swift)
uses a controlled media host to prove second-guest refusal, pending-admission
unavailability, an unchanged current lease and no extra roster member. Actual
codec media is evidenced above. Production gates are
[Session.canAdmit](../StreamMac/NativeInterviewSession.swift),
[shared Manager command availability](../StreamMac/NativeInterviewManager.swift)
and [receiver-factory occupancy](../StreamMac/NativeInterviewReceiverAdapter.swift).

The [saved-slot browser receipt](GUEST_SLOT_BACKSTAGE_2026-10-22.json) separately
proves default-SDK admission, decoded Program routing, rejoin and end. Its muted
HTML/null-sink mode does not prove decoded browser return PCM. Return-feed
routing has separate [audio](NATIVE_GUEST_RETURN_AUDIO.md) and
[video](NATIVE_GUEST_RETURN_VIDEO.md) evidence with their own limits.

## Separate optional TCP validated SDK

[The optional TCP result](NATIVE_GUEST_TCP_PORTABILITY.md) uses the same named
host/OS/Chrome with native source baseline **40d0737**, not the later slot fixture.
Packaged/relinked CLI SHA-256:
`3a87b8a785813549a6bf7a3a58635ec0f218e671288f7363dd85bd5e30613f5d`;
measured optional SDK SHA-256:
`af13ee4c331ddcc21338ffddeb7bd472b10996ad6b99509bf8d0f6acd5be10cd`.

Actual Manager/receiver/controller/mixer camera/screen H264, Opus, screen
approval/denial/stop/retry/revoke, Program/Secondary/Clean return, own-signal
exclusion, mute/restore, private controls, rejoin and end passed. Before/after
rejoin, selected-relay/socket receipts showed TCP TURN and no UDP TURN listener;
the relay allocation remained correctly labeled UDP. This is a bounded
TCP-restricted local endpoint case. It adds neither TCP/TLS to shipping defaults
nor release adoption of the optional artifact.

## Retained receipts

Local retained filenames and SHA-256 values; linked documents describe fixtures:

| Evidence | Filename | SHA-256 |
| --- | --- | --- |
| Default one-peer media/rejoin/sync | `stream-macos-interview-program-browser-cadence-20261021.log` | `69f9f65a6692c2a2bb2a3c8d893cddccd8113f0db7e419ed9611c7f59d125724` |
| Actual second refusal/native gate | `stream-central-native-manager-20261021.log` | `5d99996df6d7101968bbb03fd8042ce98977d8c4c7771484a787400524a21a21` |
| Default saved-slot browser lifecycle | `stream-wave3-guest-slots-browser-relay-final-20261022.log` | `b7067db9ca6e9963d4fe0aa9a1b125082be092a23f48783f74fbae0b0c091106` |
| Packaged optional TCP media/rejoin | `stream-wave2-providers-media.log` | `a06eed92c5421c5b8692bfa52004d5c5c6d98fa55722b7d3c9f5dc73c1d155a2` |

## Scope

This publishes #125's bounded tested gate without a universal ten-peer or
deployment requirement. Higher counts, other hardware, Intel full media,
macOS 14 runtime, mobile/Safari, Internet/deployed TURN, long-call renewal,
physical capture/playout and signed installation remain unqualified.
#126 retains browser/mobile acceptance. #127 retains its unresolved 105.104 ms
raw-return result and unqualified normal-output/AEC; incoming sync does not
relabel that failure. See [return timing limits](GUEST_RETURN_AV_ORACLES.md).
This document changes no code, capacity, authority or issue state.
