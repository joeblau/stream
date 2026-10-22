# Offline PCM delivery diagnostics

Hosted CI run [39776430822](https://github.com/joeblau/stream/actions/runs/39776430822)
at source `30f2209199b818cc685a24647a46e5a54263daa3` failed on Intel in
`media_playback_lifecycle_harness.swift:350`: the delayed-pull fixture's accumulated
`malformed` flag was true. The original log does not record which condition failed.
It therefore does not establish an incorrect frame count, duration, or host PTS.

The fixture now records the first failed sample's frame count, native sample rate,
actual and expected duration, PTS, callback entry/check host times, and the
production pull's predecode and ready-for-delivery host times. The generated
fixture adds timing observations at the decode and delivery boundaries. The
existing checks remain unchanged: 1–4096 frames, duration error below 1µs, and PTS
strictly between check time minus 30ms and check time plus 160ms. Delayed-pull
source-frame admission checks also remain unchanged.

One bounded local run of the complete original-production offline lifecycle
fixture passed. That run used actual WAV/AIFF/AAC file decoding and animated-image
decoding, without a device player, HAL, capture source, or network transport.
It did **not** reproduce or explain the hosted Intel failure. There was no repeat
run to obtain a pass.

## Controlled decode-delay defect and fix

A separate, one-shot 40ms sleep immediately after the actual offline file read
exposed a production defect. The unchanged implementation took its admission
clock before decoding, then delivered PCM using that stale clock. The owned
baseline stalled for 43.041ms and failed with a sample PTS 63.463ms behind the
callback check. Its 4096 frames, native 48kHz rate and 85.333333ms duration were
valid; the lower host-PTS bound alone failed. The original hosted Intel log lacks
these constituents, so its precise cause remains **unknown**.

Offline PCM delivery now checks a fresh host clock inside the existing serialized
delivery/retirement gate. It removes expired leading frames through CoreMedia's
sample-range copy and discards a buffer only when all its frames have expired.
The surviving frames retain their original bytes, native format, duration and
source-timeline PTS plus the exact removed-frame offset. No timestamp is rebased
onto the delivery time. The 20ms production admission policy and existing fixture
limits are retained. The AVPlayer/video audio path is unchanged. Invalid or
unrepresentable clock/range inputs are rejected before integer conversion.

The first executed fixed full offline fixture passed, including owned stalls of
45.752ms and 43.362ms. One earlier generated-source assertion failed before
compilation or executable launch; its exact-boundary hook was updated for the new
offline delivery argument. No failing executable was repeatedly run to obtain a
pass.

The default fixture retains its three original delayed-pull cases and adds a
fourth starvation case with the owned decode stall. Actual decoded stereo ramp
PCM also verifies fresh-buffer byte preservation; removing 1440 frames from a
4096-frame buffer preserves all 2656 surviving frames bit-for-bit, exact source
PTS/duration, 48kHz rate, stereo channel grid and native DTS validity. Fully
expired buffers and invalid/overflowing clock cases emit nothing. The existing
source-frame admission, pause/restart, retirement/drain, WAV/AIFF/AAC, zero-trim
and animated-image cases pass in the same executed fixture.

Immutable generated-source/input/log manifests are retained separately:

- Original production, ordinary full fixture PASS:
  `/tmp/stream-wave16-pcm-evidence-20261022/original-baseline/manifest.json`.
- Original production, controlled delay FAIL (exit 133):
  `/tmp/stream-wave16-pcm-evidence-20261022/owned-delay-baseline/manifest.json`.
- Fixed production, controlled delay/full fixture PASS (exit 0):
  `/tmp/stream-wave16-pcm-evidence-20261022/owned-delay-fixed/manifest.json`.

The controlled baseline log SHA256 is
`44acab3cf31ae6d0eea89825fbad37d0cef73c50422aaab47a22aa73fa986d92`;
the fixed log SHA256 is
`69ac171955025a3d4ee83b2b8c8175d9d60aa43e15a9dfd5dc8af0ee1f669b1c`.
Fixed playback source SHA256 is
`35d31c27b51c32519ba7a0649ac62a3836da6b974b11bcbea48cef844dd7c614`.

Retained original evidence:

- Intel job `119822293625`, log SHA256
  `f98f00f574057ce69c9b424c7c11fa155c0b3e531ae039b02314a6239411fa7a`;
  line 9601 is the precondition failure and line 9602 is exit 132.
- Intel artifact `12427461580`, SHA256
  `dae27096efb48997b3e23f456f32f6db2a766d87631bccdf19d69ea9c6ae786b`.
- Unmodified playback source SHA256
  `5d8d52360a6929a55ed181eea0ff95d92a584ce8cbef88e5c413cc7f04cccf3f`.
- Local baseline log SHA256
  `00050d98209e199f73c7e554212e3a0dfb88b25602c67f7831b0341044a95275`;
  exit 0. Generated sources, fixture inputs, and their hashes are preserved in
  `/tmp/stream-wave16-pcm-evidence-20261022/original-baseline/manifest.json`.

The job's full shared Core suite passed separately: 596 tests in 82 suites,
313.463 seconds. That does not turn the failing native fixture into a pass.
