# Native recovery fixture readiness

The October 21, 2026 follow-up starts from committed completion tip `703e8b9`.
On Mac15,8 / M3 Max, macOS 27.2 (26B118), Xcode 27.2 (27B5038j), the unchanged
tip passed actual abrupt-process recovery, both hardware-preference and forced
software RTMP-loss recovery, and native source-failover pixels/PCM. Historical
red checks on older draft branches therefore do not establish a current
shipping failure. Their remaining fixture assumptions still needed correction.

## Durable readiness before the owned kill

The abrupt child's live writer progress can lead the periodically written
recording sidecar. Its Ready signal now requires the actual flushed recovery
document to retain the expected recording session/file, active/verified status,
duration above six seconds and timed marker. It waits for those facts within
the existing readiness deadline. The parent's original restart assertions,
18-second child readiness bound, original-file/journal hashes, exact paused
player checks and decoded flash/tone bounds remain unchanged.

The corrected actual run kills only its explicitly spawned recorder child,
then opens a fresh shipping Workspace. The real AVPlayer restores to 1.25
seconds with rate zero and mute held despite autoplay. The real Recording
Library identifies the interrupted file as recoverable and exports a playable
copy. Both original and copy decode 360 H.264 frames over six seconds, with
flash at 0.5 seconds and tone at 0.499916667 seconds (0.0833 ms apart).
Original media and journal hashes remain unchanged. No capture, provider
mutation, writer finish callback or automatic output restart occurs.

## A continuous source clock for gain checks

The nine pending-gain cases now schedule their owned 10 ms PCM buffers against
one monotonic deadline sequence and one original host sample clock. Repeated
relative sleeps plus a new timestamp from each arrival had inserted synthetic
gaps under runner load, mixing scheduler starvation into a gain measurement.
Production mixer code and every RMS/silence/count bound are unchanged.

The corrected full source fixture passes all nine PCM cases and the live and
decoded fallback phases, including an independently advancing healthy source,
blank/offline/freeze, healthy/missing standby, scene fallback, explicit restore,
silent private slate, injected sleep finalization, preview-only wake and runtime
retirement. Capture gain 0.4 measures RMS 0.0848543 on the first arrival and
0.0848486 after ring reset, close to the fixture's expected
`0.3 / sqrt(2) * 0.4`. Removed/unknown/muted bindings remain exactly silent;
media gain 0.25 measures 0.0530339. The recorded Program decodes 321 frames over
10.83377 seconds.

## Actual independent endpoint loss

Both unchanged-tip transport modes interrupt only the owned RTMP receiver,
observe actual reconnecting/backoff, then recover to a replacement receiver.
The SRT publisher, original acknowledgment and shared encoder remain intact.
Each surviving SRT recording decodes 392 continuous frames with unchanged
11.48-second early/late source-cue spacing and final PTS 15.6399889 seconds.
Both RTMP segments decode, both outputs acknowledge Stop, and the original
strict cadence, source-tail, synchronization and deadline assertions pass.

## Historical failures and limits

- Draft #209's ARM job at `5c9fc43` failed the durable segment/status/marker
  assertion; its Intel job and generic ARM/Intel/iOS checks passed. The new
  Ready gate addresses the ordering assumption without dropping that assertion.
- Draft #210's Intel transport job at `8380455` timed out before publishers,
  waiting for actual receiver sockets. The current exact-tip hardware/software
  paths pass with the selected RTMP/SRT-capable receiver; this is local Apple
  Silicon evidence, not a new hosted Intel pass.
- Draft #213's ARM and Intel gain cases at `69d2292` failed the original RMS
  floor with discontinuous arrival-based test timestamps. The continuous-clock
  feeder preserves the original floor and routing assertions.
- The unrelated historical ChannelFX Intel frequency-response measurement
  included cold graph startup in a claimed steady-state RMS. Its focused test
  correction is described in the subsequent ChannelFX validation notes.

These tests qualify owned local failures and controlled source/lifecycle
callbacks. They do not establish real provider ingest, Internet route changes,
physical display/device removal, TCC revocation, OS sleep/lock delivery, power
loss, arbitrary damaged-media repair or sustained reconnect resource behavior.
The upstream SDK still emits a close-continuation warning in the exercised
reconnect despite completing its reconnect/Stop receipts.

Reproduce with the existing runners, using an owned clean `STREAM_VENDOR_ROOT`
and independent derived-data paths:

```sh
zsh apple/scripts/run_abrupt_session_recovery_harness.zsh
zsh apple/scripts/run_source_failover_native_harness.zsh
zsh apple/scripts/run_shared_encoder_harness.zsh --transport-recovery-only
zsh apple/scripts/run_shared_encoder_harness.zsh --transport-recovery-only --software
```

## ChannelFX steady-state measurement

The frequency-response helper now measures the final second of the complete
two-second rendered tone and requires all 96,000 mono samples to be present.
This excludes initial graph/filter/dynamics settling from a measurement intended
to describe steady-state response. The original low-band acceptance interval
of 2.49–3.51 dB remains intact; production DSP, preset parameters and processing
order are unchanged.

Both native arm64 and an x86_64 executable under Rosetta pass all fifteen
`ChannelFXProcessorTests`, including low/mid/high response, gate, limiter,
silence, format/timing, live edits, legacy mapping and decoding. Standalone
probes compiled from the shipping processor/model/hosted-unit sources measured
the same settled 100 Hz / 2.5 kHz response of 3.1393379 dB on both architectures.
The same-frequency shelf contribution is 2.9237541 dB, consistent with the
configured 3 dB low shelf and its finite transition at 100 Hz. This supplies a
transfer-response check without expanding the old bound to the historical
3.9271 dB whole-buffer result.

The focused package builds the actual StreamCore sources and exact test file.
The native suite runs through SwiftPM. The installed SwiftPM test helper is
arm64-only, so the successfully built x86_64 Core library and exact test file
are linked into a small x86_64 executable calling Swift Testing's standard
`__swiftPMEntryPoint`, then run through Rosetta. This is translated x86_64
evidence on the named M3 Max, not a hosted or physical Intel qualification.
