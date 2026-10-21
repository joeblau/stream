# Recovery, storage and output qualification

## 2026-10-21 local run

These checks ran on a MacBook Pro Mac15,8 / Apple M3 Max, 16 physical cores,
macOS 27.2 (26B118), Xcode 27.1. Each fixture used its owned media, temporary
storage and injected credential/provider/capture boundaries where documented.
The clean external vendor checkout was read-only. No provider account or public
stream was used. Passing the software checks does not close the physical and
service qualification gates listed below.

| Task | Actual local evidence | Remaining qualification |
| --- | --- | --- |
| #93 storage and interrupted recordings | Entire native Program writer suite passes, including zero-drop 60 fps recording/rotation, H.264/AAC and HEVC/MOV decode, preserved low-space partial media, absent-volume probe and actual writer-open failure without deleting existing bytes. A real blocked journal path now warns during continued recording; repairing the path clears the warning and produces 144 decoded frames / 2.4 seconds with synchronized audio. | Physical external-volume removal, sustained high-resolution/storage workloads and more Mac/OS combinations. |
| #155 portable shows | Signed sandbox app passes actual hot/cold LaunchServices delivery, typed file drop, explicit import/Apply, scene/asset ID remapping, copied LUT bytes, private configuration redaction, real file grant/asset repair, app-scope bookmark across normal Quit/restart, multi-package rejection and unchanged package bytes. | Actual NSOpenPanel keyboard attempt canceled and is explicitly UNQUALIFIED; physical Finder double-click/pointer drag and release signing/notarization remain separate. |
| #132 destination profiles/shared encoders | Both hardware-preference and explicit software VideoToolbox RTMP loss/replacement recovery retain one encoder and an unchanged live SRT session. Each SRT file contains 392 continuous decoded frames over 15.68 seconds; all receiver files pass decode/sync checks and both outputs acknowledge stop. Both full sharing suites also pass compressed object/byte/PTS identity, GOP/IDR overflow isolation, distinct profile/canvas failures, stop/rejoin, finalizing reservations, safe preference persistence, unsupported-rate fallback and actual 60→24 fps sampling (48 decoded frames / 2 seconds). | RTMPS/TLS, authorized provider/profile acceptance, sustained resource usage and additional Mac/OS classes. |
| #158 source and transport recovery | Source fixture passes all fourteen live/decoded routing phases, nine first-PCM/reset/prune gain checks, healthy independent animation, source/scene standby, explicit restore, exact-silence private slates, real writer finalization on controlled sleep and bounded runtime/cache retirement. Its Program decodes 307 frames / 10.435 seconds. Actual loopback RTMP loss/replacement recovers while SRT remains continuously live and decodable. | Physical capture/device/display removal, TCC revocation, real lock/sleep/wake delivery, Internet route changes and authorized provider ingest. |
| #159 safe restart recovery | Actual owned SIGKILL leaves a readable six-second H.264/AAC prefix: 360 decoded frames, flash/tone difference 1.67 ms. Fresh shipping Workspace review restores stable local geometry and the actual AVPlayer held at 1.25 seconds/rate zero/muted despite autoplay. Library classification/export, original/journal hashes and unresolved-review retention pass. Separate session/event/account fixtures pass immutable bindings, atomic restart, explicit fresh GET ownership verification, ended/live/unknown classification, generation fencing and no automatic output restart. | Unwritten tails, arbitrary damaged containers, whole-system/power loss, other codec/container combinations, external scoped media and authorized live-provider restart. |
| #171 isolated camera/screen/guest video | Four actual 1080p30 encoders pass H.264/standard and HEVC/high workloads, each about seven seconds, with 211 decoded camera frames, 30 marked missing-source frames and zero source/encoder drops. Raw/processed pixels, associated audio, independent storage failure, library/export, pause/rotation and the 1.003-second shared PCM cut pass. The short owned-folder write probe measured 4506 MB/s. | The qualified production gate remains the named M3 Max class and its existing maximum of two selected ISO sources/four total encoders at up to 1080p30. This short fixture does not qualify sustained writes, physical camera/screen sources, volume removal or other Macs. Native guest evidence is tracked separately. |
| #178 dual canvases | Actual GPU wide/portrait pixels differ while retaining identical tick PTS. Independent AAC/H.264 files decode 32 frames / 1.10998 seconds and 39 frames / 1.33998 seconds. Native dispatcher staging/Undo, remapping, atomic encoder rejection, canceled preflight, shared PDF pages, independent output disconnect/stop and privacy on both canvases pass. | Sustained full-resolution dual rendering, live portrait ingest and physical clean/virtual consumers. |
| #175 external display output | Actual borderless non-key AppKit surface, fit/fill layers, sRGB conversion, letterboxing, preserved source PTS and native run-loop presentation pass. Injected AirPlay-style topology verifies rearrangement, unplug/manual restart, studio-display exclusion, independent stop, bounded mailbox and stale callback rejection. | Physical external display/AirPlay availability, unplug/rearrangement, color and sustained presentation pacing. |

## Reproduce

Run from the repository root with `DEVELOPER_DIR` selecting Xcode and
`STREAM_VENDOR_ROOT` selecting an owned clean vendor root containing
`HaishinKit.swift` and `Syphon`:

```sh
zsh apple/scripts/run_program_recording_harness.zsh
zsh apple/scripts/run_recording_controller_harness.zsh
zsh apple/scripts/run_source_failover_native_harness.zsh
zsh apple/scripts/run_abrupt_session_recovery_harness.zsh
zsh apple/scripts/run_session_recovery_harness.zsh
zsh apple/scripts/run_recovery_event_review_harness.zsh
zsh apple/scripts/run_recovery_accounts_harness.zsh
zsh apple/scripts/run_portable_show_native_harness.zsh
zsh apple/scripts/run_external_display_harness.zsh
zsh apple/scripts/run_isolated_video_harness.zsh
zsh apple/scripts/run_studio_dual_canvas_harness.zsh
zsh apple/scripts/run_shared_encoder_harness.zsh
zsh apple/scripts/run_shared_encoder_harness.zsh --transport-recovery-only
zsh apple/scripts/run_shared_encoder_harness.zsh --transport-recovery-only --software
```

For this run, the small session/event/account/external-display Swift executables
were compiled from exactly the shipping files and harness source lists in those
runners, linked against the StreamCore framework already built by the native
source fixture. This avoids repeating unrelated Xcode/package builds; the
native application/controller/media implementations and assertions are unchanged.
The full Program writer, recording-controller, source, abrupt, sandbox package,
isolated-video, paired-canvas and transport fixtures ran their actual
media/filesystem/native boundaries. The older session/event/account/external
wrapper scripts require initialized local vendor submodules; this run used the
already-built clean-vendor StreamCore products for their Swift compile steps.

The receiver must advertise actual RTMP and SRT protocols. `ffmpeg-full` is
available through its own Homebrew keg without relinking the user's existing
`ffmpeg`. `STREAM_FFMPEG_BIN` can select the exact receiver; the minimal local
FFmpeg 9.0.2 exits qualification with status 77 because it lacks SRT. A missing
receiver never qualifies transport recovery. `--receiver-check-only` validates
this prerequisite before any listener starts; readiness polling uses a monotonic
wall-clock deadline.

Details and explicit fixture limits are recorded in
[Program recording](../PROGRAM_RECORDING.md),
[abrupt recovery](ABRUPT_RECORDING_RECOVERY.md),
[portable entry](PORTABLE_SHOW_NATIVE_ENTRY.md),
[source failover](SOURCE_FAILOVER_NATIVE.md),
[remote review](RECOVERY_EVENT_REVIEW.md),
[transport recovery](TRANSPORT_RECOVERY_QUALIFICATION.md),
[fixed encoder sharing](ENCODED_SHARING.md) and
[dual canvases](DUAL_CANVASES.md).
