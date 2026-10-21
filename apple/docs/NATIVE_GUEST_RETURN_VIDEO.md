# Native guest selectable video return

The native interview receiver can send one explicitly enabled Program, Secondary canvas or Clean video return to the current admitted guest. Source selection
and Start/Stop Video Return use the
shared command dispatcher and the complete slot/peer/negotiation/generation
lease. Changing the source stops video and requires a new Start. Joining or
rejoining resets the selection to Program and does not enable video. Public stereo mix-minus
return continues independently.

The first encoding profile is fixed constrained Baseline H264, at most 320×180,
15 fps and 250 kbps. The encoder scales down without upscaling. It reserves one
encoder through the existing shared publishing/recording budget before adding
its composition tap. Clean is a separate render of the same Program scene,
background and transition at the same source PTS, with project overlay nodes
and live annotations omitted; scene layers remain. Secondary also owns canvas source demand through that
subscription and uses the existing qualified additional-canvas gate. Currently
that gate admits the measured 16-core M3 Max Mac15,8 only; other machine classes
refuse Secondary explicitly. Removing the configured Secondary layout stops
return and releases its encoder/demand after teardown; restoring the layout
does not replay an earlier Start. Insufficient capacity refuses this optional
return. Clean also checks the existing 4K30 total Program-engine compositor
ceiling, including actual Secondary output/monitor demand. A later monitor
demand that exceeds the ceiling retires optional Clean before adding that
monitor. Clean rendering checks the current source token before drawing, so
revocation stops its additional raster while a submitted VT frame can still be
draining. The UI's
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
| Program/Secondary/Clean selection | Actual purple landscape Program and blue 100×180 portrait Secondary; independent scene content, source-demand ownership, layout removal and explicit restoration; separately composed Clean omits the actual red project overlay |
| Rejoin and terminal lease | Old remote track ends; selected Secondary resets to Program/off; explicit enable decodes current Program; retained source/start commands from old full lease rejected |
| Partial network send | Four actual SDK RTP packets include FU-A START without END; next successful AU is IDR; Chrome recovers fresh green pixels |
| Held VT teardown | Real submitted VT frame held; Off returns under 100 ms, late send rejected; reservation remains until actual VT invalidation |
| Installation races | Held Program installation→Secondary replacement and held-before-Secondary-install→Program replacement preserve only the new token/capability/reservation |
| Privacy snapshot race | Actual Program, Secondary and Clean Composer old red snapshots receive post-cutoff PTS and are rejected; fresh actor-installed subscriptions admit black slate |
| Clean raster semantics | Same-PTS actual Program shows green project overlay/red annotation; Clean retains blue scene layer/purple project default background, omits both; zero remaining subscriptions |
| Late Secondary geometry | Canceled landscape installation cannot alter a newer portrait subscription's actual pixels/geometry or attach its old tap |
| Pre-BEGIN Host cancellation | Actual Host claims source intent before scheduling; no-yield Start→privacy stop→restore cannot replay; explicit replacement Start survives held old installation; outstanding jobs bounded at two |
| Control close | Immediate audio/video authority revoke and eventual return reservation removal |
| Packetization | ASan/UBSan checks exact FU-A reconstruction,1188/1189-byte boundaries, 64 KiB/64-NAL caps, RTP marker/SSRC/original PTS, sequence wrap and partial-send sequence consumption |
| End-to-end A/V synchronization | Two fresh rendered captures per source: Program 64.44/37.02 ms, Secondary 10.65/74.23 ms, Clean 76.96/43.98 ms; every decoded/rendered cue within strict 100 ms and native Program cue within 50 ms; independent element/worklet bound also 100 ms |

The generated PCM uses the retained primary-microphone channel identity while
the fixture refuses physical capture and disables VoicePolish. An earlier
unreferenced synthetic media channel was correctly pruned on Take, discarding
its authored future PCM and confounding the A/V cue. Keeping the generated
source within the controller's real demand model fixes the fixture; no
production audio clock, deadline or assertion was relaxed. Independent native
Opus leading-silence/onset checks locate the decoded cue within 21 microseconds
and the NTP/source-PTS round trip within 0.24 microseconds.

The default runner separates the complete source-control/lease/budget lifecycle
from six fresh final-phase rendered captures (two per source). Each capture
retains strict 50 ms native-source and 100 ms rendered-recording and independent
element/worklet bounds, then retires the full lease. A capture observer never
precedes later source switching in that invocation.

The earlier raw-track MediaRecorder path measured a 117.44 ms Secondary cue
difference after controlled partial-FU-A loss while the independently measured
video-element/worklet cue was 2.58 ms and the native cue was 13.40 ms. The owned
raw artifact `decoded-return-1792611734235.webm` and log
`stream-macos-native-return-video-clean-raster-gate-final-20261021.log` retain
that failure. Raw-track re-encoding and synchronized element rendering are
different observation paths; these results do not qualify raw-track recording
as a universal playout oracle. HTMLMediaElement.captureStream also affects its
source descriptor during later track changes, hence the isolated final-phase
rendered measurements. No production browser stream replacement or timestamp
rebase was introduced, and no numerical synchronization bound was relaxed.

Receiver-feedback adaptation, multi-guest allocation,
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
