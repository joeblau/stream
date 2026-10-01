# Optional WebM decoder research — G10 #166

Decision: use libvpx for an optional, separate process VP8/VP9 video adapter.
Keep the existing AVFoundation native media path and shipping dependencies
unchanged. This prototype is a CLI process; it is not a shipping XPC service.
AV1 and WebM audio are outside the proposed video adapter's initial scope.

Run `zsh scripts/run_g10_decoder_harness.zsh` on a Mac with FFmpeg and libvpx
already installed. `VPX_PREFIX` selects the library/header installation;
`G10_DIR` selects output. It generates deterministic two-second clips with
animated color and transparent, half-transparent and opaque regions, compiles
the real StreamCore parser and C decoder bridge, probes AVFoundation, saves
PNG frames, and compares alpha bytes to FFmpeg. No decoder is linked into
StreamMac. An existing HEVC-alpha MOV may be added to the fixtures folder.

## Measured results (2026-10-01)

Environment: Apple Silicon, macOS 27.0 (26A428), Xcode 27.2 beta, libvpx 1.15.2,
restricted Codex process. Each tested VP8/VP9 file contained 60 frames at
128×96, with nanosecond presentation times from 0 to 1,967,000,000.

| Fixture | Optional decoder | Native AVFoundation |
| --- | --- | --- |
| VP8 alpha WebM | 60 frames; alpha 0–255; seek matches sequential decode | Container rejected (-11828) |
| VP9 alpha WebM | 60 frames; alpha 0–255; seek matches sequential decode | Container rejected (-11828) |
| VP9 opaque WebM | 60 frames; alpha 255 | Container rejected (-11828) |
| VP9 + Opus WebM | Video decoded; audio deliberately not decoded | Container rejected (-11828) |
| AV1 WebM | Explicitly unsupported by this adapter | Container rejected (-11828) |
| H.264 MP4 | Native path retained | Control decode failed (-11821 / -12911) |
| ProRes 4444 alpha MOV | Native path retained | Control decode failed (-11821 / -12911) |
| HEVC alpha MOV | Native path retained | Control decode failed (-11833 / -12906) |

Both alpha streams matched FFmpeg's libvpx-decoded frame 30 exactly:
12,288 bytes per mask, maximum absolute error zero. Color and alpha have
separate persistent libvpx contexts; alpha comes from BlockAdditional ID 1's
luma plane. RGBA output is premultiplied. Seek recreates both contexts,
finds the preceding keyframe, prerolls, and compares the target frame's full
RGBA hash with sequential decode. Timestamps come from signed block offsets
plus cluster time and checked nanosecond scaling, not a guessed frame rate.

H.264 and ProRes control files also fail decode in this sandbox; those local
results do not establish that the formats are unsupported. The hosted
measurements below resolve that ambiguity for the two tested configurations.
The local HEVC fixture name alone does not prove alpha survived encoding;
HEVC alpha remains unqualified by this research matrix.

The Native Media Research workflow repeats the complete prototype on hosted
macOS 15 and 26 runners. `G10_REQUIRE_NATIVE_CONTROLS=1` makes the run fail
unless H.264 and ProRes decode all 60 frames and 64ARGB ProRes retains
transparent, translucent and opaque alpha across 0–255;
an unavailable codec service can no longer produce a green qualification
check. The harness writes `native-probes.json`, elapsed decode/seek results,
fixtures and reference masks for review. The workflow does not install or
link a decoder into the product. macOS 14 still requires a separate run with
a compatible Swift 6 toolchain; the hosted matrix is not minimum-OS evidence.

An initial hosted BGRA probe decoded ProRes with alpha 0–254 rather than
0–255. That is not a missing alpha channel. The harness measures both the
8-bit RGB route and Apple's recommended 64ARGB ProRes-alpha route, keeping
their results separate. [Apple's reader output guidance](https://developer.apple.com/documentation/avfoundation/avassetreadertrackoutput)
recommends alpha-bearing high-bit-depth formats to preserve ProRes alpha.

## Hosted native measurements (2026-10-01)

Both [macOS 15.7.9 (24G830)](https://github.com/joeblau/stream/actions/runs/36942618228/job/110637384726)
and [macOS 26.6.2 (25G83)](https://github.com/joeblau/stream/actions/runs/36942618228/job/110637385029)
passed on arm64 with libvpx 1.17.0 and FFmpeg 9.0.1. H.264 decoded all
60 frames as opaque BGRA. ProRes 4444 decoded all 60 frames with transparent,
translucent and opaque alpha: 0–254 in BGRA and 0–255 in 64ARGB. Both outputs
completed without reader errors. AVFoundation rejected each tested WebM
container with -11828, including VP8/VP9 alpha, opaque VP9/Opus and AV1.

The optional adapter decoded every VP8/VP9 fixture, retained timestamps,
and reproduced frame 37 after keyframe-30 preroll. VP8/VP9 alpha masks both
matched FFmpeg exactly. Decode, output hashing/snapshot and seek validation
for each two-second 128×96 clip took 0.34–0.43 seconds on macOS 15 and
0.24–0.30 seconds on macOS 26. These tiny fixtures establish correctness,
not a 1080p/4K throughput claim. Per-run artifacts include the fixtures,
native JSON report, decoded masks and logs.

The bounded research acceptance is satisfied on these documented systems.
Minimum-OS, Intel, real production-size workload, signed helper and complete
shipping qualification remain in [R03 #92](https://github.com/joeblau/stream/issues/92)
and [R05 #94](https://github.com/joeblau/stream/issues/94). No native support
claim is extended to untested codecs or configurations.

## Bounds and limitations

The parser rejects files over 512 MiB, enforces a shared one-million-element
budget across nested readers, checks child elements against parent bounds,
and rejects integer/timestamp overflow and lacing. Payloads are ranges into
one retained input file. The decoder uses one worker per color/alpha context,
limits compressed packets to 16 MiB and accepts at most 4096×4096 output.
One reusable RGBA buffer is 49,152 bytes for the measured fixture, at most
64 MiB at the configured maximum; decoded codec reference buffers are also
retained by libvpx. The file/index and codec buffers mean this is bounded,
not a streaming or zero-copy production demuxer. Production must impose an
OS-enforced helper resource budget and use mapped input/incremental indexing.

Only eight-bit I420 BT.601/BT.709 color is converted. HDR, high-bit-depth,
resolution changes, encrypted tracks, AV1, laced audio and audio playout
require separate decisions. Unknown-size clusters that encompass subsequent
clusters are not a supported live-container case. This is a local animation
file prototype, not an incoming live WebM receiver.

## Packaging route

Package a pinned universal libvpx build with its BSD license/notice files in
an optional signed helper bundle. Build and validate arm64 and x86_64 slices;
do not depend on Homebrew paths in a distributed app. Sign the helper and
its library with the application, notarize the complete package, and provide
bookmark/file-descriptor access only to the selected asset. An XPC boundary
must contain decoder failure, enforce cancellation and memory limits, and
return timestamped premultiplied pixel buffers through the existing media
frame source contract. Native media must work when this helper is absent,
disabled or fails to start. Browser widgets and the main renderer must never
acquire a mandatory libvpx dependency.

## Primary references

- [WebM container rules](https://www.webmproject.org/docs/container/)
- [WebM alpha design](https://sites.google.com/a/webmproject.org/wiki/alpha-channel)
- [libvpx SDK and tools](https://www.webmproject.org/code/)
- [Apple AVAssetReader](https://developer.apple.com/documentation/avfoundation/avassetreader)

G10's prototype and optional packaging decision are supported by the hosted
measurements above. A production helper remains follow-up implementation;
native playback retains its existing dependency path.
