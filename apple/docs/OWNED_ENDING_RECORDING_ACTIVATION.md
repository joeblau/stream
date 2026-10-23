# Owned ending: active recording prerequisite and retained evidence

The owned-ending fixture now waits for the actual `ProgramRecordingSession`
`.recording` event before either ending action. That event follows successful
video and audio appends. A locked observer checks that its recording state
remains active before and after remote completion at frame 20 and the independent
local publisher stop at frame 40. Failure remains sticky in the observer.

The first video frame and its five PCM chunks are moved before the existing
five-second readiness helper; they are not additional preroll. The workload
still supplies exactly 60 video frames and 100 audio chunks with the original
timestamps, content and 17 ms pacing. The one-second decode, 60 ms cue alignment,
track-boundary checks, healthy-output assertions and production three-second
final drain deadline are unchanged. No shipping recorder code changes here.

`OWNED_ENDING_MEDIA_DIR` optionally selects a fresh retained directory. Atomic
`mkdir` refuses an existing entry, and this opt-in directory is never removed.
Without the variable, the original UUID temporary directory and deferred removal
remain. CI supplies `apple/build/owned-ending-media` and always uploads that
exact directory. It contains the movie, native writer manifest and a latest-phase
`result.json`, written before the original result/decode assertions. The latter
includes bounded 64 actual recording/paused/failed events and the writer result.
Its observer `active` field is the last event state, not a claim that a completed
writer is still running. Earlier phase checkpoints are overwritten.

The first and only controlled local arm64 macOS 27.2 invocation passed. Actual
Swift 6 compilation used 30 existing runner inputs, `-j2`, and a private copy of
the matching full Core framework, verified against all 76 source hashes. Compile
took 8.689 s; native runtime took 2.266 s under a 120 s limit. Both owned process groups
exited and were reaped without termination signals. The shared build slot was
released. No Core build or original-source rerun occurred.

The native writer accepted 60 video frames and 100 audio chunks with zero drops,
matched one-second frontiers and zero start offsets. The unchanged
`ProgramRecordingFixtures.inspect(expectedDuration:1, checkSync:true)` decoded
60 frames, a flash at 0.5 s and tone at 0.5000416667 s. The actual recording event
arrived 0.151983 s after observer creation. Both ending actions and the healthy
publisher checks passed. The movie and manifest are retained; no second decode
was performed.

Exact commands, source/framework/executable/artifact hashes, native result and
scope are in [the machine receipt](OWNED_ENDING_RECORDING_ACTIVATION_2026-10-22.json).
The controlled provider HTTP, publishers and credentials remain fixture-owned;
the file writer and decoder are actual native implementations. No provider
network, device/audio playback/capture, camera, UI or OS-default change occurred.

The original hosted Intel 80af run 39877849256/job 120172937931 remains failed:
34 accepted video frames, 100 audio chunks, unequal 0.566645833/1.0 s frontiers and
the final drain deadline. Its log and terminal report are bound separately.
This correction establishes the fixture's missing active-recording precondition;
the local pass does not establish the Intel cause or demonstrate its remediation.
The independently proposed terminal-audio EOS correction is absent from this run.
