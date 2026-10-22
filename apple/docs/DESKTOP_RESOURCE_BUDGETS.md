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

Each case now writes an atomic `case-N.json` and updates `performance.json`
before media inspection or qualification gates. Earlier case files survive a
later failure. Checks distinguish pending inspection, failed qualification and
completed validation; a decoder stall cannot turn pending work into a pass.
Failed gates retain the report and exit nonzero after both cases. Recording
finalization, original host-clock and media inspection bounds remain in force.

Compressed sample timestamps provide a separate replay inventory: total source
frames, source duration, monotonicity and frames due before the existing
five-second allowance. Decoding the actual available frames is checked
independently from the original nominal `fps * Int(seconds - 5)` requirement.
Both nominal compositor capacity and nominal replay decoding remain required.
A slow first workload cannot manufacture a 30fps source for its second case;
successfully decoding its sparse recording does not pass the nominal gate.

`python3 apple/scripts/test_performance_evidence.py -v` checks durable failed
case receipts and nonzero exit, then writes and actually decodes a one-second
20fps H.264 source through the same inventory/replay implementation. That
bounded diagnostic regression does not replace a sustained capacity run.

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

### Updated hosted ARM measurement, run 39724736435

The fresh [ARM job](https://github.com/joeblau/stream/actions/runs/39724736435/job/119645957686)
on exact source `b53ae5d23a4b66df65b4974ea5ab90cc461e5267` completed both
600-second cases and **failed** the unchanged 17,850-frame qualification.
It used native arm64 Debug on VirtualMac2,1, three logical CPUs, 7 GiB RAM,
macOS 26.6.2 and the Apple Paravirtual Metal device. This is virtual-machine
evidence, not physical M1 certification. The original run remains unchanged.

| Observed result | Static source mix | Compressed replay mix |
|---|---:|---:|
| Actual compositor cadence | 28.2588 fps | 28.4079 fps |
| Rendered / required frames | 16,957 / 17,850 | 17,047 / 17,850 |
| Failed renders / wholly skipped opportunities | 16 / 1,028 | 0 / 955 |
| Written video frames | 16,956 | 17,046 |
| Writer-reported audio / video drops | 0 / 0 | 0 / 0 |
| Mean / maximum render wall time | 13.802 / 1,017.347 ms | 12.624 / 652.024 ms |
| Sampled actual CI kernel mean / maximum | 4.198 / 20.466 ms | 4.217 / 18.053 ms |
| Endpoint host-clock duration error | 6.958 ms | 9.593 ms |
| Maximum main-actor scheduling lag | 695.414 ms | 209.551 ms |
| Mean CPU fraction of total logical capacity | 13.10% | 15.56% |
| Peak physical footprint / Metal allocation | 101.1 / 82.4 MB | 238.9 / 193.7 MB |

Both recordings finalized and passed the original media inspection. The replay
actually decoded all **16,956 available source frames**; its actual-source
cadence check passed, while its nominal decode requirement failed because the
source itself supplied fewer than 17,850 frames. Correcting the separate
source-availability diagnostic boundary cannot turn this result into a pass.
Written counts remain one below the compositor counters; zero writer-reported
drops does not assert that every upstream rendered frame reached the file.

Compressed video PTS remained monotonic. Median gaps were 31.667 ms; 95th
percentiles were 78.333/76.667 ms, and maximum gaps 1.016666/0.653334 seconds.
There were 74/48 gaps above 100 ms. Attempts plus wholly skipped slots account
for 18,001/18,002 opportunities over the respective measured windows. Aggregate
subscriber drops include the deliberately slow sink and are not healthy-writer
drop counts.

All 590/589 process samples reported nominal thermal state. First/last-quarter
memory and Metal-allocation means stayed bounded after startup; these data do
not establish a growing retention problem or a CPU/GPU stall cause. Sampled
kernel time is not GPU utilization or complete render latency. Endpoint latency,
recording frontier skew and scheduling lag do not measure waveform A/V drift.

[The exact machine receipt](PERFORMANCE_HOSTED_ARM_39724736435.json) preserves
source hashes, raw failed checks, job/log/artifact/report/media digests, resource
summaries and compressed timestamp distributions. Intel job `119645957767` was
still active when this receipt was made. No additional dispatch, changed
threshold, smaller canvas, lower target rate or narrower workload was used.
Issue #92 remains open.

### Earlier failures and remaining scope

The compositor now retains one due render opportunity when a previous frame
finishes slightly late. Previously it rounded every completion up to another
future slot: a 33ms render plus 0.5ms wake jitter at 30fps could unnecessarily
halve cadence. Fully elapsed opportunities are still skipped. An overdue loop
yields its actor so stop and configuration work remain serviceable. Frames keep
their actual host-clock PTS; no elapsed time is compressed, no queued timeline
is replayed and neither target frame rate nor canvas size changes.

`zsh apple/scripts/run_composition_frame_schedule_harness.zsh` runs the shipping
helper against a deterministic virtual clock. Over virtual 600s, that specific
33ms/jitter case improves from 9,001 to 18,000 frames against the unchanged
17,850-frame requirement. A real 40ms render cost produces 15,000 frames and
still fails the 30fps requirement. Fast rendering retains the 30fps cap, starts
remain monotonic and a simulated 59s stall leaves at most one due opportunity.
These are scheduling regressions, not a repeated GPU or hardware qualification.

Read-only inspection of both retained hosted archives confirms ARM writers
accepted all 11,722/12,140 rendered frames with no audio/video mailbox drops.
Intel's first case wrote all 10,123 rendered frames but dropped 34 audio chunks.
Its replay writer stopped after receiving no video for ten seconds: only 1,689
frames through source time 117.14044s were written before the recoverable file
ended at about 127.48s. The final 2,209 compositor renders are neither that
written count nor a decoded-source count. This is a genuine stalled workload.

The original 59.192148398s Intel assertion is an unsigned change in endpoint
delivery latency: both frame PTS and callback arrival use the same host clock.
Its exact OS/render stall cause remains unresolved; it is not an independent
audio-clock or waveform drift measurement. The due-tick correction fixes a
concrete cadence-loss mechanism without claiming that it explains or repairs
that stall. [The forensic receipt](PERFORMANCE_HOSTED_FAILURES_2026-10-22.json)
retains original journal/archive/log hashes and the separate virtual-clock proof.

The hosted ARM job [119611316182](https://github.com/joeblau/stream/actions/runs/39713883982/job/119611316182)
failed its requested two 600-second 1080p30 workload on VirtualMac2,1 / Apple M1
(Virtual), macOS 26.6.2, Xcode 26.6. Static and replay cases rendered 11,722 and
12,140 frames, about 19.5 and 20.2 frames per requested second. The first case
reported seven failed renders; the second reported none. Both arrival sequences
were monotonic. The original nominal replay requirement was 17,850 frames.
Its trap occurred before the old aggregate JSON write, so the original log
does not contain a decoded replay count or recoverable resource summary. The
new diagnostics preserve those facts on future runs; they do not change this
failed 30fps qualification. [The failure receipt](PERFORMANCE_HOSTED_ARM_FAILURE_2026-10-22.json)
retains original log/artifact hashes and explicitly unknown measurements.

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
