# Cadenced Program video admission

A Program compositor already emits its declared source cadence with original
host timestamps. Ordinary timer jitter must not become an implicit second
frame-rate reduction. The former normal publisher configured HaishinKit's
minimum-gap filter at `1/fps - 1ms`; a short30fps interval could therefore drop
an otherwise valid frame. The shared encoder independently applied its phase
filter even when source and destination were both30fps, with a100µs threshold.
Neither rejection appeared as queue/congestion loss.

A bounded actual regression reproduced both defects before correction. Sixty
monotonic source frames with±1.2ms clock jitter produced31 actual decoded RTMP
frames through the normal publisher. The shared H.264 encoder produced31
compressed and31 decoded frames from60 source frames with±600µs jitter.
The failed 2×60s ISO workload likewise had Program30fps without missed deadlines,
but normal RTMP3143 frames/123.9s and failed its unchanged>3400frame gate.

Desktop destinations now explicitly declare their compositor source cadence
through `Publisher.configureProgramVideo(sourceFrameRate:)`, before startup.
Only this declared Program path disables the SDK's second minimum-gap filter.
The adaptive controller preserves original sample PTS and phase-samples only a
profile, congestion or thermal target that is slower than the source. Intentional
sampling records pacing drops; queue-pressure admission remains separate. The
same-rate shared encoder likewise avoids downsampling an already paced source,
while preserving its existing slower/non-divisor phase accumulator. Raw capture
and iOS omit the new contract and retain their existing SDK filtering, without
an extra per-frame adaptive actor hop. Bitrate policy, source audio timestamps,
AAC alignment, mailbox bounds, encoder EOS and independent stop behavior are
unchanged by this correction.

## Reproduction

Use the isolated runner's owned vendor/cache and the shared host build-slot
wrapper. The small modes build the shipping controllers/publishers/encoders and
actual MP4 consumers; no capture device, TCC or system route is opened.

```sh
ISO_ENCODER_CADENCE_ONLY=1 scripts/run_isolated_sustained_harness.zsh
ISO_ENCODER_CADENCE_ONLY=1 ISO_CADENCE_SOFTWARE=1 scripts/run_isolated_sustained_harness.zsh
ISO_RAW_CADENCE_ONLY=1 scripts/run_isolated_sustained_harness.zsh
```

`STREAM_VENDOR_ROOT` selects an owned dependency tree. Setting
`ISO_CADENCE_BASELINE=1` compiles the encoder/transport files from ancestor
`d413aa1` with the current fixture and protocol's default no-op Program hook,
reproducing the original cadence failures without changing source PTS.

The shared mode validates actual hardware and software H.264 samples, MP4 bytes,
decoded pixels/counts, exact original48kHz timestamp membership and decoded PTS
within100µs. The fixed results are:

| Source → target | Inputs | Encoded | Decoded, hardware/software |
| --- | ---: | ---: | ---: |
|30→30|60|60|60/60|
|30→15|60|30|30/30|
|60→24|120|48|48/48|

The raw mode uses real shipping RTMP/SRT adapters and actual localhost FFmpeg
listeners. Each sends60 source frames with±1.2ms PTS jitter. A lower-profile case
and a live `setThermalCeiling(... frameRateCap:15)` case both retain the real cap.
All encoder/output resources reach zero after stopping. Independent FFprobe
packet counts are60RTMP30,30RTMP15profile,30RTMPthermal15 and60SRT30.
The native AVAssetReader decodes61/30/30/59pixels respectively: RTMP's leading
empty edit can materialize a zero-time pixel, and the consumer can omit a
terminal boundary frame. The fixture uses the actual video-track time range to
exclude the empty edit and keeps a one-frame decoder boundary bound. It compares
each same-rate real decoded PTS to the original jittered source sequence within
1.1ms (RTMP millisecond wire quantization), and every slower-rate PTS to an
original source receipt. No uniform replacement time grid is manufactured.

## Retained native receipts

Host: Apple M3 Max, Mac15,8,16 logical CPUs; macOS27.2(26B118),
Xcode27.2(27B5038j). These are bounded software/codec/localhost transport
regressions, not an additional physical-device qualification.

- Original raw failure: `/tmp/stream-wave3-isolated-raw-cadence-baseline-decoder-20261022.log`.
- Original shared failure: `/tmp/stream-wave3-isolated-cadence-baseline-exact-20261022.log`.
- Fixed hardware shared: `/tmp/stream-wave3-isolated-cadence-fixed-20261022.log`.
- Fixed software shared: `/tmp/stream-wave3-isolated-cadence-software-fixed-20261022.log`.
- Fixed raw source-grid proof: `/tmp/stream-wave3-isolated-raw-cadence-grid-final-20261022.log`,
  artifact `media-30010e59-a9b1-4351-90d0-192a40f3a4c6` in the owned isolated build folder.

Early probe-development failures are also retained: an AVAssetReader asset
identity mistake, MP4 default600Hz time scale, a decoder helper's incompatible
1080p size assertion, and SRT caller latency expressed in listener microseconds
instead of the adapter's milliseconds. These were fixture defects corrected
before their respective media verdict; none supplied a passing acceptance claim.
The unchanged full sustained ISO/network workload remains a separate gate.
