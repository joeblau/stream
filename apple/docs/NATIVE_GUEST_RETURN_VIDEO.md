# Native guest Program video return

The native interview receiver can send one explicitly enabled Program video
return to the current admitted guest. Start/Stop Program Video Return uses the
shared command dispatcher and the complete slot/peer/negotiation/generation
lease. Joining or rejoining does not enable video. Public stereo mix-minus
return continues independently.

The first profile is fixed Program, constrained Baseline H264, at most 320×180,
15 fps and 250 kbps. The encoder scales down without upscaling. It reserves one
encoder through the existing shared publishing/recording budget before adding
its Program tap. Insufficient capacity refuses this optional return. The UI's
ready state means a current encoded frame was accepted by the SDK; it does not
claim remote decode or playback.

The Composer tap and sender each keep bounded latest-frame mailboxes. Source
PTS reaches 90 kHz RTP without rebasing and uses the same host/NTP mapping and
CNAME as 48 kHz Opus. Sender reports use actual send-time NTP and extrapolate
the corresponding RTP clock at that instant, as required by
[RFC3550§6.4.1](https://www.rfc-editor.org/rfc/rfc3550.html#section-6.4.1);
media packet timestamps keep their original source PTS. Annex-B parsing, NAL count, access-unit size, packet MTU and
transport buffering are bounded. A failed or partially sent access unit is
never retried; the next attempt requests a fresh IDR. RTP sequence numbers and
source windows are consumed on attempted sends because SRTP may already have
consumed its packet index before a transport failure.

Off, privacy enter/restore, preview/pipeline stop, control close and lease
retirement synchronously revoke token authority. They do not wait for a codec
drain on the main actor. The encoder's serial queue invalidates its actual VT
session before removing the tap and releasing its reservation. A new explicit
enable installs a fresh actor-serialized Composer subscription. This barrier is
necessary: a previously entered composition tick can capture old scene pixels
and receive a newer host PTS after a privacy change; a timestamp cutoff alone
cannot fence that frame.

## Qualification evidence

Owned generated pixels/PCM, actual native Manager/default SDK, local Worker,
pinned owned Coturn and Chrome 155 on Apple silicon macOS 27.2/Xcode 27.2 were
used. Physical devices, deployed brokers and signed installation were not used.

| Check | Evidence/status |
| --- | --- |
| Explicit start/stop/restart | Actual H264 Chrome decode of green→black→purple Program; stopped track hidden; fresh opt-in required |
| Bounds and budget | Actual remote 320×180 H264; shared four-encoder admission denied while return holds one and succeeds after VT teardown |
| Rejoin and terminal lease | Old remote track ends; fresh lease begins video off; explicit enable decodes current Program; old full lease rejected |
| Partial network send | Four actual SDK RTP packets include FU-A START without END; next successful AU is IDR; Chrome recovers fresh green pixels |
| Held VT teardown | Real submitted VT frame held; Off returns under 100 ms, late send rejected; reservation remains until actual VT invalidation |
| Installation races | Held installation and held-before-install cancellation followed by replacement preserve only the replacement token/reservation |
| Privacy snapshot race | Actual Composer old red snapshot receives post-cutoff PTS and is rejected; fresh actor-installed subscription admits black slate |
| Control close | Immediate audio/video authority revoke and eventual return reservation removal |
| Packetization | ASan/UBSan checks exact FU-A reconstruction,1188/1189-byte boundaries, 64 KiB/64-NAL caps, RTP marker/SSRC/original PTS, sequence wrap and partial-send sequence consumption |
| End-to-end A/V synchronization | Actual decoded element-capture WebM flash/tone 6.35–74.92 ms apart in two full runs, strict 100 ms bound; independent video-element/AudioWorklet clock 17.97–80.25 ms apart; native Program cue 12.09–21.72 ms apart |

The generated PCM uses the retained primary-microphone channel identity while
the fixture refuses physical capture and disables VoicePolish. An earlier
unreferenced synthetic media channel was correctly pruned on Take, discarding
its authored future PCM and confounding the A/V cue. Keeping the generated
source within the controller's real demand model fixes the fixture; no
production audio clock, deadline or assertion was relaxed. Independent native
Opus leading-silence/onset checks locate the decoded cue within 21 microseconds
and the NTP/source-PTS round trip within 0.24 microseconds.

Clean/secondary selection, receiver-feedback adaptation, multi-guest allocation,
AEC/physical microphone behavior, Internet/mobile impairment and signed install
remain separate gates. The existing adaptation-policy harness qualifies policy
arithmetic only; this fixed profile does not claim measured feedback adaptation.

## Reproduce

The full owned runner requires Node 24.15, Chrome, ffmpeg/ffprobe, XcodeGen and
the pinned owned TURN server produced by `build_owned_interview_turn.zsh`.
`STREAM_VENDOR_ROOT` can select a clean external vendor checkout.

```sh
apple/scripts/run_native_interview_return_video_harness.zsh
# Independent partial-AU/lifecycle phase:
apple/scripts/run_native_interview_return_video_harness.zsh --video-fault-only
apple/scripts/run_native_guest_return_h264_harness.zsh
apple/scripts/run_native_guest_return_video_privacy_harness.zsh
```

The lifecycle subset runner additionally takes `STREAM_GUEST_RTC_INCLUDE`,
`STREAM_GUEST_RTC_LIBRARY` and `STREAM_INTERVIEW_RECEIVER_FRAMEWORKS` from a
qualified native runner build. It compiles the actual sender/sink/mixer/VT
sources with validation-only held-install/held-codec hooks. Those hooks and the
controlled partial-send receipt do not exist in a production build.
