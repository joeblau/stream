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
