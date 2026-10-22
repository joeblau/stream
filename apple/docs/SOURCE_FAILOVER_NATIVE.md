# Native source failover qualification

Run from the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer \
STREAM_VENDOR_ROOT=/path/to/clean/Vendor \
FAILOVER_NATIVE_BUILD_PATH=/tmp/owned-failover-derived \
zsh apple/scripts/run_source_failover_native_harness.zsh
```

The runner generates an isolated full shipping desktop graph, builds it, and
limits its own child to 60 seconds. It preserves the H.264/AAC Program file,
writer journal, original-host frame receipts and decoded pixel receipts under
`apple/build/source-failover-native-validation/artifacts-<UUID>`. Derived data and
downloaded transport repairs belong to that run; the external vendor is read
only. Credentials use memory fixtures, defaults and storage use owned temporary
locations, microphone/permission requests are denied, and provider requests are
rejected. No operator files, accounts, capture devices or TCC settings are used.

Three owned screen producers deliver immutable buffers to the actual keyed
source holders. Audio enters the shipping `CaptureSourcePool.onScreenAudioSample`
callback with its original host PTS. Only permission-bearing producer startup is
replaced. Shipping source health, grace, failure latching, capture demand,
`ResilientSourceFrames`, renderer, compositor, mixer, recording controller and
writer run unchanged. Read-only observations expose cache size and pipeline
ownership without changing policy.

The fixture requires live and decoded pixels for freeze, blank, the visible
offline card, a healthy configured standby source, unavailable/unknown standby
fallback and explicit restoration. An independently healthy animated source
must keep advancing. It then exercises the actual controller's configured
standby scene, manual return to Program, private lock slate and continued
recording. Both private-slate windows must decode to silence. Controlled sleep
must finalize the real writer, release encoder/capture/render demand and clear
retained failed frames. Wake remains idle unless preview is enabled; that opt-in
starts preview alone. Actual profile replacement must retire the old runtime.

Wake and unlock are ordered gates: a wake received while locked refreshes no
sources and starts no preview. The opted-in preview waits for unlock. Unlock
before wake keeps capture retired until wake, and duplicate wake/unlock signals
do not repeat either action. A lock delivered after sleep does not rebuild a
slate or repeat output teardown. These cases matter because public workspace
and distributed lock notifications can overlap or arrive in either order.

The 2026-10-22 requalification on Mac15,8 / M3 Max, macOS 27.2 (26B118),
Xcode 27.2 (27B5038j), passes the actual owned-source recording fixture with
the new locked-wake/duplicate-signal assertions, all original fourteen painted
windows, nine PCM cases and unchanged strict track endpoint checks. The native
destination-controller harness also covers reverse unlock-before-wake ordering,
late lock while asleep, and unchanged publisher allocation. Running its new
assertions against the original coordinator reproduces the unwanted unmatched
wake source refresh. Controlled notifications qualify callback behavior; they
do not establish physical OS notification delivery or TCC revocation behavior.

Measured phases use observed painted-frame host timestamps rather than intent
timestamps. Live receipts require monotonic original timestamps and sequence;
decoded media must contain both real tracks and retain the strict 40 ms start /
80 ms end checks. This is a source-routing qualification, so the generic
flash/tone cue comparison is disabled: the independent color and constant-tone
producers deliberately have different content cues.

The test exposed a local mixer registration defect: gain published before a
screen source's first PCM was ignored by automatic registration and after a
ring reset. The before run produced 62,464 actual Program scalars at RMS zero
with capture gain 0.4. The registry now retains declared local effective gains
through registration and resets. Program binding changes also revoke declared
capture gains whose source has not delivered yet or whose ring was reset/pruned.
The cache-only candidate exposed that latent-source leak at RMS 0.07886; the
fixed late callback must be silent. Nine native PCM checks cover first arrival,
nonunity gain, mute persistence, resets, pruning, removed bindings and a truly
unbound silent capture.
Guest gains continue to require the full receive lease and explicit routing.

Local qualification: Mac15,8 / Apple M3 Max, macOS 27.0.1 (26A434), Xcode 26.6
(17F113). The final failover file decoded 310 frames over 10.33348 seconds; all 14
painted windows and their Program audio policies passed, with both private
windows at RMS zero. The existing native guest PCM harness separately checks
that leased admission and Program/Monitor/pre/post isolated privacy remain intact.

Physical screen/camera capture, display unplug, permission revocation, actual OS
lock/sleep/wake notifications and Internet/provider recovery remain separate
gates. Calling the shipping lifecycle coordinator with controlled events proves
its owned callbacks and resume policy, not delivery of real hardware/OS events.
Independent publisher reconnect acceptance is covered by its separate endpoint
recovery fixture. These source results alone do not close issue #158.

`--permission-transitions` adds controlled permission-authority transitions to
the same recorder/source graph. ScreenCaptureKit discovery is replaced only at
the OS boundary; real pending screen/app-audio requests must stay retired across
deny/regrant. The actual permission probe separately runs with controlled
preflight/discovery results. Explicit SCK-domain user-declined is distinguished
from transient errors, missing display lists and a matching code in an unrelated
domain. Confirmed denials survive stale preflight until a successful re-probe;
older completions cannot overwrite a newer result.

The additional seven media phases keep the original recording session and
clock: microphone grant/denial/regrant with healthy video, screen denial with
an independently healthy microphone, both permissions denied while callbacks
continue, regrant that holds the offline pixels, and explicit Program restore.
The same decoded RMS tone/silence bounds apply to every phase. Browser helper
audio, media and guest authority remain independent from microphone and
Screen Recording permission gates. Optional VoicePolish is disabled in this
owned routing workload; its DSP qualification is separate.

If the host's AVAssetReader AAC decode is unavailable, explicitly add
`--external-decoder`. The native child must still finalize the real file,
retire captures/runtime and write original-host receipts. Its output says
**PENDING DECODE** until a second bounded offline FFmpeg process validates the
actual H.264 pixels and 48 kHz stereo PCM. This decoder retains the exact
original 40 ms track-start / 80 ms track-duration limits, painted-frame and
independent-animation assertions, and per-phase sample-count/RMS thresholds.
It checks decoded frame/sample counts against FFprobe timestamps and writes
`external-decoder-summary.json`, decoded frame receipts and the actual PCM
file. The default AVAssetReader path remains available. This mode changes no
audio device or system audio service.

The 2026-10-22 permission run on the named Mac15,8/M3 Max host passes all
21 actual decoded windows, 448 frames over 14.933458 seconds. Video/audio
starts are both zero; durations are 14.933333/14.933458 seconds. Microphone
grant/regrant RMS is 0.09715/0.09393. Screen denial retains the independently
healthy microphone at RMS 0.09358, while microphone denial and both-denied
windows decode to exact zero despite continuing callbacks. All original
fourteen source/privacy windows and thresholds also pass. The sanitized
[measured receipt](PERMISSION_RESILIENCE_2026-10-22.json) records every phase.
The actual guest admission, queued-revocation, isolated-ring and guest-return
regression harnesses also pass with the new independent permission authority.

Two prior attempts retained explicit failure receipts: the original mic test
called its inlet on MainActor with optional VoicePolish enabled; the corrected
source run then finalized successfully but AVAssetReader's AAC decoder blocked
inside an AudioQueue/HAL device call. Neither is reported as a decoded media
pass. The successful run selects `--external-decoder` and owned off-main PCM,
with the optional effect disabled. No global audio reset or device mutation
was used to obtain a result.
