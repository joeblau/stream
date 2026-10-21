# Recording storage failure with live network outputs

Run `apple/scripts/run_recording_storage_network_harness.zsh` to exercise the
shipping studio, compositor, mixer, recorder and adaptive RTMP/SRT publishers
together. The generated tool isolates credentials, preferences and automatic
microphone permission. Generated PCM enters the existing capture inlet with
its original host-clock timestamps. The compositor and mixer keep their own
production clocks; neither source timestamps nor network media are replaced.
The runner requires FFmpeg with both RTMP and SRT, accepts `STREAM_FFMPEG_BIN`,
and bounds the tool and its owned receiver processes to 90 seconds.

The fixture stages an edit to a retained fullscreen shape, proves it has not
appeared in Program, and reverts it. Three subsequent Takes carry known graphic
and tone cues through actual output files. During the first recording, the
fixture moves its recording directory and stops preview. The still-open media
descriptor can continue writing; the test specifically requires the production
storage probe to report the missing directory, the controller to retain that
failure and its partial URL, and all recording writers/reservations to finish.
Both actual network publishers must remain live during cleanup and receive the
later cues. Stopping RTMP independently must leave SRT live.

`AVAssetReader` decodes the preserved local file and both received network
files. Assertions retain 60 ms source-cue alignment, 80 ms file cue alignment,
80 ms network track-start alignment, 120 ms track-end alignment, a maximum
150 ms decoded video step, and original source-cue spacing within 80 ms across
the storage failure. The library must classify the readable interrupted local
file as recoverable. `decoded-media.json` and `source-evidence.json` preserve
track ranges, frame counts, cue times, observed recorder failure and ownership.

## Publisher corrections exposed by the combined fixture

The studio's canonical Program bus is 48 kHz stereo packed Float32 PCM. On
macOS, the pinned HaishinKit multitrack mixer copies the input interleaving into
its Float32 AudioUnit bus format. Actual packed input caused its bus setup to
fail with status -10868, leaving the adaptive RTMP/SRT routes without audio.
`PublisherProgramAudio` changes only this Program input to planar Float32 before
the native mixer, preserving sample values and normalized host/sample time.
Existing microphone/app paths and canonical recorder/ISO PCM stay unchanged.
The conversion accepts the bounded, known stereo format and falls back to the
existing append path for other inputs.

The raw-capture frame-repeat timer also raced the studio's already-clocked
frames. A host-now duplicate could overtake the next real source frame; the
monotonic timestamp repair then advanced subsequent frames a full interval,
accumulating visible video/audio drift. Both adapters now skip capture repeats
when they receive the studio Program bus. The studio compositor already ticks
static scenes. Raw microphone/app capture and shared compressed-input behavior
retain their existing paths.

The initial combined runs independently exposed absent adaptive audio and then
444/535 ms network track-end differences after only the format correction.
The corrected native run passed the unchanged sync/cadence assertions with
both protocols and actual storage-error cleanup. It ran on Mac15,8, Apple M3 Max
(16 CPUs), macOS 27.2 (26B118), Xcode 27.2 (27B5038j). Its first completed output
contained 91 local frames over 3.033 seconds, 125 RTMP frames over 5.134 seconds,
and 261 SRT frames over 10.435 seconds; both receivers retained all three cues
and their maximum decoded video step was below 68 ms.
The final bounded repeat also passed: 91 local frames over 3.033 seconds,
129 RTMP frames over 5.149 seconds and 261 SRT frames over 10.468 seconds.
Its network endpoint differences were 93/36 ms, maximum decoded video step
85.3 ms, and all three taken graphic/tone cues survived on both receivers.

This is a controlled missing-recording-path failure and actual localhost media
qualification. It does not qualify a physical drive unplug, hardware capture,
public ingest, TLS delivery or sustained high-resolution workloads. The issue's
storage-isolation requirement does not depend on claiming those results.
