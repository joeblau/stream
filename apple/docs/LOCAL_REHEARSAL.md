# Local rehearsal lifecycle

Begin Local Rehearsal reserves the public-publishing guard before preview,
recording countdown, storage preflight or writer preparation starts. Preparing,
Recording, Paused and Stopping all retain that guard. End Local Rehearsal cancels
countdown/preflight or drains the actual recording and its previous segments,
isolated tracks and archive before releasing it. A failed start/finalization
releases only its own rehearsal; an earlier callback cannot release a new one.

Rehearsal starts preview when needed and stops that owned preview after recording
cleanup. A preview already running remains running. Stopping preview manually
does not stop recording. An existing publisher or reserved/active recording
prevents rehearsal from adopting or disturbing that output.

The encoder checklist reports the greater of planned publishing owners and
actual active/finalizing publishing owners, alongside studio-wide recording
reservations. The total studio limit and the user-set publishing budget remain
separate; the budget does not certify hardware capacity.

Run `apple/scripts/run_local_rehearsal_harness.zsh`. It compiles the actual
StreamController, RecordingController, compositor, mixer and Apple writer;
exercises the shipping rehearsal entry point; checks countdown/preparation
cancellation, stale callbacks, pre-existing preview, storage failure, existing
outputs, held failed publisher finalization, reservation accounting, pause/resume,
rotation, finalization and a recording directory relocated during writing; and
decodes the generated H.264/AAC files with AVAssetReader. By default it runs
both the existing 5 ms mixer timing and an explicit 60 ms capture-holdback lease
without changing source PTS or compositor/mixer clocks. The same shipping
pause/rotation/stop sequence writes selected WAV/M4A bus tracks and verifies
actual decoded endpoints, no missing-tail padding and bounded origin rounding.
A pending pause rejects manual/automatic split until actual writer acknowledgment.
`REHEARSAL_AUDIO_HOLDBACK_MS` selects one explicit timing run when diagnosing a
specific route; it does not change production's default audio scheduling.
`REHEARSAL_RESTART_BURST` optionally exercises up to 64 shipping preview
start/stop transitions immediately before the storage-loss recording. It uses
the same owned controller and recording entry point, without altering engine
clocks or gates. If the storage-loss recording fails to start, the fixture logs
its actual state, source video/audio frontiers, progress, output reservations
and error before preserving the original failure. CI retains the rehearsal
media and writer/isolated journals even when the fixture fails.

The runner creates fixture-only copies for the publisher factory, credential
storage and microphone-consent boundary. It never requests capture access,
reads operator credentials, contacts an external provider or changes default
devices. Synthetic local scene pixels and the actual mixer silence clock feed
the real recorder. This verifies rehearsal software ownership, not physical
capture, foreground focus, provider private/test broadcasts or live ingestion.
