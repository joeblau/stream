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

### Hosted run after font caching: original capacity gates still fail

Run [39735454725](https://github.com/joeblau/stream/actions/runs/39735454725)
measured exact source `98813596d02a58d4eb6538c2b0b538bdeb7008f8` with two
600-second 1080p30, 12-layer static/replay cases on each platform. Both jobs
**failed**. All four cases remained below the original 17,850-frame requirement;
the canvas, frame rate, allowance and launcher deadline were unchanged.

| Platform / case | Previous → current rendered frames | Current fps | Mean render wall time | Whole skipped opportunities |
|---|---:|---:|---:|---:|
| ARM static | 16,957 → 17,252 | 28.7508 | 10.250 ms | 740 |
| ARM replay | 17,047 → 17,306 | 28.8404 | 8.992 ms | 695 |
| Intel static | 17,366 → 17,232 | 28.7166 | 19.685 ms | 745 |
| Intel replay | 17,058 → 16,434 | 27.3864 | 27.538 ms | 1,525 |

The comparison is with run `39724736435` on the same advertised host classes
and OS versions. ARM gained 295/259 frames; Intel lost 134/624. Mean render wall
time fell in all four cases, from 13.802/12.624 ms on ARM and 28.213/31.431 ms on
Intel. These are observations across separate hosted runs, not a universal
cadence improvement or controlled causal proof. ARM reported VirtualMac2,1,
three CPUs, 7 GiB RAM and macOS 26.6.2; Intel reported Macmini6,2, four CPUs,
14 GiB RAM and macOS 26.6.1. Both exposed Apple Paravirtual Metal devices, so
these results do not certify physical M1 or Intel machines.

ARM replay decoded **17,251 of 17,252** available source frames, against 17,110
due before decoder grace ended. Intel decoded **17,232 of 17,232**, against
17,090 due. Both actual-source checks passed; both nominal replay input and
decoding gates still failed. Render failures were 9/0 on ARM and 24/42 on Intel.
Writer-reported video sample counts equal the rendered counters in these cases;
all four writers completed with zero reported audio/video drops. The healthy recorder
sink is removed before the mailbox metrics snapshot, leaving the deliberate
80 ms sink's drops/depth. Those counters are not recorder loss or actual UI
preview drops.

Both ARM media inspections and Intel's first inspection completed. Intel's final
inspection remained **pending** when the owned launcher reached its existing
`2 × 600 + 180 = 1,380` second wall deadline. Both measurement windows and both
writers had already finished. Its numeric capacity failures remain failures
independently of that additional timeout; neither eventual inspection success
nor a blocking API is inferred.

Endpoint host-clock errors were 6.404/2.634 ms on ARM and 2.965/5.215 ms on
Intel, within the original 80 ms bound. They do not measure independent waveform
A/V drift. Main-actor maximum lag was 471/335 ms on ARM and 129/461 ms on Intel.
All sampled thermal states were nominal. Mean CPU fractions of total logical
capacity were 9.97%/12.72% and 7.78%/12.43%, respectively. Maximum render wall
times reached 787/1,183 ms on ARM and 1,000/482 ms on Intel despite the lower
means. Sampled CI kernel means were 4.703/5.428 ms and 12.768/16.507 ms; these
are not GPU utilization or complete render time. The aggregate resource samples
do not identify the remaining latency or skip cause.

[The terminal machine receipt](PERFORMANCE_HOSTED_39735454725.json) retains
source hashes, unchanged gates, all raw check statuses, logs/archive/media
digests, resource summaries and the exact incomplete Intel validation state.
The original earlier failures remain unchanged; issue #92 remains open.

The hosted receipt proposed a separately authorized 20-second trace to distinguish
deadline-start lateness, thread CPU versus wall time in graph/CI/fanout phases,
and mailbox lock/drop-release/callback costs. The subsequent single local trace
below implements that plan. The hosted run was not repeated or relabeled.

### Bounded thread CPU, render and mailbox trace

Exact source `78796d13dffc193217c6aa6ec3a8ecfb8a562182` ran once on the local
Mac15,8 / M3 Max, native arm64, macOS 27.2 (26B118). Generated source copies
instrumented the existing two 20-second 1080p30, 12-layer static/replay cases,
with the real recorder, independent PCM and deliberate 80 ms sink. Shipping
sources, the sustained harness and its original gates remained byte-identical.
The generated renderer retained the same render calls and existing sampled
task wait; no extra render or wait was added.

| Mean interval | Static wall / thread CPU | Replay wall / thread CPU |
|---|---:|---:|
| Measured tick body | 8.968 / 3.997 ms | 6.622 / 3.593 ms |
| Scene graph preparation | 1.406 / 1.152 ms | 1.324 / 1.031 ms |
| Regular Core Image call | 6.814 / 2.270 ms | 4.636 / 2.020 ms |
| Existing sampled task wait | 1.833 / 0.021 ms | 0.923 / 0.023 ms |
| Subscriber fanout | 0.204 / 0.158 ms | 0.176 / 0.147 ms |

The measured tick interval starts after `frameOverrideProvider` and the scene
guard; the override phase is recorded separately. Thread CPU is never subtracted
across asynchronous suspension. The deliberate sink's synchronous `Thread.sleep`
remains on the same thread and is included in its callback wall/CPU interval.

Neither case skipped a whole scheduling opportunity. Maximum tick wall times
were 29.553/25.633 ms, deadline-start lateness 5.090/7.284 ms and actor-entry
delay 0.075/0.158 ms. Static rendered 600 of 601 attempts: sequence 5 failed
the existing pixel-buffer allocation threshold (`-6689`) during a 0.312 ms
tick. Replay rendered 601 of 601. Both actual recordings finalized and decoded
600 frames; replay's source decoder consumed 599 of 600 available frames,
against 449 due. Replay's final sequence 601 posted only to the slow sink;
healthy posts and deliveries cover sequences 1–600. These distinct counts are
retained without calling the difference a writer drop.

The deliberate sink completed 233 callbacks per case, averaging 86.074/86.265 ms
wall despite its nominal 80 ms sleep. Maximum drop-removal/release intervals
were 0.550/0.270 ms and fanout 2.044/1.570 ms. The measured between-callback
residual includes release, loop, scheduling and instrumentation; it does not
isolate destruction. Events are constructed outside mailbox critical locks.
The trace retained 22,780/22,788 events with no omissions or synchronous thread
migrations. Mean full-record calibration overhead was about 0.0017 ms per call;
nested measurements overlap and instrumentation adds cost.
Both healthy callback peaks contain the profiler-only first-warm pixel hash
(10.917/13.097 ms); they do not measure a shipping recorder callback peak.

The regular Core Image call's wall/CPU difference does not separate off-thread
work, host scheduling, driver work and GPU waiting. The existing task wait is
mostly non-CPU; kernel samples remain execution time, not GPU utilization.
No hosted-like long stall or whole skip reproduced. These local observations
establish no cause or production fix for the hosted deficits, historical Intel
59-second endpoint error or pending inspection at its 1,380-second deadline.
The local tool's duration-dependent 450-frame check is not the original
17,850-frame / 600-second qualification. Issue #92 remains open.

[The trace receipt](PERFORMANCE_LOCAL_THREAD_TRACE_2026-10-22.json) retains raw
case checks, source/generated hashes, event correlations, calibration, resources
and log/media digests. `run_composition_hotpath_profile.zsh` reproduces the
generated-copy tool; reserve a quiet host and build first with `--build-only`.
No additional trace or hosted dispatch followed this measurement.

### Bounded local title preparation profile

A separate 20-second static/replay comparison on Mac15,8 / M3 Max found an
avoidable CPU preparation cost: each unchanged title rebuilt its Core Text font
and fallback cascade before consulting the raster cache. The four titles caused
2,404 cascade constructions per case despite 2,400 raster-cache hits.

| Mean wall time per frame | Original static / replay | Cached static / replay |
|---|---:|---:|
| Font construction or cached lookup | 4.472 / 4.628 ms | 0.054 / 0.038 ms |
| Scene graph preparation | 5.237 / 5.383 ms | 0.782 / 0.820 ms |
| Complete tick | 8.580 / 9.572 ms | 6.499 / 4.913 ms |
| Regular Core Image render | 3.186 / 3.957 ms | 5.386 / 3.834 ms |

The local cases kept the same 1080p30 canvas, generated screen/camera content,
six shapes, four titles, real recorder and deliberately slow subscriber. All
four cases produced 601 frames without skipped opportunities or failed renders.
Original replay decoded 601 and candidate replay decoded 600 of 601 available
source frames; each inventory had 450 due before the short fixture allowance.
Static Core Image time
increased in the second measurement; these observations support removing the
repeated font preparation, not a universal whole-render speedup or an explanation
for the hosted stalls. Candidate font-span counts measure lookups, not actual
cache misses or constructions.

Fonts now reuse a renderer-local cache bounded to 64 request/size pairs. Process
and distributed font-registration notifications, locale notifications and
preferred-language changes invalidate font-dependent resources. Same-name font
replacement also refreshes title rasters, ticker lines, comment layouts and
baked nested scenes. A registry change during a nested bake permits that
in-flight frame to finish, but prevents retaining the mixed result.

Native complete-buffer comparisons match the original renderer for static,
Unicode, missing-font fallback, sizes/styles, wrapping, scale-down and ellipsis.
Owned process-only fonts prove registration/removal, same-PostScript replacement
and a change between two nested title builds. The next settled/transition frame
and subsequent cache hit match a fresh replacement reference. Removing only the
nested retention guard fails this regression; restoring production source passes.
The benchmark also retains identical before/after visible-pixel hashes for one
warm frame per case; this does not claim every frame was hashed.

Reproduce the focused font probe with
`zsh apple/scripts/run_title_font_cache_harness.zsh`; the actual renderer probe is
`zsh apple/scripts/run_title_render_font_harness.zsh` and requires a checkout
containing ancestor `44c078e` for the original reference. The optional
`zsh apple/scripts/run_composition_hotpath_profile.zsh` generates instrumented
copies, runs exactly 20 seconds per case and retains source hashes/counters.
Its build uses two jobs; coordinate local GPU profiling with other native work.
It does not edit the shipping renderer or the sustained harness/gates.

[The source and measurement receipt](TITLE_FONT_CACHE_PROFILE_2026-10-22.json)
distinguishes the short measured candidate from its later nested-retention guard
and retains the final native regression, negative control and initial unordered
fixture failure. This local profile is not sustained or physical-source
qualification. The real hosted failures below remain failed; issue #92 is open.

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
still active at that receipt's observation; its terminal result follows below.
No additional dispatch, changed
threshold, smaller canvas, lower target rate or narrower workload was used.
Issue #92 remains open.

### Updated hosted Intel measurement, same run

The [Intel job](https://github.com/joeblau/stream/actions/runs/39724736435/job/119645957767)
also completed both 600-second cases and **failed** the unchanged 17,850-frame
qualification on the same exact source. It reported native x86_64 Debug,
Macmini6,2, four logical CPUs, 14 GiB RAM, macOS 26.6.1 and an Apple Paravirtual
Metal device. The advertised model does not establish physical Intel hardware
qualification.

| Observed result | Static source mix | Compressed replay mix |
|---|---:|---:|
| Actual compositor cadence | 28.9406 fps | 28.4278 fps |
| Rendered / required frames | 17,366 / 17,850 | 17,058 / 17,850 |
| Failed renders / wholly skipped opportunities | 38 / 597 | 50 / 893 |
| Written video frames | 17,366 | 17,058 |
| Writer-reported audio / video drops | 0 / 0 | 0 / 0 |
| Mean / maximum render wall time | 28.213 / 450.280 ms | 31.431 / 363.880 ms |
| Sampled actual CI kernel mean / maximum | 13.286 / 23.118 ms | 15.849 / 23.432 ms |
| Endpoint host-clock duration error | 7.074 ms | 25.533 ms |
| Maximum main-actor scheduling lag | 199.181 ms | 356.543 ms |
| Mean CPU fraction of total logical capacity | 11.51% | 14.29% |
| Peak physical footprint / Metal allocation | 186.2 / 79.9 MB | 74.7 / 88.8 MB |

Both recordings finalized and passed the original media inspection. Replay
decoded all **17,366 available source frames**; the actual-source cadence check
passed, while both nominal compositor checks and nominal replay decoding failed.
The source itself remains below the unchanged 17,850-frame requirement, so the
later source-availability diagnostic correction does not alter this failure.

Compressed video PTS remained monotonic. Median gaps were 33.333 ms; 95th
percentiles were 60.000/56.667 ms and maximum gaps 450.000/363.333 ms. There were
70/117 gaps above 100 ms and none above 500 ms. All 590/591 resource samples
reported nominal thermal state. These measurements do not identify the cause
of the remaining missed cadence; sampled kernels do not measure GPU utilization.

The original Intel run's 59.192-second endpoint error and ten-second no-video
abort did not recur in this run. Their underlying cause remains unestablished;
the original failure evidence is retained. Current endpoint errors passing the
80 ms gate do not measure independent waveform A/V drift.

[The terminal Intel receipt](PERFORMANCE_HOSTED_INTEL_39724736435.json) retains
the exact source, failed gates, raw log/archive/report/media hashes, compressed
timestamp distributions and terminal status of both jobs. Run `39724736435`
finished **failure**. No additional workload dispatch or qualification change
was made; issue #92 remains open.

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
