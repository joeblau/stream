# Stream

For the desktop studio, build the **StreamMac** scheme. See the
[macOS workflow, projects, transfer, and distribution guide](docs/MACOS_STUDIO.md).

**Stream** is an iOS 27+ app that captures the screen and publishes it to RTMP,
RTMPS, SRT, or WHIP endpoints. It uses ScreenCaptureKit for system-managed content
selection and sample delivery; ReplayKit and a broadcast upload extension are not
used.

## Features

- System screen selection through `SCContentSharingPicker`.
- Screen, app-audio, and microphone samples through `SCStream`.
- RTMP/RTMPS publishing with HaishinKit, plus SRT and experimental WHIP support.
- Configurable resolution, bitrate, frame rate, codec, audio mix, and microphone gain.
- H.264 or HEVC encoding with VideoToolbox low-latency rate control.
- Optional facecam composited into the outgoing video.
- Restream unified chat.
- Connection credentials stored in the Keychain.

## Architecture

| Component | Responsibility |
| --- | --- |
| `Stream` | SwiftUI interface, ScreenCaptureKit lifecycle, sample routing, and publishing |
| `StreamCore` | Settings, secure storage, liveness state, and recording utilities |
| `StreamBroadcast` | Process-agnostic publishers, network recovery, and facecam composition; these sources compile into the app target |

`ScreenCaptureController` presents `SCContentSharingPicker`, receives the selected
`SCContentFilter`, creates an `SCStream`, and forwards its screen/audio/microphone
buffers to the selected publisher. Capture and network publishing run in the app
process, as required by ScreenCaptureKit on iOS 27.

## Requirements

- Xcode 27 or newer.
- iOS 27 or newer on a physical device.
- XcodeGen (`brew install xcodegen`).
- An Apple Developer team for device signing.
- Apple's Multitasking Camera Access capability enabled for the Stream App ID so
  the facecam remains active during full-display capture.

The current Xcode 27 beta does not ship ScreenCaptureKit in the iOS Simulator SDK.
The app provides a simulator stub for previews and non-capture UI, but actual
screen capture must be tested on hardware.

## Build

```bash
git submodule update --init --recursive
cd apple
xcodegen generate
xcodebuild \
  -project Stream.xcodeproj \
  -scheme Stream \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Deploy to a paired iPhone

With one paired physical iPhone connected and unlocked, build, install, and
launch the app with:

```bash
bun stream
```

If more than one iPhone is available, select one explicitly with
`STREAM_DEVICE_ID=<UDID> bun stream`.

## Configure a stream

Open Settings and choose the transport:

- RTMPS: for example `rtmps://live.restream.io/live`, plus its stream key.
- RTMP: for example `rtmp://live.restream.io/live`, plus its stream key.
- SRT: enter the full SRT URL, including stream ID or passphrase query values.
- WHIP: enter the HTTPS WHIP endpoint and optional bearer token.

The URL and key are stored per protocol. The record button remains available when
configuration is incomplete, but capture will not start until the selected
transport is publishable.

## Start and stop

Tap the `record.circle` toolbar button. The app presents Apple's
`SCContentSharingPicker` for full-display selection. After selection, the button
changes to `stop.circle`; tap it to stop both `SCStream` and the network publisher.

The picker exposes microphone control. App-audio inclusion and microphone gain are
configured in Settings.

## Facecam

ScreenCaptureKit's system camera effect only supports current-application capture.
Stream captures the full display, so it retains its own low-resolution camera input
and composites that frame into the selected corner before encoding. The app uses
Apple's Multitasking Camera Access entitlement to keep that camera session active
after full-display sharing moves Stream into the background. If the installed
provisioning profile does not grant the capability, Settings reports that the
signed build cannot keep the facecam active.

## Codec selection

The Video settings offer H.264 (default) or HEVC. HEVC gives roughly a 40%
quality-per-bit gain on text-heavy screen content in the 2–8 Mbps band, but needs
a compatible ingest: it rides SRT (MPEG-TS) and *enhanced*-RTMP (the
publisher advertises the `hvc1` FourCC in the E-RTMP connect command). Traditional
RTMP services such as Restream and the current WHIP transport speak H.264 only, so
leave the codec on H.264 for them — HEVC over RTMP should be verified against the
specific endpoint on a real device. Low-latency VideoToolbox rate control is enabled
for both codecs.

## Notes

- ScreenCaptureKit is device-only in the current Xcode 27 beta SDK.
- Local backup remains disabled because it requires a second video encoder.
- WHIP should be validated on hardware because its WebRTC stack has a larger
  memory footprint than RTMP or SRT.
- The output resolution locks to the first captured frame's aspect ratio. Start
  capture in the orientation intended for the stream.

## License

See the repository license.

### Destination management and preflight

The Destinations inspector and embedded connection settings share a native draft editor. Create, name, duplicate or remove RTMP, RTMPS, SRT caller and experimental WHIP destinations; select the program canvas or an independent output size/frame rate, codec, bitrate and enabled state. Apply Destinations saves metadata in the active desktop project and connection credentials in machine Keychain accounts addressed by stable UUID. Duplicates start disabled. Legacy per-protocol credentials migrate once, preserving the iOS slots. Endpoint URLs (including query tokens), stream keys and SRT passphrases never enter project JSON.

Each destination has its own acknowledged connection state and Start/Stop/Retry actions. Bounded video/audio ingress prevents a stalled endpoint from holding up other endpoints or recording. Public Go Live starts enabled destinations, supports partial success, and caps sessions at ten subject to tested uplink/session budgets. The current publisher backend uses one encoder per destination; the plan identifies compatible profiles but does **not** claim actual encoded-media sharing. HEVC on RTMP requires an explicitly verified enhanced ingest; WHIP is H.264/Opus and currently cannot set a bearer Authorization header.

Preflight checks required permissions, program source availability, recently audible program audio, local credential completeness, canvas/ingest constraints, recording storage, tested encoder budgets and uplink headroom. Its explicit upload test sends up to 32 MiB of synthetic data to [Cloudflare's documented speed-test endpoint](https://github.com/cloudflare/speedtest#configuration), lasts about ten seconds and can be canceled. It estimates that route rather than provider ingest acceptance. Local Rehearsal starts preview and local recording and blocks publisher allocation until it ends. Provider-private/test broadcasts are not configured by this version; Public Go Live and individual destination Start publish to their configured endpoints.

Run the deterministic controller/media isolation harness with:

```sh
zsh apple/scripts/run_destinations_harness.zsh
```

It injects fake publishers into the shipping destination controller, verifies isolated failure/reconnection/stop/retry and rejection of obsolete lifecycle events, saturates one video mailbox while the healthy endpoint advances, checks the ten-session boundary, and verifies that rehearsal disallows public publisher allocation. StreamCore tests additionally cover credential redaction and migration, protocol fields, encoder compatibility, profile isolation, explicit ingest limits, resource estimates, checklist evaluation and upload cancellation/deadlines. These tests do not claim acceptance by a real provider ingest.


### Desktop session resilience

The destination manager includes project-scoped Session Resilience and Source Failover controls. Offline cards are the default visual source fallback. Freeze retains one buffer per demanded source; blank removes the source's pixels; standby video substitutes a configured camera, screen, media, PDF, web or Syphon source and uses an offline card when that standby is unavailable. A configured standby scene changes the program snapshot without changing saved scenes or unpublished preview edits. Standby captures are warmed while the pipeline runs, so budget their capture resources. Source substitution retains the existing mixer routing; standby scenes update scene-bound audio. Reported capture errors, permission loss and missing hardware trigger immediately; fresh-frame startup failures allow two seconds. Recovery is latched until Restore Recovered Sources / Program unless automatic source restoration is explicitly enabled. Output publishers retain their own reconnect/backoff supervision, and a source fallback never restarts healthy publishers. Manual Take supersedes automatic standby restoration.

Screen lock or an inactive user session stops outputs by default. The opt-in alternative keeps existing sessions on a silent offline slate until explicit restoration; Take cannot bypass that privacy hold. Sleep always requests publisher stop and recorder flushing immediately. `NSWorkspace.willSleepNotification` cannot guarantee completion of an asynchronous writer drain before the OS suspends the process: use explicit Stop before sleep when finalization is required, and inspect fragmented-recording recovery after interrupted sleep. Wake and unlock refresh source availability and never create publishing or recording sessions. Optional wake behavior resumes preview only. Distributed macOS lock notifications supplement public workspace session notifications; both use the same conservative policy.

Validated on Mac15,8, macOS 27.0.1 (26A434): the native injected harness exercised two acknowledged destination sessions, one saturated video queue with 100 frames, independent transport failure/retry, source-health/freeze isolation, duplicate lock/sleep events, silent-slate continuation, sleep stopping, manual-only output restart, opt-in preview wake and corrupt-policy preservation. Four StreamCore tests cover grace timing, immediate device-error fallback, manual/automatic restoration, stale-frame suppression for all modes, failed-standby fallback and bounded frame retention. This deterministic evidence does not claim a physical unplug, permission-revocation or provider ingest test; reproduce those manually with two configured destinations and observe that the healthy session remains LIVE while only the affected source uses its selected fallback.

### Clean output on external displays

The Destinations inspector includes External Display Output: select a system-visible external display, clean program video or a saved destination canvas, and fit/letterbox or fill/crop framing. A borderless, mouse-transparent, non-key AppKit window contains only video; all production controls stay in the studio. Built-in screens and the display hosting the studio are excluded. AirPlay works when macOS exposes it as a separate desktop display: enable the separate/extended display through [macOS Displays settings](https://support.apple.com/en-gb/guide/mac-help/mchlb5f905a1/mac), then refresh the picker. Enumeration follows [NSScreen](https://developer.apple.com/documentation/appkit/nsscreen); Stream does not connect to an AirPlay receiver directly.

This is an independent program subscriber, with a capacity-one compositor queue and one pending presentation image. Conversion runs off-main in sRGB; selecting a destination canvas aspect-fits program pixels onto an opaque black canvas, capped at 4096 pixels per dimension / 60 fps. Presentation uses the main common-mode run loop at the lower of source and display rates, skips missed ticks, and displays the newest image. Display rearrangement updates the window frame without a resubscription; disconnect, studio relocation onto the output display, sleep or studio close stops the feed. Reconnection never starts it automatically. Stopping this optional surface leaves publishing and recording untouched. It produces no encoded file or audio track.

Run the native controller/surface/conversion harness with:

```sh
zsh apple/scripts/run_external_display_harness.zsh
```

Validated on Mac15,8, macOS 27.0.1 (26A434) using injected display topology: start/stop, AirPlay-style availability, a 100-image saturated mailbox, late callbacks after disconnect, rearrangement, manual reconnect, studio-display exclusion, portrait canvas selection, allocation/subscription/size failure cleanup, fit/fill layer framing, borderless video-only window flags, actual sRGB conversion, opaque letterboxing and unchanged source PTS. No external display or AirPlay receiver was attached for this run, so physical presentation latency, display color calibration and receiver reliability remain hardware validation tasks.

### Session recovery after interruption

Session Recovery in the main transport bar offers prior-run context for explicit review. Machine-local `SessionRecovery/current.v1.json` and `pending.v1.json` retain project/profile IDs, program and staged scene IDs, staged layer geometry/visibility/order and registered source references, active publishing UUIDs, paused media/page positions, and actual recording session/segment IDs, basenames and marker seconds. They exclude endpoints, keys, headers, bookmarks, paths, raw scene payloads, marker titles and command history. The selected recorder folder's real journals provide segment context; missing/unreadable inventory stays unverified. Writer I/O is serialized off media paths, burst edits coalesce into one newest snapshot, files are atomic and capped at 1 MiB, and an unresolved prior review survives a second interruption. Late prior-runtime checkpoints cannot replace the selected project/profile.

Restore Local Context selects/validates the matching project/profile through the workspace, restores available saved scenes and staged numeric edits, and seeks local media while holding autoplay until a new operator Play/Restart. Missing scene/layer/media references require project backup review or relinking. New/deleted layers, source payload edits, text and effects cannot be reconstructed from this deliberately narrow journal. Recording Library inspects actual tracks and can export a finalized copy of recoverable media; recovery never overwrites an original recording. Public streams, recording, cues, macros and destructive commands never auto-start or replay. Provider event APIs are unavailable: local acknowledged connection IDs are known, but remote ended/reconnectable status and event IDs remain unknown unless a future provider integration supplies verified facts.

Run `zsh apple/scripts/run_session_recovery_harness.zsh`. On Mac15,8/macOS 27.0.1 (26A434), the shipping native coordinator/store and actual recording-journal reader passed interrupted and second-restart tests, explicit-only restoration, 100-edit burst coalescing, selected-context isolation, conservative recording shutdown, corrupt-document preservation, exact segment/marker identity and timing, credential/title/path redaction, selected-profile inventory and directory-grant lifetime. Five StreamCore tests cover schema limits, duplicate IDs, redaction, review policy, unknown versus ended/reconnectable states and delayed-load autoplay suppression. This injected evidence does not claim a killed GUI-process recovery, physical disk loss or real provider event recovery.

Workspace integration owns one `SessionRecoveryCoordinator(directory:)` under machine storage and rebuilds `SessionRecoveryRuntimeBinding` with every runtime. The binding consumes `recorder.$state.map { $0.isActive }` and a retained `recorder.libraryAccess()` grant through `SessionRecordingJournalReader.read`. Inject `.environment(\.sessionRecovery, recovery)` in the main window; wire explicit restore/project selection and Recording Library review callbacks. Normal termination awaits recorder drain, `binding.refreshRecordings()`, and `recovery.finishCurrentSession()` before replying to termination. An asynchronous `willTerminate` callback alone cannot guarantee journal completion.

### Guided manual service destinations

Add Destination → Guided Service or Relay offers Instagram Live Producer, Amazon Live Creator, X Producer, TikTok LIVE when external ingest is actually granted, Restream, Switchboard and OneStream Live. Native setup displays dated official evidence, account/access requirements, key lifecycle, orientation, provider event controls and encoder limits. Confirm granted ingest access to create a disabled draft, then paste issued credentials into the existing ID-based Keychain editor. Generic RTMP/RTMPS/SRT/WHIP setup remains available. No provider login, browser scraping, key extraction or downstream broadcast automation occurs.

Guides do not grant account access or establish encoder acceptance. Missing current eligibility/expiry/orientation evidence is explicit, and old Instagram/Amazon setup documents are labeled archived. Comments, viewer metrics, scheduling and remote event state are unavailable in Stream for these manual guides. Relay LIVE state acknowledges only the relay ingest, not each downstream channel. WHIP requires a complete authorized URL; bearer headers and separate WHIP keys are unsupported. Instagram/Restream's recommended 44.1 kHz audio differs from Stream's current 48 kHz output and requires an actual test event. See [official-source review and validation limits](docs/research/guided-destinations.md).
