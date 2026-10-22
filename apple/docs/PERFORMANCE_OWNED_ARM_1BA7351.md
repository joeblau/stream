# Sustained owned ARM workload, 2026-10-22

**PASS:** one actual native invocation completed both original 600-second
1920×1080/30fps cases and their media inspections on an Apple M3 Max,
Mac15,8, macOS 27.2 (26B118), Xcode 27.2 (27B5038j), Swift 6.4.2. No retry ran.
The first case used the existing generated desktop/camera placeholders and
12-layer mix. The second actually decoded the first H.264 recording into that
same mix. Both retained the real recorder, independent 48 kHz PCM and deliberate
80ms consumer. This is named local ARM evidence for #92; the issue's other
supported configurations and representative workloads remain separate.

| Original counter or gate | Static 600s | Decoded replay 600s |
| --- | ---: | ---: |
| Rendered, required ≥17850 | 18001 | 17978 |
| Render failures | 0 | 0 |
| Whole clock opportunities skipped | 0 | 23 |
| Written video frames | 18000 | 17977 |
| Healthy post-warmup arrivals | 17970 | 17947 |
| Actual replay input / decoded frames | — | 18000 / 18000 |
| Endpoint duration error, required <80ms | 9.500ms | 1.785ms |
| Written video / audio drops | 0 / 0 | 0 / 0 |
| Recorder ingress drops | 0 | 0 |
| Deliberate slow-recipient drops | 10813 | 10792 |
| Original checks completed/passed | 7/7 | 11/11 |

Render, writer, post-warmup arrival and decoder counts measure different
boundaries. The one-frame render/writer differences are preserved. The replay
input's original timestamp-based grace frontier required 17850 decoded frames;
all 18000 available input frames decoded. The nominal input and decode gates
also passed without substituting actual-source cadence for nominal capacity.

The recorder used its actual count 30 / 128,000,000-byte queue policy and
headroom 5: measured queue cost 8,294,400 bytes gives Q15 and private threshold 20.
Actual backing cost was 8,294,464 bytes per surface. Source threshold 4 and slow
recipient threshold 3 remained fixed. Both slow-recipient receipts attributed
their drops to private queue eviction plus one retired intent; neither case
reported source allocation failures or healthy-recorder ingress loss. This
tests a slow callback, alongside the separate broker proofs for extracted
CVPixelBuffer/IOSurface holders; it does not replace those adversarial proofs.

Static/replay mean render cost was 4.795/4.473ms; process CPU time was
226.276/256.509 seconds over the 600-second windows. Peak resident memory was
269,320,192/287,932,416 bytes. The existing sampled kernel collection retained
601/600 samples; it measures kernel cost, not GPU utilization. All 594/593
resource snapshots reported thermal state 0. Replay still had a 192.428ms
maximum render and 172.808ms maximum main-actor scheduling delay; passing the
cadence allowance is not a claim of no stalls. Raw per-second samples remain
in the original case files.

Writer PCM extended beyond the final submitted video endpoint by 9.407/9.182ms.
Maximum observed writer frontier skew was 27.624/30.815ms. These are source
frontier and endpoint metrics, not independent waveform-clock drift. The
original media inspection retained its existing `checkSync:false` setting;
no new audio decoder fallback or inspection substitution was introduced.

The test binary was the already compiled unsigned Debug arm64 tool with
SHA256 `7dbab453cb597706484aefb4177eff6143a9ff88fe0ed12272b2345d2614567c`.
Its harness SHA256 `ce1771c698cd8dea42e341778f2445cfd55f346c311abb6d53d3999614dd23ae`
matches published `1ba7351`. Its shipping sources were compiled from `662930f`;
the only shipping differences through `1ba7351` are four EOF-newline removals,
listed in the machine receipt. No application source was rebuilt or replaced
for this invocation.

The existing owned-process launcher ran once with
`STUDIO_PERFORMANCE_SECONDS=600` and `--sustained`, under the native slot
wrapper. Its 1380-second deadline covered both windows, writer finalization
and media inspection. Both validations completed within that original bound.
The root reserved the local native/GPU window; ordinary host background work
remained uncontrolled and no OS settings changed. No personal capture,
network, RTC, external output, or UI interaction occurred.

Original stdout, recordings, journals and per-case resource/check files are
retained under `/tmp/stream-owned-arm-sustained-1ba7351-20261022`. The
[machine receipt](PERFORMANCE_OWNED_ARM_1BA7351_2026-10-22.json) binds all 10
original artifacts, the compiled binary, source identity and exact counters.
The original [hosted 600s failures](PERFORMANCE_HOSTED_39735454725.json) remain
failed. A physical M3 Max pass neither diagnoses those VM failures nor
certifies Intel, all hardware, physical capture or Internet uplink capacity.
