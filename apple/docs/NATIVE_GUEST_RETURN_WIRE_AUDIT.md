# Guest return wire and receive-clock audit, 2026-10-22

Baseline 44c078e. No production sender, SDP, packet, mixer, sink or transport
behavior changes follow from this audit. #127 remains open, including the
original failed browser PCM and 105.104 ms raw-return synchronization results.

## What the native source contract establishes

The host offers sendrecv Opus payload 111 at 48 kHz, two channels, stereo/sprop-stereo
parameters and the return SSRC on the audio m-line. Its own media source
identities are distinct from guest camera/screen/audio SSRCs. Accepted browser
answers must retain the qualified payload/clock/direction and source bounds.
The libdatachannel0.24.0 audio-description helper expands Opus to 48 kHz/two channels.

The shipping encoder emits raw <=1275-byte 20 ms Opus payloads with original mixer
PTS and declared priming. The native sender builds RTPv2, PT111, a marker on the
first packet, an incrementing 16-bit sequence, the same offered SSRC and the
original 48 kHz RTP timestamp. It does not add a MID extension; the known offered
SSRC identifies the bundled audio source. The actual failed Chrome receipt
already associated 931 packets with audio/opus, so absence of a MID extension is
not demonstrated as the failure.

The first packet and every 25th subsequent packet also send a 52-byte compound
RTCP SR/SDES: 28-byte sender report plus 24-byte single CNAME chunk. Its packet
lengths, SSRCs and padding are internally consistent. The report extrapolates the
same media RTP/NTP mapping to the report sending instant; it does not rewrite
media timestamps. Retained encoded packets all advanced 960 ticks. Packetization
and SRTP send paths are shared between shipping UDP and optional NICE/TLS;
reviewed optional transport changes do not replace the audio codec/packet builder.

This is a source-contract assessment, not captured-wire validation. Original
TLS temporary SDP/RTP/session directories were removed by design. Retained
Opus packets were decoded in memory, but neither full RTP/RTCP bytes nor SDP were
exported. No claim is made that new local packets are the old933network sends.

## Different clocks in exact Chrome 155.0.8059.85

The pinned browser source shows that the WebAudio MediaStream source drains a
FIFO supplied by the remote track's asynchronous OnData callback. Running a
null WebAudio destination does not itself invoke WebRTC's receive decoder.
[WebAudio sink](https://chromium.googlesource.com/chromium/src/+/155.0.8059.85/third_party/blink/renderer/modules/mediastream/webaudio_media_stream_audio_sink.cc),
[remote audio source](https://chromium.googlesource.com/chromium/src/+/155.0.8059.85/third_party/blink/renderer/platform/webrtc/peer_connection_remote_audio_source.cc).

A separate platform WebRtcAudioRenderer callback calls WebRtcAudioDeviceImpl's
RenderData and then PullRenderData. When that renderer is initialized, it
creates a platform output sink; its source callback keeps pulling even in a
paused state. Null WebAudio processing alone does not guarantee that this
separate callback exists or runs. WebRTC's pinned ChannelReceive obtains NetEq
audio and updates decoded statistics during GetAudioFrameWithInfo, delivering
track sinks before applying the HTML mix volume.
[Renderer](https://chromium.googlesource.com/chromium/src/+/155.0.8059.85/third_party/blink/renderer/modules/webrtc/webrtc_audio_renderer.cc),
[device](https://chromium.googlesource.com/chromium/src/+/155.0.8059.85/third_party/blink/renderer/modules/webrtc/webrtc_audio_device_impl.cc),
[Chromium DEPS](https://chromium.googlesource.com/chromium/src/+/155.0.8059.85/DEPS),
[pinned WebRTC receive](https://webrtc.googlesource.com/src/+/5bd86a2f17a35dfc986b87d058f511e45805bd1d/audio/channel_receive.cc).

This supports a specific hypothesis for the retained 931 RTP/zero jitter-buffer
emission/zero PCM result: the WebAudio worklet may tick while the separate
WebRTC renderer never advances the receive decoder. It is not yet a measured
cause and does not prove that no wire/decoder issue exists.

## One bounded all-Chrome discriminator

`owned-null-audio-loopback.mjs` uses actual generated stereo oscillators, two
verified 48 kHz null AudioContexts, a real same-browser Opus peer pair and the same
muted-HTML/direct-track/Worklet/zero-gain/null-destination consumer. It installs
no dependency or device and changes no OS/trust/permissions/defaults. Its
measurement is 12 seconds, every CDP deadline 10 seconds, with finite initialization
and no-progress limits. Public tracing is bounded to 8 MiB/25,000 events.

The single authorized attempt verified both real null contexts as running,
then stopped at RTC negotiation with exit 77/UNQUALIFIED before connection or
measurement. Thus it has neither a same-symptom nor a positive-decoder outcome.
The original attempt source hash and exact failed receipt are retained in the
machine report. The separately authorized fake-output-clock attempt below adds
subphase and bounded failure-trace receipts. Additional ICE error/state/count
observers added afterward were syntax checked only, without another attempt.
No unchanged browser retry was made.

## Cross-implementation payload control

The optional validation compile condition STREAM_GUEST_RFC_OPUS_VALIDATION
adds only an observation to the existing owned sender diagnostic. It consumes
the exact payload Data/PTS/RTP emitted by the shipping encoder and decodes it
with an explicitly supplied existing libopus through its public API. It does not
encode an alternative payload, send packets, or create a playback/capture device.
The original Apple decoder remains a separate-instance control, not a different
codec implementation. Raw payloads are not exported.

```sh
STREAM_GUEST_RFC_OPUS_LIBRARY=/absolute/existing/libopus.dylib \
  zsh apple/scripts/run_guest_return_sender_diagnostics.zsh
```

The final current-source run decoded 109 payloads/104640 stereo frames using actual
libopus 1.6.1. Every packet is 960 samples/two channels and retains 960-step source
PTS/RTP framing. Source tones were 0.399981/0.199994; reference decode tones
0.384166/0.189548 and RMS 0.277224/0.136918. Wrong-channel and absent 440/880 Hz
controls stay below 0.005; a malformed TOC is rejected. Separate Apple decoding
agrees to numerical precision. The default compile/run without the optional
condition also passes. Both units report zero successful network sends.

The exact existing library path/hash/version, source packet aggregate hash,
source hashes and frozen receipts are in
[NATIVE_GUEST_RETURN_WIRE_AUDIT_2026-10-22.json](NATIVE_GUEST_RETURN_WIRE_AUDIT_2026-10-22.json).
This rules out a proprietary/silent payload format for this current generated
encoder path. It does not establish what reached the old browser's decoder or
qualify normal output, acoustic/browser AEC, Internet/TLS media or A/V timing.

## Source-only candidate for a future reviewed probe

In this exact browser, the existing --disable-audio-output test switch is
forwarded to the audio utility process. It selects AUDIO_FAKE in the output
proxy, then the built-in FakeAudioOutputStream. That stream starts a real
FakeAudioWorker timer and calls the ordinary output callback, so this path can
drive a consumption clock rather than simply suppressing all callbacks.
[Utility forwarding](https://chromium.googlesource.com/chromium/src/+/155.0.8059.85/content/browser/service_host/utility_process_host.cc),
[output selection](https://chromium.googlesource.com/chromium/src/+/155.0.8059.85/media/audio/audio_manager_base.cc),
[fake output](https://chromium.googlesource.com/chromium/src/+/155.0.8059.85/media/audio/fake_audio_output_stream.cc),
[worker clock](https://chromium.googlesource.com/chromium/src/+/155.0.8059.85/media/base/fake_audio_worker.cc).

It is not the complete FakeAudioManager: macOS still constructs AudioManagerMac
and may query default-device metadata before fake-stream selection. It does not
promise successful initialization on this host. The camera/microphone fake-device
flag alone does not establish output substitution. The one revised authorized attempt verified this flag on both owned browser
and audio-utility argv. It completed actual offer/answer and remote-track
HTML/WebAudio attachment, then failed connection-wait before RTP or the 12 s
measurement. It remains exit 77/UNQUALIFIED. Trace captured 6883 WebAudio input
callbacks but zero WebRTC RenderData/PullRenderData/remote OnData events;
the sender worklet had actual 0.4/0.2 PCM and the receiver zeros. Without a
connected/RTP positive control this is not the original 931-packet symptom and
does not prove a clock cause. No additional attempt was made. Any future
reviewed result would isolate only an explicit fake-output-clock decoder route,
never normal/speaker playback or AEC.

## Failure observation before receiver cleanup

The two retained exit77 receipts cannot explain why connection failed: the first
has only its coarse negotiation phase; the second has no peer/ICE/candidate or
RTP statistics at the failed connection boundary. Neither establishes the
original connected 931-packet/zero-decoder-emission symptom.

The diagnostic now snapshots a fixed allowlist before its page's cleanup:
phase, peer/ICE/signaling states, candidate counts (not candidate strings),
bounded ICE error names/codes, null-context/player/track state, existing spectral
PCM summaries, and available audio RTP/playout/selected-transport counters.
It includes no SDP, IPs, credentials, track/peer IDs, raw PCM or packets. Each
peer's statistics explicitly reports available, unavailable or timeout. Collection
has a shared 500 ms failure-only budget; a late result cannot rewrite the frozen
receipt. A nonresponsive page produces an explicit unavailable snapshot through
the watchdog's bounded 700 ms failure-only read, before owned-browser retirement.

API-phase deadlines use the remaining original 16-second no-progress and
60-second total budgets. Additional subphase labels do not reset that budget.
The original 10-second connection wait, 12-second measurement, null/muted
requirements, positive PCM/RTP gates and exit77 refusal remain unchanged.
Observing a failure never changes it into diagnostic completion.

`owned-loopback-failure-snapshot-client.mjs` tests the exact serialized helper's
redaction, fixed bounds, refused/stalled statistics and immutable late-result
handling. It also executes the actual diagnostic page in an owned Node VM with
API doubles to check that its snapshot precedes peer/track/context cleanup.
Those checks exercise diagnostic code only; they do not establish a browser
connection, decoder clock, playout or issue127 acceptance. A new browser attempt
requires a separately scheduled owned null-output run; the old receipts remain
unchanged.
