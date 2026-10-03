# Abrupt recording process recovery

`scripts/run_abrupt_session_recovery_harness.zsh` builds the shipping macOS
Workspace, recovery binding/coordinator, Program writer and Recording Library in
an owned command-line fixture. The parent launches a child instance, waits for
actual H.264/AAC sample acceptance and flushed recorder/recovery journals, and
sends `SIGKILL` only to that live child `Process` PID. The child never calls the
writer's finish API or the clean-exit recovery hook.

The shipping writer already sets `movieFragmentInterval` to two seconds. The
fixture tests whether its finished fragments can actually be decoded after the
process dies, rather than treating a previously finalized movie as crash proof.
A fresh shipping Workspace must offer the saved review, preserve selected
project/profile, Program/staged scene IDs, actual segment/session identity and
timed markers, and remain idle. The owned window hosts the shipping
`SessionRecoveryReviewView`; explicit bound restore and library APIs recover
local geometry/visibility and export a finalized copy. An owned WAV source with
`autoplay=true` additionally proves that its saved 1.25-second position remains
parked after explicit recovery. Shipping labels a newly loaded held player
`.ready`, and a previously playing held player `.paused`; neither may advance.
Read-only generated accessors also inspect the actual public AVPlayer time,
rate and mute state after its asynchronous seek, rather than treating the
status assignment alone as native seek evidence.

Native `AVAssetReader` checks both requested tracks, their start/end agreement
and a decoded white-flash/1 kHz tone cue. The source media and original recorder
journal must remain byte-identical before and after startup, inspection and
export. An unresolved previous review must survive later local checkpoints.
Artifacts, child logs and the interrupted checkpoint remain in the fixture's
ignored build folder, including on failure. An unreadable interrupted file is a
capability failure, never a successful recovery or a reason to delete it.

## Reproduce

```sh
DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer \
STREAM_VENDOR_ROOT=/path/to/owned/clean/Vendor \
ABRUPT_RECOVERY_BUILD_PATH=/tmp/owned-abrupt-recovery-derived \
zsh scripts/run_abrupt_session_recovery_harness.zsh
```

Run from `apple`. `ABRUPT_RECOVERY_DIR` optionally selects a separate generated
project/artifact directory. Builds never activate extensions or modify the
vendor checkout. Each execution creates a fresh catalog, profile, recordings
directory and named preferences suite. Generated validation boundaries disable
Keychain reads/writes and migration (including shared source aliases), provider
network transport and capture-permission acquisition. No physical capture,
monitor, global shortcut or external provider is started. Native source stores,
recovery logic, writer, player and library remain shipping implementations.

The owned review window requires a logged-in WindowServer session; unavailable
presentation returns `77` with `UNQUALIFIED`, not `PASS`. Child readiness is
bounded to 18 seconds, owned child termination to five seconds, media hold
readiness to five seconds, and the entire fixture execution to 60 seconds.

## Evidence and scope

The first qualified native run on Mac15,8 (M3 Max, 16 physical cores), macOS
27.0.1 (26A434), Xcode 26.6 (17F113) recovered a 6.001667-second interrupted MP4
prefix containing 360 decoded video frames and AAC audio. The decoded flash
was at 0.501667 seconds and tone at 0.5 seconds in both the interrupted original
and finalized copy. Its journal still reported `recording`; startup/library
correctly treated the inactive readable file as `recoverable`. The final
expanded run also decoded 360 frames over six seconds, with flash/tone
difference 1.71 ms in both files, and observed the actual restored AVPlayer at
1.25 seconds, rate zero and muted after its asynchronous seek and hold. These
checks prove the default H.264/MP4 path after completed fragments exist. They do not
promise recovery of the currently unwritten tail, arbitrary damaged media,
every codec/container, OS/power loss, physical-volume removal or actual remote
provider state. Remote ended/live classification has separate injected native
ownership/HTTP evidence in `RECOVERY_EVENT_REVIEW.md`.
