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
and sustained high-resolution load remain release qualification work. Isolated
source-track recording and a recording library are separate output features.

## Recording options and file changes

The transport's Recording Options popover selects MP4/MOV, H.264/HEVC, standard
or high quality, file prefix, a security-scoped destination folder, optional
record-only countdown, and duration/size splitting. Recording always uses an
independent encoder at the active program canvas size/frame rate; sharing the
network encoder is not supported. Selected-folder bookmarks are local machine
preferences and are not silently replaced when a volume disappears.

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
