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

The strict native run on Apple M3 Max / Mac15,8 / 16 logical CPUs, macOS27.2
(26B118), Xcode27.2 (27B5038j), produced all four ISO files at1809 frames each
with zero render drops, dropped audio or missing associated audio frames.
The two recording durations were60.268746s and60.299083s. All three expected
camera cue pairs measured16.42ms in the first recording and14.88ms in the
second; both expected old-lease guest pairs measured49.75ms. All are below the
unchanged80ms limit. Common origins, audio/video frontiers, controlled camera
gaps/recovery, old-lease black/silence, holder handoff, selected tracks/effects,
resource rejection and independent stop checks passed. Independent FFprobe
metadata validation also passed.

**The complete combined workload remains failed.** Its actual RTMP file was
123.9s /3143 video frames with a68ms maximum video step. It stayed live with
zero mailbox/congestion drops, but failed the unchanged requirement of more
than3400 frames. Target FPS remained30 and the compositor reported no missed
deadlines. The normal publisher's SDK timestamp-admission path is under
investigation; this receipt does not certify the sustained publishing cadence
or close issue171. No failing gate is removed.

Ten native health samples measured4.004–7.3468% of machine CPU capacity,
177.49–194.49MB resident,353.75–395.43MB physical footprint and17.09–41.11MB
Metal allocations. The manifest folder probes measured3.70–4.59GB/s for their
bounded8MB fsync probe; those values are not a sustained disk benchmark.

The retained run log is
`/tmp/stream-wave3-isolated-final-capture-sustained-20261022.log`; artifacts are
`media-43c79380-484a-4ff7-83b4-81abb4943eec` below the owned runner build folder,
including `decoded-media.json`, `evidence.json` and `consumer-metadata.json`.
Earlier failed runs remain retained. The first supplied camera pixels 20 ms before their PTS,
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
