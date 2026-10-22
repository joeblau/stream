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

## Remaining acceptance gates

R01 #91 native clock and degraded-broadcast qualification is pending the
combined actual-pipeline run described above. Perceptual A/V sync and hardware
GPU utilization are not claimed by these timestamp observations. R03 #92 needs named Apple Silicon and Intel sustained physical
camera/desktop/media mixes, UI scheduling, actual GPU/encoder pressure,
storage/uplink limits and independently measured A/V sync. The short synthetic
`run_studio_performance_harness.zsh` baseline is useful for regression but does
not qualify those workloads. Do not replace prior performance evidence with
unrelated synthetic timings or infer supported workloads from core/RAM counts.

P06 #90 still needs VoiceOver and Full Keyboard Access traversal, focus after
all native sheets, and compact-display checks described in STUDIO_CONTROLS.md.
Effects controls now provide named layer/source scopes, explicit numeric units
and preset deletion targets. E02 #107 / E04 #108 still require representative
hair/edge footage, physical-camera color inspection and sustained render cost;
the existing native synthetic color fixture does not establish those results.
