# Offline PCM delivery diagnostics

Hosted CI run [39776430822](https://github.com/joeblau/stream/actions/runs/39776430822)
at source `30f2209199b818cc685a24647a46e5a54263daa3` failed on Intel in
`media_playback_lifecycle_harness.swift:350`: the delayed-pull fixture's accumulated
`malformed` flag was true. The original log does not record which condition failed.
It therefore does not establish an incorrect frame count, duration, or host PTS.

The fixture now records the first failed sample's frame count, native sample rate,
actual and expected duration, PTS, callback entry/check host times, and the
production pull's predecode and ready-for-delivery host times. The generated
fixture adds only the timing observation; the playback implementation and the
existing checks remain unchanged: 1–4096 frames, duration error below 1µs, and PTS
strictly between check time minus 30ms and check time plus 160ms. Delayed-pull
source-frame admission checks also remain unchanged.

One bounded local run of the complete original-production offline lifecycle
fixture passed. That run used actual WAV/AIFF/AAC file decoding and animated-image
decoding, without a device player, HAL, capture source, or network transport.
It did **not** reproduce or explain the hosted Intel failure. There was no repeat
run to obtain a pass. A separate deterministic decode-delay investigation must
remain distinct from the original hosted failure unless matching constituent
values become available.

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
