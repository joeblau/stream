# Desktop resource guards and measured workloads

Issue #92 remains open. Existing `StreamCapability` and `OutputCapabilities`
hardware ceilings remain in force; these changes do not certify a new Mac,
output count, capture mix, resolution or frame rate.

## Protect optional work first

The runtime samples actual process CPU time, task resident/physical-footprint
bytes, thermal state and the Program compositor's missed-deadline deltas once
per second. CPU is normalized to this Mac's logical capacity. The existing
capability model now derives an optional-preview footprint budget of one fifth
of physical RAM, bounded to 256 MiB–4 GiB.

Three seconds of CPU use above 80% of logical capacity, footprint above the
budget, serious thermal state or at least 10% missed Program deadlines reduces
staged preview to at most 15 fps and a 1280-pixel long edge. Critical thermal
state reduces it immediately to 5 fps / 640 pixels; sustained severe footprint
or missed-deadline pressure does so after one second. Monitor image conversion
cadence follows the same guard. Thirty clear seconds restore one stage at a
time. Invalid or stale observations cannot restore or escalate the policy.
Stopping the pipeline clears observation windows and the CPU baseline while
retaining the last safe preview level. Idle time cannot count as measured
pressure or recovery, and a new lifecycle requires a fresh CPU delta.

Only the optional preview engine, its secondary raster and monitor conversion
cadence change. Program geometry, source enables, media clocks, outgoing
publisher objects, recording configuration and encoder reservations are never
reconfigured by this policy. The HUD says Preview limited when the guard acts.
This conservative hysteresis is a runtime safety policy, not a measured
promise that every workload will remain within budget or recover from pressure.

The bounded `resource-budget.v1.json` in the machine directory persists hardware
and OS identity, native/translated architecture, existing output ceilings,
derived preview gate and the latest 120 observations. Atomic background writes
are capped at 1 MiB. There are no URLs, account credentials, source names,
bookmarks or captured media in that report.

## Actual Metal observations

The device name, unified-memory flag, recommended working set, current Metal
allocation and supported counter-set names come from the actual `MTLDevice`.
Allocation is not GPU utilization. The collector explicitly reports that
process-wide utilization is unavailable through this API.

One of every thirty renderer frames uses an actual `CIRenderTask` and records
`CIRenderInfo.kernelExecutionTime` after completion. This is sampled Core Image
kernel execution time on the selected Metal backend, not a CPU wall timer or
an empty artificial GPU job. Failed/zero timing observations remain explicitly
unavailable; rendering uses the existing path if timing fails. Software/no-Metal
backends do not claim GPU timing. A local asymmetric-color/alpha parity probe
found zero byte differences between the original render and measured task path
on Apple M3 Max; the real task reported 0.02975 ms kernel execution.

Apple references: [allocated Metal resources](https://developer.apple.com/documentation/metal/mtldevice/currentallocatedsize),
[Core Image render information](https://developer.apple.com/documentation/coreimage/cirenderinfo),
[kernel execution time](https://developer.apple.com/documentation/coreimage/cirenderinfo/kernelexecutiontime).

## Reproducible sustained observations

Run on an otherwise quiet host, using an owned clean vendor root:

```sh
STREAM_VENDOR_ROOT=/path/to/owned/Vendor \
STUDIO_PERFORMANCE_SECONDS=600 \
zsh apple/scripts/run_studio_performance_harness.zsh --sustained
```

The two workloads each run for 120–600 seconds (180 by default). The first
retains static owned camera/desktop placeholders and ten text/shape layers at
1080p30 while producing real H.264/AAC. The second actually decodes that owned
1080p compressed file on its media clock and reuses the decoded pixels in the
layer mix while encoding a new recording. Decode holds only its latest pixel
buffer. An independent original-host 48 kHz PCM grid covers the final video
source frontier. A deliberately slow sink exercises bounded fanout isolation.
No user camera, microphone, screen source, permission prompt or provider starts.

Reports retain actual CPU/footprint/Metal allocations and kernel timings,
compositor cadence/queue drops, main-actor scheduling lag, original host-clock
duration error, encoder/writer outcomes, accepted recording track-frontier skew,
bytes and write rate. Original generated recordings and journals remain beside
the report. A process-group deadline bounds the run. `--build-only` permits
building first and measuring later without concurrent compiler load.

The manual Native performance budgets workflow runs the same bounded workload
on ARM and Intel hosted Mac runners and retains original evidence. Intel jobs
reject translated processes; a Rosetta run cannot qualify Intel hardware.
No workflow was triggered by the local implementation task.

## Quiet-host observations on October 22, 2026

Commit `fd5f1ce` was measured after all collaborating native builds and media
tests paused. Mac15,8 / M3 Max, 16 logical CPUs, 128 GiB RAM, macOS 27.2
(26B118), Xcode 27.2 (27B5038j), native arm64 ran both 120-second sampling
windows. Each contained twelve layers. Both original H.264/AAC recordings
finalized and decoded with zero writer audio/video drops. The second workload
actually decoded 3,600 source frames. Its Program compositor missed seven
deadlines; no render failed. This is an observation, not a zero-drop guarantee.

| Observation | Static owned source mix | Owned compressed replay mix |
|---|---:|---:|
| Achieved compositor cadence | 29.9899 fps | 29.9312 fps |
| Rendered frames | 3,600 | 3,593 |
| CPU, mean fraction of total logical capacity | 2.776% | 2.901% |
| Maximum physical footprint | 263.2 MB | 262.4 MB |
| Maximum actual Metal allocation | 10.94 MB | 22.69 MB |
| Actual CI Metal kernel mean / maximum | 0.404 / 4.422 ms | 0.477 / 0.563 ms |
| Maximum main-actor scheduling lag | 15.01 ms | 89.68 ms |
| Original host-clock duration error | 12.19 ms | 8.38 ms |
| Observed recording write rate | 0.573 MB/s | 0.576 MB/s |
| Maximum accepted recording-frontier skew | 30.49 ms | 28.63 ms |

Each case retained 119 actual process samples and 120 completed Metal kernel
timing samples, with nominal thermal state throughout. The GPU exposed a
timestamp counter set; process-wide GPU utilization remained unavailable. The
writer rate is the achieved workload rate, not the disk ceiling. Frontier skew
and scheduling lag retain the limitations below. The raw original report's
`seconds` included about seven seconds of final decoding/validation; future
reports separate actual compositor sampling time and validation time.

[The bounded measurement summary](PERFORMANCE_OWNED_SUSTAINED_2026-10-22.json)
retains the exact run commit, hardware facts, measured counters and SHA-256
receipts for both original recordings and the original unmodified report.
The subsequent lifecycle reset does not change these continuously running
workloads; the measurements were not repeated or relabeled as a later commit.

## Qualification limits

These owned workloads add real decode/encode, sustained scheduling and actual
resource measurements. They are not representative physical camera/desktop
capture qualification. Main-actor scheduling lag is a responsiveness proxy,
not input-to-photon interaction latency; recording frontier skew is not a
waveform or independent device-clock drift measurement. One recording encoder
does not measure maximum encoder/output counts or Internet uplink limits.
The separate actual healthy RTMP/SRT fixture is required for live-output
continuity while preview guards act.

Original #92 acceptance still requires representative camera/desktop/media and
interactive UI mixes, long thermal runs, independent sustained A/V sync,
measured storage/uplink ceilings, supported output/encoder counts and named
Intel configurations. Missing counters or failed workloads remain gaps or
measured limits, never a fabricated successful benchmark.
