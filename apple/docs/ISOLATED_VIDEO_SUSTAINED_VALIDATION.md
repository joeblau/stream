# Isolated video identity and sustained controller validation

Issue #171 requires selectable camera, guest and optional screen video taps,
chosen associated audio, encoder/storage admission, synchronized files and
manifest gaps, and independent operation during source/resource failure.
Only the enabled class is qualified: Apple M3 Max, Mac15,8, 16 logical CPUs.
Other models remain disabled by `IsolatedVideoBudget.current`; no limits are
inferred for another Apple Silicon variant or Intel Mac.

## Reproduction and boundaries

Run from `apple` using an owned vendor/build directory and the native build-slot
wrapper when sharing a host:

```sh
STREAM_FIXTURE_AUDIO_DECODER=av-audio-file \
STREAM_VENDOR_ROOT=/absolute/owned/vendor \
scripts/run_isolated_sustained_harness.zsh
```

The runner builds shipping controller, capture-pool demand/identity,
full-generation guest receipt routing, mixer, compositor, source renderer,
Program/isolated writers and RTMP publisher. A real FFmpeg listener copies the
published audio/video into an MP4 for decoding. No counter or second local
writer substitutes for the publisher. The generated boundary replaces camera
hardware discovery/delivery and ScreenCaptureKit capture calls with immutable
owned pixels; guest inputs are immutable decoded receipts with original host
PTS. Microphone capture permission requests are denied and generated PCM enters
the actual mixer. Credential/default storage is owned by the fixture, and its
coordinator explicitly declares an unlocked session with system observation off.
Shipping lock admission is unchanged. No personal camera, microphone, display,
Keychain, TCC setting or audio device is changed.

Camera callbacks deliver captured pixels at the current host PTS. Audio keeps
20 ms of delivery headroom with its original independent PTS; received guest
video is selected at its original due PTS by the shipping guest frame store.
The offline decoder is explicitly `AVAudioFile` for PCM plus `AVAssetReader` for
video. This does not claim the separate original `AVAssetReader` PCM/HAL path
passed on this host.

## Historical failure and correction

`ISO_SUSTAINED_BASELINE=1 ISO_SUSTAINED_REGRESSIONS_ONLY=1` compiles the three
camera/audio lifecycle files directly from commit `d413aa1`; the current runner
also selects that commit's source renderer for a complete four-file baseline.
Only owned discovery/default-ID, initial-session and callable-signature adapters
are added to those historical sources. It reproduces both
regressions: a capture opened without its resolved physical ID rebuilds onto a
new default device, and an ISO with a retired associated-audio source fails
while the healthy Program writer finishes. The corrected final-PCM boundary
fixture has Program duration 10.006667 s, associated ISO audio end 1 s, and ISO
video end 10.006667 s. The actual ISO error is `No program audio was written for
ten seconds.` Its receipt and readable partial media are retained.

The correction pins both the capture rebuild and recording demand to the same
resolved physical UID. Keyed holder publication includes that physical UID and
is repeated after retirement during a default/explicit holder handoff, so the
alias cannot retain a stopped same-device holder. An unresolved default cannot
start an identity-pinned recording. A registry retarget applies to the next ISO.

Camera and screen holders expose original capture PTS. Only active Mac ISO
consumers acquire a shared capture-history lease, retaining at most eight
receipts and 96 MiB per holder, measured from actual pixel-buffer bytes.
Captures append receipts independently of renderer polling. A renderer chooses
the latest receipt at or before its requested original source time; it never
stamps future camera/screen pixels into Program's earlier accepted window.
Missing or oversized history becomes a marked black gap. Camera history expires
after 500 ms; static screen frames remain usable. The last lease clears retained
history, and swapping physical holder identity releases the old lease first.
Ordinary Program and iOS capture retain their latest-only ownership.

Each ISO video cursor resolves its original host time through the completed
pause intervals or current interval, rather than always using the newest pause
offset. An unmapped/pruned interval remains explicitly invalid and records black,
including for a legacy timeless screen holder. A resumed guest likewise uses its
original host time instead of the collapsed movie timestamp.

Missing associated PCM is filled with marked silence on the accepted common
clock after 500 ms of delivery grace, at most 4096 frames per pump. Late PCM is
trimmed against the committed cursor. The existing five-second guard on an
incoming audio clock discontinuity remains. The full guest lease still filters
both video and associated audio, so a newly admitted connection in the same
persistent slot cannot replace an old ISO's contents.

## Workload and strict checks

The same binary first proves the camera/default handoff and decodes the
10-second associated-AAC regression with nine seconds of missing input. It then
runs two 60-second workloads at Program 1920×1080/30 plus two 1920×1080/30 ISO
files and one actual RTMP encoder:

- Raw H.264 camera plus processed HEVC guest, followed by processed HEVC camera
  plus processed H.264 static screen. Standard/high quality coexist.
- During the first recording the default changes A→B, the capture rebuilds,
  and the Program source is retargeted to B. ISO A retains A, records a two-second
  black gap and then recovers A. The next recording restores A through the
  default/explicit handoff.
- The old guest is retired at 20 s. A different full lease rejoins the same
  persistent slot at 25 s with visibly and audibly different media. The old ISO
  keeps roughly 40 s of marked black/silence; it never substitutes the rejoin.
- Camera associated audio selects the microphone channel, guest associated
  audio selects the admitted guest channel, and the screen is video-only.
  Expected counts are three camera flash/tone pairs per recording and two
  old-lease guest pairs. Counts must match exactly, then every pair must differ
  by at most 80 ms. Common
  session/origin, duration and audio/video frontier checks remain strict.
- A fifth encoder reservation is rejected without changing the three recording
  reservations or the live publisher. Recording stops release their captures
  and encoder reservations while real network media continues. Final output
  stop releases publishing and all capture demand.
- Actual native diagnostics record process CPU capacity, resident/physical
  footprint and output health at ten-second intervals. Manifests retain the
  real folder probe, drop/gap counts, codecs, source IDs and shared timeline.

The fixture retains all media, source manifests, Program manifests, diagnostics
and `evidence.json`. Every decoded file must have one 1080p video track, the
selected audio-track policy, a common duration within 80 ms, forward timestamps
and no video step of 200 ms or more. Actual network duration must exceed 115 s
with more than 3400 decoded video frames across both independent recording
stops. This is a measured bounded workload, not a zero-loss or indefinite
endurance claim.

## Evidence

The final strict combined run **passed** on Apple M3 Max / Mac15,8 /16 logical
CPUs, macOS27.2(26B118), Xcode27.2(27B5038j). The tested tree `dff65bd` is
identical in its entirety to integrated `9cbe0b9`, including the other reviewed
feedback/capture and compositor scheduling fixes. The native runner exited0,
then its independent FFprobe/resource validator passed. The machine-readable
receipt is [ISOLATED_VIDEO_SUSTAINED_2026-10-22.json](ISOLATED_VIDEO_SUSTAINED_2026-10-22.json).

| Actual file | Frames | Duration | Every expected flash/tone delta |
| --- | ---: | ---: | ---: |
| Raw H.264 camera A |1809|60.270313s|15.77ms, all3pairs|
| Processed HEVC old-lease guest |1809|60.270313s|49.10ms, both2pairs|
| Processed HEVC camera A |1809|60.298521s|13.94ms, all3pairs|
| Processed H.264 screen, video-only |1809|60.298333s|No associated audio selected|

All four ISO files have zero render drops, dropped audio or missing associated
PCM frames. Their source black-frame counts are63/1208/0/1: the controlled
camera gap/rebuild, old guest retirement, and one screen startup frame are
marked honestly. Common origins, audio/video frontiers, source identity,
selected tracks/effects, lease rejoin privacy, fifth-encoder rejection and
independent stop checks passed. Three associated files differ at their decoded
video/audio ends by at most0.313ms.

The actual normal RTMP recording is123.9s with3715 native decoded video frames
(3714 real video packets plus a materialized leading empty-edit pixel) and a76ms
maximum step. It passes the unchanged>115s, >3400frames and<200ms step gates.
Independent packet metadata reports H.2641080p and AAC48k stereo; the real video
track starts66ms after the container origin. The publication remained live
through both recording starts/stops, source failures and resource rejection.

Ten native resource samples measured6.255–7.377% of machine CPU capacity,
177.78–183.80MB resident,378.19–380.72MB physical footprint and17.09MB Metal
allocations. Folder probes measured3.53–4.31GB/s for the bounded8MB fsync probe;
those values are not a sustained disk benchmark.

The final retained log is
`/tmp/stream-wave3-isolated-combined-cadence-sustained-20261022.log`; artifacts are
`media-99bcd1d1-8879-494f-9d81-93b6ccb3980b` below the owned runner build folder,
including `decoded-media.json`, `evidence.json` and `consumer-metadata.json`.
The earlier complete run remains failed and retained as
`media-43c79380-484a-4ff7-83b4-81abb4943eec`: all four ISO files passed, but its
normal RTMP123.9s/3143frames failed the original>3400gate. Actual controlled
source-jitter probes then reproduced duplicate cadence admission in both raw
and shared publishers. The correction and original/fixed hardware/software
media receipts are recorded in
[PUBLISHER_CADENCE_VALIDATION.md](PUBLISHER_CADENCE_VALIDATION.md); no source
PTS, expected cue count or acceptance threshold was relaxed. Earlier failed
runs remain retained. The first supplied camera pixels 20 ms before their PTS,
failed the unchanged 80 ms gate at 83.27 ms, and exposed a stale alias after a
same-device holder handoff. Realistic camera arrival then exposed the separate
ISO latest-frame backdating defect: a later run failed at 81.854 ms, while two
later cues measured 48.521 ms. Independent FFmpeg PCM decode agreed with the
native decoder, and AAC packet timestamps/skip metadata were correct.

The bounded diagnostic records original camera/PCM input, actual post-FX PCM,
pre-writer rendered video and decoded file origins. Source PCM and post-FX PTS
agreed within about 3 microseconds; pre-writer and decoded ISO video agreed
exactly. This identifies source-frame selection as the correction point,
without a constant offset or production PCM retiming. A capture-history
regression supplies an intermediate white frame and another captured frame
before the renderer wakes, proving history is independent of polling. Additional
checks cover future-only history, static screen retention, known/pruned pause
mapping, multiple-lease release, same-identity holder replacement, retired guest
black/silence and exact PCM-grid audio-leading segment rotation.

The fixture uses realistic 30 fps camera/screen delivery and an independent
background 100 Hz PCM producer with unchanged original PTS. This matches native
capture queue independence and avoids coupling PCM delivery to UI/manifest work.
Neither the 80 ms media limit nor the exact expected cue counts are relaxed.

Physical camera/ScreenCaptureKit IO, other Mac classes, removable-volume
behavior, more complex effects and durations beyond the measured workload are
not established by this generated-input fixture. Actual native guest
browser/relay/adapter and shorter Program/ISO media evidence is separately
recorded in [NATIVE_INTERVIEW_PROGRAM_ISO.md](NATIVE_INTERVIEW_PROGRAM_ISO.md).
Existing native source-recording coverage additionally exercises low-storage
partial preservation, pause/segment timing, library manifests and video-only
clip export; this sustained fixture extends that evidence rather than claiming
those separate checks were rerun.
