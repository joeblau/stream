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
100% across cores). Memory is the process peak resident set, not current memory
or GPU allocation. Encoder count includes active publishers and reserved
recording capacity, including preflight and finalization; it is not hardware
encoder utilization. Recording track endpoint difference compares last-written
timestamps, not perceptual A/V sync or independently measured clock drift.
Hardware capability ceilings are derived limits, not qualified workload claims.

## Export boundary

**Export Diagnostics…** saves JSON containing configuration geometry, derived
capabilities, counters, machine/OS information and recent lifecycle events. It
does not include captured media, credentials, source/output titles, endpoint
URLs, device labels or arbitrary error messages. Source/output/audio identifiers
receive fresh pseudonyms per export; matching events and audio counters remain
correlatable within that export. Unknown state/kind text is replaced with a
fixed identifier. The live inspector retains its original identifiers and names.

Export retains at most 256 sources, 64 outputs, 256 audio keys per counter and
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

R01 #91 still needs measured degraded-broadcast recovery while other outputs
remain healthy. GPU use and perceptual A/V drift are not currently measured by
this panel. R03 #92 needs named Apple Silicon and Intel sustained physical
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
