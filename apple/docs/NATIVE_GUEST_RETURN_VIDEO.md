# Native guest selectable video return

The native interview receiver can send one explicitly enabled Program, Secondary canvas or Clean video return to the current admitted guest. Source selection
and Start/Stop Video Return use the
shared command dispatcher and the complete slot/peer/negotiation/generation
lease. Changing the source stops video and requires a new Start. Joining or
rejoining resets the selection to Program and does not enable video. Public stereo mix-minus
return continues independently.

Every fresh opt-in starts constrained Baseline H264 at most 320×180,
15 fps and 250 kbps. The encoder scales down without upscaling or duplicating
source frames. Authenticated receiver feedback can constrain the current target;
the UI displays its current resolution, cadence and bitrate ceiling. Qualified
hardware permits policy ceilings of 640×360/24 fps/650 kbps and 1280×720/30 fps/1.5 Mbps.
Other Mac classes remain capped at the low profile. It reserves one
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
| Measured capacity | Actual negotiated single-source REMB/RR; Chrome received 73,196 bps and SDK-accepted RTP payload plus headers 75,591 bps remain below fresh 119,451 bps REMB; learned bucket survives same-lease Off/On |
| Static application-limited estimate | Actual Clean remains ready through a late white update at 6,400 bps REMB/4,000 bps codec target; fresh remote decoded frame and strict A/V bounds |
| Persistent video-only failure | Controlled actual SDK sends fail for 2 seconds; optional video hides and releases its VT reservation, real decoded stereo public audio continues, restored source cannot replay Start |
| Held VT teardown | Real submitted VT frame held; Off returns under 100 ms, late send rejected; reservation remains until actual VT invalidation |
| Installation races | Held Program installation→Secondary replacement and held-before-Secondary-install→Program replacement preserve only the new token/capability/reservation |
| Privacy snapshot race | Actual Program, Secondary and Clean Composer old red snapshots receive post-cutoff PTS and are rejected; fresh actor-installed subscriptions admit black slate |
| Clean raster semantics | Same-PTS actual Program shows green project overlay/red annotation; Clean retains blue scene layer/purple project default background, omits both; zero remaining subscriptions |
| Late Secondary geometry | Canceled landscape installation cannot alter a newer portrait subscription's actual pixels/geometry or attach its old tap |
| Pre-BEGIN Host cancellation | Actual Host claims source intent before scheduling; no-yield Start→privacy stop→restore cannot replay; explicit replacement Start survives held old installation; outstanding jobs bounded at two |
| Control close | Immediate audio/video authority revoke and eventual return reservation removal |
| Packetization | ASan/UBSan checks exact FU-A reconstruction,1188/1189-byte boundaries, 64 KiB/64-NAL caps, RTP marker/SSRC/original PTS, sequence wrap and partial-send sequence consumption |
| Earlier raw-track A/V recordings | Two fresh recordings per source: Program 67.94/76.19 ms, Secondary 37.06/64.58 ms, Clean 84.73/13.63 ms passed the unchanged 100 ms check in that frozen run. A subsequent exact integrated Program run failed at 105.104 ms; this observation path is not qualified to the 100 ms bound. These are raw-track consumer recordings, not element-rendered captures. |

The generated PCM uses the retained primary-microphone channel identity while
the fixture refuses physical capture and disables VoicePolish. An earlier
unreferenced synthetic media channel was correctly pruned on Take, discarding
its authored future PCM and confounding the A/V cue. Keeping the generated
source within the controller's real demand model fixes the fixture; no
production audio clock, deadline or assertion was relaxed. Independent native
Opus leading-silence/onset checks locate the decoded cue within 21 microseconds
and the NTP/source-PTS round trip within 0.24 microseconds.

The earlier runner separated the complete source-control/lease/budget lifecycle
from six fresh final-phase recordings (two per source) and one independent
persistent video-delivery failure phase. Each recording checked 50 ms native
source alignment and a 100 ms decoded recording bound, then retired its full
lease. Its `HTMLMediaElement.captureStream()` call was initially described as
rendered capture. The exact Chrome 155 implementation instead clones the
element's source tracks when `srcObject` is a MediaStream, bypassing the audio
and video element capturers. This records an additional raw-track consumer;
it does not establish the element's final audio/video presentation timing.
See the [exact Chromium implementation](https://chromium.googlesource.com/chromium/src/+/155.0.8059.85/third_party/blink/renderer/modules/mediacapturefromelement/html_media_element_capture.cc).

An earlier raw-track MediaRecorder path measured a 117.44 ms Secondary cue
difference after controlled partial-FU-A loss while the independently measured
video-element/worklet cue was 2.58 ms and the native cue was 13.40 ms. The owned
raw artifact `decoded-return-1792611734235.webm` and log
`stream-macos-native-return-video-clean-raster-gate-final-20261021.log` retain
that failure. Raw-track re-encoding and synchronized element rendering are
different observation paths; these results do not qualify raw-track recording
as a universal playout oracle. HTMLMediaElement.captureStream also affects its
source descriptor during later track changes, hence isolated final-phase
measurements. This isolation alone does not turn it into rendered capture.

The final integrated repeat retained a second raw-track failure:
`decoded-return-1792616136258.webm`, log
`stream-macos-final-combined-video-20261021.log`. The flash was at 1.228 s and
the tone at 1.333104 s, a 105.104 ms difference against the unchanged 100 ms
bound. Contiguous decoded PCM still differs by 103.104 ms, so the failure is
not merely a per-packet timestamp calculation error. Its native source cue
difference was 11.48 ms. The separate video-element requestVideoFrameCallback
and raw remote-track AudioWorklet consumers differed by 90.527 ms; they are
also distinct consumption paths, and do not measure normal element audio
hardware output. An unchanged observational repeat passed at 35.40 ms raw-track
and 27.13 ms independent-consumer difference; this demonstrates variance, not a
fix or qualification closure. No production timing change, packet timestamp
rebase or relaxed numerical bound follows from these observations.

### Normal element-output observation remains unqualified

A fixture-only alternative tried a video-frame-callback canvas plus
`AudioContext.createMediaElementSource(element)` through one passthrough
AudioWorklet. Local H264/AAC file controls with authored zero and ±150 ms
offsets passed the aligned 100 ms check and rejected both 150 ms offsets with
the correct sign. The same graph on the actual WebRTC return produced silence:
the independent remote-track control had 100,352 nonzero PCM frames and peak
0.4202, while the element-source node had 100,352 zero frames and no cue.
The file control cannot qualify this live graph. In exact Chrome 155,
[`WebMediaPlayerMS`](https://chromium.googlesource.com/chromium/src/+/155.0.8059.85/third_party/blink/public/web/modules/mediastream/web_media_player_ms.h)
does not override the base
[`GetAudioSourceProvider()`](https://chromium.googlesource.com/chromium/src/+/155.0.8059.85/third_party/blink/public/platform/web_media_player.h),
which returns null. Thus this public element tap cannot observe the normal
remote audio renderer. It is retained as an explicitly unqualified probe,
not substituted for a passed return test.

A second bounded probe used existing Screen Recording access and an audio-only
ScreenCaptureKit filter containing only the exact newly owned Chrome PID.
It registered no screen output and used only owned local video/tone content.
Headless, normal minimized direct-executable and a new LaunchServices instance
(`activates=false`, private profile, exact returned PID) all returned zero PCM
even for a known-positive 1000 Hz file. The LaunchServices run retained 118,911
measurement frames, zero rejected packets, 71 video callbacks and no audio cue.
A zero signal in the unrelated-tone control consequently proves no exclusion:
the required selected-Chrome positive control failed. This OS-output observation
path remains unqualified; it supplies no normal-element or physical-output A/V
result. The original 105.104 ms raw-track failure remains unresolved by it.

`workers/interviews/test/browser/chrome-output-oracle-calibration.mjs` retains
the optional controlled experiment. It requires an explicitly supplied owned
observer executable and native tone helper, validates zero/±150 ms authored
sources before capture, and refuses missing positive PCM. It never changes a
permission, selects another process or falls back to system mix. This probe is
separate from the shipping native source/clock/privacy and decode evidence.

## Measured receiver feedback and remaining adaptation gates

The native SDK observes authenticated RTCP SR/RR report blocks for the current
outbound video SSRC, and negotiated single-source goog-remb messages addressed
to that SSRC. The entire bounded compound packet is validated before publishing
observations. Old extended sequences, other sources, aggregate multi-source
REMB, unnegotiated estimates, retired peers and old generations cannot supply
capacity. RR fields follow [RFC3550§6.4.1/6.4.2](https://www.rfc-editor.org/rfc/rfc3550.html#section-6.4.1).
The deployed goog-remb format is an [expired experimental draft](https://datatracker.ietf.org/doc/html/draft-alvestrand-rmcat-remb-03#section-2.2),
not an RFC standard. Queue bytes come from the actual outbound SDK track.

The sender samples at 500 ms intervals and requires new reports after each
explicit opt-in. Reports older than 2 seconds or missing capacity reset the
resolution policy to low. A previously learned tighter bitrate restriction
survives a feedback gap. Fresh scoped REMB limits the actual VT target to a
quantized ceiling, down to the codec's 4 kbps target floor. A separate whole-AU
admission bucket charges the exact projected RTP payload plus 12 byte headers
from the actual packetizer, at 80% of fresh REMB with a maximum 2 second/16 KiB
burst. Repeated reports and same-lease Off/On do not refill it, and rejected or
failed AUs cannot borrow unbounded debt. Static low-entropy pictures remain
useful even when an application-limited receiver estimate is only 6–10 kbps.
If no complete fresh frame can be delivered for 2 seconds, video stops with a
measured bandwidth message and requires a new deliberate Start. Audio continues
independently. These charges exclude SRTP, UDP/IP, TURN and RTCP overhead;
20% remains as headroom rather than claiming full wire accounting. Received throughput is
never treated as spare capacity. RR loss, actual latest-frame replacement,
SDK send failures and the 16 KiB outbound queue limit provide congestion signals.
Three bad windows lower one policy level; eight good windows spanning at least
3 seconds admit one increase with 1.7 times the next target's capacity and a
2 second dwell. Upward bitrate changes additionally require fresh loss-free RR.
SPS/PPS accompanies every IDR; tiny inter frames omit redundant parameters.
Every lease, profile change or failed AU requests a fresh IDR. Profile
replacement preserves cadence and invalidates the old VT session before allocating another,
while the same shared encoder reservation remains held. Source timestamps and
lease/privacy fences remain unchanged. An oversized high-profile access unit
falls back to the low raster without relaxing the 64 KiB bound.

Actual owned Chrome155 relay reports negotiated goog-remb and current-source
RR. A 24 second probe lowered the real VT target under measured capacity,
retaining 320×180 without invented capacity. The exact static-image regression
also stays active at a fresh 8,400 bps REMB and 4,000 bps codec target, decodes its
late white update, and measures 29.37 ms raw-track recorder / 18.80 ms
independent element-video plus separate audio-worklet consumer cue differences.
Those observations do not qualify element-rendered or hardware-output timing.
Actual partial-FU-A loss and next-IDR decode recovery use the existing bounded
network fault seam. The standalone policy checks additionally exercise RR-loss
and SDK-backpressure downsteps; actual VT high-to-low replacement proves
invalidation, no upscaling and original 90 kHz PTS.

Natural higher-profile upshift, real impairment-driven high-to-low adaptation
and capacity-bootstrap probing remain unqualified. The application-limited
receiver estimate in this owned test cannot authorize the 1.105 Mbps capacity
needed for the next profile. No padding probes or fake estimates were added.
Multi-guest allocation, AEC/physical microphones, Internet/mobile impairment
and signed installation remain separate gates.

## Reproduce

The full owned runner requires Node 24.15, Chrome, ffmpeg/ffprobe, XcodeGen and
the pinned owned TURN server produced by `build_owned_interview_turn.zsh`.
`STREAM_VENDOR_ROOT` can select a clean external vendor checkout.

```sh
apple/scripts/run_native_interview_return_video_harness.zsh
# Independent partial-AU/lifecycle phase:
apple/scripts/run_native_interview_return_video_harness.zsh --video-fault-only
# Focused actual authenticated RR/REMB and receiver-capacity constraints:
apple/scripts/run_native_interview_return_video_harness.zsh --video-fault-only --video-feedback-probe
# Video-only SDK delivery failure; public stereo audio and teardown stay real:
apple/scripts/run_native_interview_return_video_harness.zsh --video-delivery-failure
apple/scripts/run_native_guest_return_feedback_harness.zsh
apple/scripts/run_native_guest_return_video_budget.zsh
apple/scripts/run_native_guest_return_h264_harness.zsh
apple/scripts/run_native_guest_return_video_privacy_harness.zsh
```

The lifecycle subset runner additionally takes `STREAM_GUEST_RTC_INCLUDE`,
`STREAM_GUEST_RTC_LIBRARY` and `STREAM_INTERVIEW_RECEIVER_FRAMEWORKS` from a
qualified native runner build. It compiles the actual sender/sink/mixer/VT
sources with validation-only held-install/held-codec hooks. Those hooks and the
controlled partial-send receipt do not exist in a production build.
