# Program recording and storage policy

The macOS recorder writes an independent H.264/AAC MP4 from the composition
engine and 48 kHz stereo program bus. It uses the current output frame rate and
the engines' common host-clock timestamps. A static source does not gate the
composition engine's output ticks. Recording demand keeps composition and audio
running when the on-screen preview is stopped.

The transport shows Preparing until both audio and video have actually been
accepted by AVAssetWriter, Recording while writing, and Stopping while draining
and finalizing. Encoder/open/append/finalization errors appear in the main
window. Start, stop, failure, and finalization release only recording's taps and
pipeline demand; no recording error calls the network publisher's stop method.

Each tap feeds a bounded mailbox directly: at most 30 video frames/128 MB and 128 audio chunks
by default. The writer runs on one private serial queue. It orders the available
media by timestamp, rejects invalid/backward timestamps, and counts each track's
loss. A slow encoder cannot build an unbounded queue of dispatch blocks. The
first video frame is retained during encoder warmup to preserve the track's
start time. Overload can create gaps; the studio warns rather than claiming an
undamaged recording.

Recordings use unique names in the App Group's Recordings folder. The initial
free-space guard requires 1 GB. Once per second the writer checks the backing
volume's available capacity and write progress. It warns below 1 GB, stops local
recording below 100 MB, warns after three seconds without accepted media, and
fails after ten seconds. Missing/unmounted storage becomes a visible local
failure. Video and audio statuses, errors, counts, start offsets, source clock
origin, and warnings are journaled separately in `<file>.recording.json`.

The MP4 writer creates two-second movie fragments. A normal stop drains for up
to three seconds and finalizes the container. A normal Quit waits for
finalization, with a 15-second upper bound if storage/encoding is stuck. The
recorder never deletes an incomplete or failed recording:

- `complete`: the writer finished and accepted both program tracks; a legacy
  `.complete` marker is also written for the existing recordings importer.
- `recoverable`: recording failed, but its accepted audio/video were successfully
  finalized into a readable container. The original failure remains in the
  journal and UI.
- `partial`: media is missing or the writer could not finish. Finished fragments
  may still be readable. Arbitrary corrupt containers and lost volume contents
  cannot be promised recoverable.
- An interrupted journal can still say `preparing`, `recording`, or `finishing`.
  It records the last successful heartbeat, not evidence that a killed process
  still owns the file. Inspect the retained file before using it.

## Native qualification

Run `apple/scripts/run_program_recording_harness.zsh`. It compiles the actual
writer with Swift 6 strict concurrency and the macOS 14 baseline, then writes and
decodes media with AVAssetWriter/AVAssetReader. No generated reference media or
mock encoder substitutes for the Apple frameworks.

Qualified locally on MacBook Pro Mac15,8, Apple M3 Max, macOS 27.0.1 (26A434),
Xcode 27.2 beta:

- Three-second, 60 fps H.264/AAC: 180 decoded static frames, both tracks start at
  zero, durations agree, and a simultaneous video flash/audio tone decodes
  within 0.06 seconds (observed difference 0.0000417 seconds).
- Injected low capacity: visible error, preserved finalized partial audio/video,
  recoverable journal, and source producer tasks continue independently.
- Fast overload: both mailboxes stay bounded and both track drop counts rise.
- Removed-volume probe/no-media: visible storage failure and explicit cleanup.
- Actual AVAssetWriter open failure on an existing path: visible error and
  existing file contents retained.
- Full StreamMac unsigned native build passes.

The injected storage probes make failures reproducible; they do not replace a
physical external-drive unplug or a simultaneous network-stream workload test.
Those, sudden process termination/container recovery, other Mac/OS encoders,
and sustained high-resolution load remain release qualification work.

## Recording options and file changes

The transport's Recording Options popover selects MP4/MOV, H.264/HEVC, standard
or high quality, file prefix, a security-scoped destination folder, optional
record-only countdown, and duration/size splitting. Recording always uses an
independent encoder at the active program canvas size/frame rate; sharing the
network encoder is not supported. Selected-folder bookmarks are local machine
preferences and are not silently replaced when a volume disappears.

Recording presets, naming, countdown, splits, auto-record, and isolated-source
choices live in `recording-preferences.json` in the active profile directory.
The app shell calls `recorder.loadPreferences(directory:)` on profile activation.
Old machine presets migrate into the first profile once; later profiles start
with defaults. The native controller harness verifies migration, independent
profiles, and persistence when switching back. Changing a profile cannot
rewrite the preferences or context captured by an active recording.

Auto-record on Go Live is opt-in and starts without the record-only countdown.
A failed network connection does not stop its recording. Pause removes the same
source-clock interval from both tracks; the journal retains the omitted gap.
New File and automatic size/duration rotation atomically swap the writer behind
the existing taps. The previous file finishes independently, so composition,
audio demand, and networking continue. Only one previous segment can finish at
once; another split waits for it. Byte thresholds are checked on the one-second
health heartbeat using fresh filesystem attributes; sizes may exceed the
threshold by in-flight fragment/encoder buffers and that interval.

Additional native qualification covers a two-second resumed recording after a
one-second pause, actual MOV/HEVC output, and two gap-free MP4 segments containing
every source frame/audio chunk. `run_recording_controller_harness.zsh` uses the
actual app controller and writer, with a hardware-independent tap source, to
verify countdown cancellation, writer preparation, pause/resume, manual split,
source-clock duration split, actual byte-triggered split, and storage preflight.
The duration test deliberately advances source timestamps rather than waiting
a minute. Its unrelated-consumer counter proves the controller leaves the tap
source running; simultaneous provider-network publication still needs release
qualification.

## Recording library and handoff

The main transport's library popover groups files by session and scopes them to
current project/profile metadata, with an All profiles view. The app shell sets
`recorder.context` with project/profile IDs and display names; each recording
snapshots it at start, so later profile changes cannot relabel existing files.
The library reads actual media tracks, duration, size, and thumbnails. Readable
orphans are recoverable; unreadable files remain partial. Files still owned by a
current/finishing writer cannot be exported.

Add Marker records the accepted local media time, including valid paused time.
Markers remain in the recording journal and export as JSON, quoted CSV, or text.
An inline player, Finder reveal, explicit native sharing/editor picker, and a
trim range are available on readable recordings. Clip export uses Apple's
highest-quality supported MP4/MOV preset, validates the range, and preserves the
original. It requires a new output name. Native picker/share/editor interactions
remain manual UI qualification; no sharing or editor is invoked automatically.

`run_recording_library_harness.zsh` verifies actual generated media metadata and
thumbnails, project/profile context, complete/recoverable/partial/active status,
marker timing and all export formats, and a decoded 0.8-second H.264/AAC clip
(48 frames, flash/tone difference 0.0000417 seconds). Invalid ranges and attempts
to overwrite the source fail visibly. These checks pass on the named local Mac.

The recorder's `progress` additionally exposes wall elapsed time, shared source
origin, each accepted track's ending media time, and their endpoint difference.
The endpoint difference measures current write alignment; it is not an estimate
of hardware clock drift. The journal retains per-track starting offsets and
source-clock pause gaps for downstream reconciliation.

## Isolated audio tracks

Recording Options selects up to eight channel/bus taps, each as 48 kHz stereo
Float32 WAV or AAC M4A. Microphone/device, guest, media/soundboard, screen-audio,
app/system-audio channels and program/monitor/aux buses use stable source or
channel IDs. Selecting a pooled audio source holds its capture demand for the
recording; stopping/rotating releases only the recorder's subscriptions. Channel
taps can capture before or after the app's insert chain; both precede fader,
mute, and ducking. Capture-level OS processing is already in the input and
cannot be undone. Bus taps contain their mixed bus processing.

WebKit widgets currently have no independent audio tap. Their explicit System
Mix route can be recorded through that system channel or a mixed bus. The
popover states this limitation; it does not offer an artificial web channel
that would silently record no widget audio.

Each isolated writer has its own serial file queue and bounded 128-chunk
mailbox. It waits for the program's common origin, pause offset, and accepted
ending media time, pads timeline gaps with counted silence, and finalizes with
the program segment. It cannot write beyond the program's accepted window.
Source underrun windows, shed chunks, start offset, processing/format/name/ID,
profile context, and per-track errors are written to `<file>.isolated.json`.
The program journal links all selected isolated files, including failed tracks.
Missing targets remain failed through segment rotation. A failing isolated
writer closes and preserves its partial file without stopping program encoding
or unrelated audio consumers. A clock jump over five seconds fails that track
instead of performing an unbounded silence write. Gap journals retain up to
10,000 coalesced windows and count later omitted events explicitly.

The library inspects actual WAV/M4A media and isolated journals, groups them with
their program session/profile, displays source/processing/gap/error metadata,
and exports audio ranges to a new AAC M4A. Missing/unreadable files remain
partial; readable failed tracks remain recoverable. Active and finishing
isolated files cannot be exported.

`run_isolated_recording_harness.zsh` exercises the actual AudioMixEngine insert
and pre/post taps, AVAudioFile WAV/AAC writers, and the actual program writer.
The only source stand-ins are opaque capture identities and timestamped PCM/
video fixtures; it acquires no screen/microphone permissions. Native checks on
the named local Mac include:

- Intended 4x insert attenuation decodes at approximately 4x RMS in pre-WAV and
  post-M4A; decoded onset difference is 0.000125 seconds. Program flash/tone
  difference is 0.000167 seconds, with one common session origin and duration.
- A disconnected source produces over 40,000 counted missing frames while the
  program and another bus consumer continue advancing.
- Injected isolated low capacity preserves a playable partial WAV; an actual
  existing-file collision preserves its original bytes. Healthy isolated and
  H.264/AAC program files still finalize.
- Overload counts shed chunks and aligned silence, while three seconds of
  supplied isolated data cannot extend the accepted two-second program window.
- The actual controller harness verifies WAV/M4A duration alignment through
  pause/resume/manual rotation and a missing target's independent failure.

Pass an isolated harness output directory as the optional argument to
`run_recording_library_harness.zsh` to also qualify real isolated media/context/
gap inspection and a trimmed AAC audio export. Native device/guest disconnects,
physical volume removal, sudden-kill recovery of each audio format, sustained
eight-track workloads, and native picker/editor handoff remain release checks.

Completed program writers release AVAssetWriter and both inputs before invoking
finish callbacks, even if a client retains the finished session. Local encoder
failure logs include NSError domain/code chains only; exported diagnostics do
not gain arbitrary error userInfo or recording paths.

## Isolated camera and screen video

Recording Options can select two camera/screen source IDs independently of the
program scene, with separate 720p/1080p, 15/30 fps, H.264/HEVC, quality, source
processing, and optional channel/bus audio association. Choices persist in the
active profile. No Source Effects records scaled, unmirrored capture pixels;
Source Effects applies that registry source's current defaults and camera
orientation. Layer transforms, scene overlays, annotations, and transitions
are excluded. OS capture processing already present in pixels cannot be undone.

Each source resolves through CaptureSourcePool's normalized physical identity
and strict SourceFrameProviders keyed lookup. An unavailable source records
marked black frames; it never falls back to an unrelated default camera/screen.
A static screen holder remains recordable. Source subscriptions retain capture
demand through all segment finalization, then release only recorder demand.
Physical source identity is snapshotted when recording starts; retargeting a
registry source applies to the next recording. Guest video capture is not yet
implemented: the UI disables it with that reason, and an existing guest
selection fails visibly without substituting another source or stopping the
program recording.

The app budgets program + active publisher + isolated encoder sessions before
start and write-tests the selected folder using an exclusive 8 MB temporary
file plus fsync. Required measured throughput is twice the estimated program,
isolated video, and isolated audio writes. The test file is removed afterward.
This establishes start headroom; it does not qualify sustained or removable
storage. Go Live/add-destination preflight honors
`maximumPublishingEncodersWhileRecording` through a runtime-owned recorder binding.
The native controller fixture verifies rejection before any publisher starts.

| Measured Mac class | Program maximum | Isolated maximum | Total native encoders |
| --- | --- | --- | --- |
| Apple M3 Max, Mac15,8, 16 CPUs | 1080p30 | Two 1080p30 camera/screen sources | Four including program and publishers |
| Other models/variants, including Intel | Awaiting native qualification | Start is rejected with the detected class | No inferred limit |

Each isolated source owns its serial render queue and independent Apple writer:
six video frames/48 MB and 128 associated-audio chunks maximum. Every segment
gets a fresh renderer and writer. It follows the program's accepted shared host
origin, pause offset, and ending time; audio cannot extend that window. Missing
source, source render overload/backpressure, and associated-audio underrun/gap
windows are journaled separately in `<file>.video-isolated.json`, with source
profile/ID/name, audio association, session/segment/project/profile metadata,
start offset, budget measurements, counts, and per-source failure. Journals
retain 10,000 coalesced gap windows and count later omitted events. Backpressure
can produce a counted black gap or a held-frame timeline gap; the app warns.
A failing source writer closes and preserves its partial media while other
writers and program/network consumers continue. Completed tracks release their
native encoder and renderer pixel pools even while the session retains status.

`run_isolated_video_harness.zsh` builds actual StreamMac source/renderer/writer
code and uses native generated camera/screen holders without hardware capture
permissions. On the named Mac, macOS 27.0.1, Xcode 27.2 beta, repeated seven-second
four-encoder 1080p30 workloads pass for H.264 standard and HEVC high. The extra
program consumer in this fixture is an independent native file writer; it does
not establish concurrent RTMP/SRT/WHIP network-publisher qualification. The fixture
uses a refreshed camera with a flash, a deliberately static screen, and an
unrelated bright default camera. Decoded checks verify exact source identity,
unmirrored/no-effect pixels, +0.2 source brightness, black disconnect/recovery,
optional AAC presence/video-only absence, common origin/duration and profile
metadata. Flash/tone differences are 0.0000417–0.0000625 seconds. The final pair
had six H.264 and one HEVC source startup/render gaps per source, explicitly
counted; a later complete pair counted two H.264 and one HEVC source gaps per
source. This is not a zero-loss or endurance claim.

The fragmented writers disable frame reordering. Earlier variable-host-PTS
runs intermittently rejected media at append/finalization with native error
codes, including -11800/-16341. Repeated runs passed after this setting; copying
shared PCM did not resolve the failures and was removed. The observed mitigation
does not identify a private OSStatus meaning. Native camera/screen permissions,
device/guest adapters, complex processed effects, long workloads, physical
volume removal/sudden kill, mixed codecs, and other Mac classes remain release
qualification. The source harness also passes shared pause/segment timing,
independent low-storage playable partial preservation, library session/gap/error
inspection, active-file export guards, and decoded video-only range export.

The program harness reports every supplied sample as written or counted dropped
and retains actual duration, decoded A/V sync, bounded overload, and partial
recovery checks. Its initial flash/tone occurs at two seconds after warmup.
Local runs additionally require zero dropped samples; hosted CI VMs exercise
portable writer contracts and report loss without claiming physical-Mac cadence.
`STREAM_RECORDING_REQUIRE_REALTIME=1` enforces the cadence requirement everywhere
(`0` explicitly disables it); the wrapper defaults to `0` only when `CI=true`.
