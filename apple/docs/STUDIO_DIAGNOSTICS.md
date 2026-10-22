# Studio diagnostics and qualification limits

The main-window diagnostics row reports Program achieved cadence and target
cadence, cumulative render time, late ticks, render failures, consumer queue
depth and dropped consumer frames. Health Details separates per-source capture
delivery from per-output encoded cadence, bitrate, mailbox/socket queues and
congestion drops. A static screen may deliver no new capture frames while the
compositor continues to emit Program frames. A missing socket/congestion probe
reads **unavailable**, so an unsupported probe does not imply a healthy zero.
The uplink HUD also separates measured encoder FPS from its target; a zero
measurement is displayed instead of being replaced by the target. A live output
awaiting its first telemetry snapshot remains labeled live.

CPU is a sampled process CPU-time delta divided by wall time (it may exceed
100% across cores). Peak memory is the process peak resident set. Separate runtime collector
fields expose current resident size, physical footprint, and Metal allocation
when available, with their sample age; these are distinct measurements. CPU
also has a logical-machine-capacity percentage, unavailable until a delta
exists. Optional preview budget, main-actor delay, unified-memory capability,
recommended Metal working set and counter-set count come from that same
collector. Sampled completed Core Image Metal kernel time has its own count,
mean and maximum; it is not process-wide GPU utilization. Encoder count includes active publishers and reserved
recording capacity, including preflight and finalization; it is not hardware
encoder utilization. Recording track endpoint difference compares last-written
timestamps, not perceptual A/V sync or independently measured clock drift.
Hardware capability ceilings are derived limits, not qualified workload claims.

## Observed A/V timestamp clocks

Health Details reports offset in **milliseconds** and relative timestamp rate
in **milliseconds per second**, projected from audio/video PTS onto the same
monotonic host observation instant. Positive offset means the observed audio
clock is ahead; positive rate means it advances faster. A fixed offset is not
rate skew. These measurements do not inspect image/sound content and do not
measure lip sync, receiver playout, or physical device oscillator error.

Named boundaries are deliberately separate:

- Camera/screen sample callbacks observe original capture PTS. A camera with
  no associated audio reads unavailable, never zero drift.
- Each accepted source PCM ingest observes original PTS before insert effects,
  resampling and user delay, against actual Program video observations. These
  are explicitly source-PCM/Program-video comparisons; a microphone is not
  silently assumed to belong to a particular camera.
- Program/secondary compositor and mixed-audio fanout observes the shipping
  buffers before destination queues.
- Each publisher observes samples after actual admission and timeline
  normalization at raw encoder ingress. When shared encoding is enabled this
  boundary instead observes compressed samples admitted to that publisher.
- Shared H.264 VideoToolbox completion and successfully produced AAC packets
  have a separate actual encoded callback observation. The default HaishinKit
  backend does not expose its compressed callbacks publicly, so post-encode
  measurement is unavailable there. Its public raw StreamOutput observer is
  not used as evidence of encoded callbacks.

Each track stores at most 256 points / 12 seconds, sampled at up to 20 Hz.
Two seconds and eight observations per track are required. Least-squares
PTS-versus-host fits expose residual RMS and relative-rate standard error.
Residual above 5 ms suppresses numeric offset/rate as uncertain callback
jitter; callbacks older than two seconds suppress them as stale. Rate skew
requires magnitude above both 2 ms/s and three standard errors. An offset
above 80 ms with no confident rate skew is classified separately. These are
inspection thresholds, not latency or supported-workload guarantees.

Out-of-order/duplicate timestamps are rejected and counted. A host gap over
two seconds, a timestamp epoch jump over 150 ms, capture reset, publisher
start/reconnect/pause/resume or explicit teardown creates a fresh window.
Dropped callbacks retain their elapsed timestamps rather than changing rate.
A smooth delivery-delay trend is mathematically indistinguishable from a
media-clock rate change using these observations alone; the UI therefore says
**observed timestamp-rate skew**, with the boundary, residual and sample ages.
No observer corrects or retimes production samples.

`run_av_clock_telemetry_harness.zsh` tests the production estimator with known
zero rate, fixed 200 ms offset, 1% rate skew, dropped/held callbacks, stale or
missing tracks and epochs. `STORAGE_NETWORK_CLOCK_VALIDATION=1` adds controlled
original-PCM clock inputs and snapshot assertions to the existing actual
compositor/mixer/recorder/RTMP/SRT storage-failure fixture. Named-host results
must be recorded after that native run; estimator fixtures alone do not prove
healthy encoded media or independent network outputs.

## Export boundary

**Export Diagnostics…** saves JSON containing configuration geometry, derived
capabilities, counters, machine/OS information and recent lifecycle events. It
does not include captured media, credentials, source/output titles, endpoint
URLs, device labels or arbitrary error messages. Source/output/audio identifiers
receive fresh pseudonyms per export; matching events, source PCM clocks and audio counters remain
correlatable within that export. Unknown state/kind text is replaced with a
fixed identifier. The live inspector retains its original identifiers and names.

Export retains at most 256 sources, 64 outputs, 256 audio keys per counter/clock collection and
the last 256 lifecycle events. JSON must fit within 1 MiB or saving fails with
an explicit error. Nonfinite numeric probes serialize as `"unavailable"`, never
as a misleading zero. This file includes machine model, OS and resource limits;
review it before sharing if those details are sensitive.

Run `zsh apple/scripts/run_studio_diagnostics_harness.zsh` for the actual
production data/export boundary with injected unrecognized strings, oversized
collections and unavailable numeric values. It compiles the production
capability/protocol sources directly and needs no cached app/framework build.
This verifies redaction, collection bounds, correlated fresh pseudonyms and
preservation of the runtime snapshot. It does not exercise real capture,
publishing, storage pressure or physical hardware.

## Named-host evidence and retained limits

[The bounded measurement artifact](AV_CLOCK_PIPELINE_2026-10-22.json) records
Mac15,8 (M3 Max, 16 logical CPUs, 128 GiB), macOS 27.2 (26B118), the controlled
source observations, four actual canonical redacted bundles and decoded media
measurements. `STORAGE_NETWORK_CLOCK_VALIDATION=1` with
`run_recording_storage_network_harness.zsh` passed using the shipping
StreamController compositor/mixer, real RecordingController and actual RTMP/SRT
publishers/owned FFmpeg receivers. No raw media is included in the artifact.

The final run measured the stable source at −0.123 ms/s; the fixed 120 ms offset
changed timestamp offset by 119.76 ms with rate −0.104 ms/s; injected 1% skew
measured +9.801 ms/s. Dropped callbacks remained stable; the held callback had
10.54 ms residual and suppressed numbers. Stop/rejoin, camera-only unavailable,
actual resource samples, persistent runtime timers and failed-recorder events
passed. Canonical current resident size was 107.7 MB, physical footprint
213.8 MB, Metal allocation 0.967 MB, CPU 4.95% of logical capacity; six real
Core Image Metal kernel samples had mean 0.0165 ms and maximum 0.0222 ms.
These are observations of this small 320×180/30 fps workload, not capacity limits.

Real recording-path loss released its writer/encoder reservation while both
network outputs kept all three taken cues. Independently decoded RTMP/SRT
maximum cue errors were 29.2/46.3 ms, maximum frame steps 68.0/68.6 ms and track
end differences 81.0/40.1 ms. Existing source <60 ms, decoded cue <80 ms,
track ends <120 ms and cadence <150 ms assertions were preserved. Program
geometry remained 320×180 through reduced/minimum optional-preview budgets.
A separate actual output-controller lifecycle fixture verifies reconnect timer
continuity, terminal failed-output timer retirement and last-output failure.

Two earlier assertions wrongly assumed every fresh clock must remain stable:
actual shared codec callbacks had 6–7 ms delivery residual; a fault-time raw
callback excursion had 7.20 ms video residual. Production correctly reported
uncertain and suppressed numeric rate/offset. Those failed logs are retained
in the artifact. The fixture now verifies freshness and that residual above
5 ms suppresses numbers, keeping initial stable-playback checks and all
independent decoded media limits unchanged. No estimator threshold, source
PTS, normalizer, correction or retiming behavior was changed.

Shared H.264/AAC's real callbacks and each publisher ingress were measured,
with their actual jitter explicitly uncertain. Its independent decoded RTMP
cue errors were 75.2, 82.2 and 91.2 ms, exceeding this fixture's unchanged
80 ms limit; the run failed and SRT decode qualification was not reached.
That publishing/performance gate remains unqualified. The passing normal
backend failure-isolation result and truthful diagnostic uncertainty do not
claim shared-backend media health, perceptual sync or device oscillator drift.

Native builds used the shared two-slot scheduler and `xcodebuild -jobs 2`.
Xcode appended generated `-j16` after requested `OTHER_SWIFT_FLAGS=-j2`;
Swift driver concurrency was therefore not independently established as two.
The small terminal-timer fixture compiled directly with `swiftc -j2`.

R03 #92 workload gates and named configuration limits are maintained in
[DESKTOP_RESOURCE_BUDGETS.md](DESKTOP_RESOURCE_BUDGETS.md). Timestamp observations
do not broaden those limits. Accessibility qualification remains separate in
[STUDIO_CONTROLS.md](STUDIO_CONTROLS.md).
