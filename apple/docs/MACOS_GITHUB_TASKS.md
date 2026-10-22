# macOS GitHub task audit — 2026-10-21

This is the historical review imported from `main` at `07d2fdb`, before its integration with `work/macos-completion-20261021`. Its implementation gaps and test counts describe that earlier source snapshot. For the combined branch, use [MACOS_TASK_STATUS.json](MACOS_TASK_STATUS.json) and [MACOS_STUDIO.md](MACOS_STUDIO.md). In particular, native guest receive/return/talkback, browser Program-lease routing, static Twitch emote tiles and show scheduling were subsequently integrated; live service, production browser-audio enablement and normal guest-playback A/V qualification remain open. The combined raw-track A/V run failed its unchanged 100ms gate and is not superseded by an earlier passing fixture.

The open GitHub inventory contained **61 macOS issues: 48 implementation tasks and 13 roadmap/epic trackers**. Twelve subagents worked concurrently across the workstreams below, followed by independent cross-review and integration. This records the initial implementation pass and subsequent acceptance review; it does not claim that the entire roadmap is complete. Unmet acceptance criteria remain open.

## Acceptance review for integration

The follow-up review uses each issue's original acceptance criteria and validation instructions. Optional release qualification must remain visible without becoming a new requirement for every software task. The workstream inventory below includes both unfinished functionality and broader release checks; they are distinguished here.

The reviewed implementation supports closure after publication and successful integration checks for:

- **#94:** reproducible macOS/iOS CI, sandbox/IPC/permission/embedded-bundle audits, and documented Developer ID/notarization/update/uninstall policy. Producing a notarized artifact is separate from the issue's requirement to choose/document that distribution path.
- **#132:** destination limits and explicit overrides, exact fixed-profile encoder sharing/separation, aggregate owner accounting, and independently validated local RTMP/SRT media behavior.
- **#135:** per-output health and supported fresh viewer/link receipts, distinct local disconnect versus remote completion, coordinated one/all ending, partial outcomes and independent actual recording.
- **#146 and #151:** supported first-party Stream Deck package/pairing and authoritative multi-instance lifecycle; input/monitor dials, scene/overlay/sound browsing, touch feedback and reconnect handling through the pinned SDK.
- **#159:** bounded secret-free session journals, explicit restore/relink/finalize and supported fresh ended/live/unknown review, without automatic public output or destructive replay. Unsupported media/provider cases remain explicit.
- **#170:** capability-gated manual provider/relay guides with current-account/key/orientation disclosures and unavailable-API labels. This does not assert universal provider ingest eligibility.
- **#180:** six discoverable foreground App Intents in the built app, shared explicit-target commands, structured errors, permission/profile checks and named studio readiness/focus handling.
- **#87 and #178:** the secondary-aware preflight correction must also pass its shipping-controller regression before closure. The checklist now uses both demanded layouts' sources, actual secondary profile, taken-layout availability and combined compositor budget.

Physical controller/display/device acceptance, live provider consent/ingest, signed installation and sustained resource qualification remain documented limits rather than implied test passes. Other tasks with genuinely missing features or explicitly required unperformed validation remain open. Existing draft/failing PRs and active integration worktrees are not declared merged by this review.

## Implemented changes and remaining acceptance

| Workstream | GitHub tasks | Implemented or corrected in this working tree | Remaining acceptance |
| --- | --- | --- | --- |
| Automation and shortcuts | [#88](https://github.com/joeblau/stream/issues/88), [#180](https://github.com/joeblau/stream/issues/180) | Named studio focus/reopen, foreground readiness, live interaction gates, imported shortcut validation, global input routing, and shared rundown commands. | Native guest production commands, installed Shortcuts discovery/cold launch, and other-app global shortcut qualification. |
| Stream Deck | [#146](https://github.com/joeblau/stream/issues/146), [#147](https://github.com/joeblau/stream/issues/147), [#148](https://github.com/joeblau/stream/issues/148), [#149](https://github.com/joeblau/stream/issues/149), [#150](https://github.com/joeblau/stream/issues/150), [#151](https://github.com/joeblau/stream/issues/151), [#152](https://github.com/joeblau/stream/issues/152) | Overlay dial selection/tally, recording countdown IPC/feedback, unavailable resource labels, inspector edit retention, binding validation and packaged plugin. | Signed app/helper/device pairing, physical Plus checks, scene/destination/provider bindings, camera selection, additional sound transport modes, guest/profile/audience actions and exported sample profiles. |
| Remote interviews | [#125](https://github.com/joeblau/stream/issues/125), [#126](https://github.com/joeblau/stream/issues/126), [#127](https://github.com/joeblau/stream/issues/127), [#128](https://github.com/joeblau/stream/issues/128), [#129](https://github.com/joeblau/stream/issues/129), [#130](https://github.com/joeblau/stream/issues/130) | Transactional browser capture replacement and recovery; project-persisted preparation slots, editable layouts and automatic local names. | Native guest connection/admission/media integration, mix-minus/program returns, backstage/talkback, independent remote screen-share reception, deployed TURN and browser/network qualification. |
| Providers and scheduling | [#133](https://github.com/joeblau/stream/issues/133), [#134](https://github.com/joeblau/stream/issues/134), [#135](https://github.com/joeblau/stream/issues/135), [#169](https://github.com/joeblau/stream/issues/169), [#170](https://github.com/joeblau/stream/issues/170) | Receipt freshness, exact-event metric validation and account/credential-generation fencing for late responses. | Authorized live provider OAuth/ingest/event/end validation and Facebook/LinkedIn application approval/API connectors; manual fallback remains explicitly limited. |
| Chat and audience | [#139](https://github.com/joeblau/stream/issues/139), [#142](https://github.com/joeblau/stream/issues/142), [#143](https://github.com/joeblau/stream/issues/143) | Explicit audience refresh, per-provider freshness/availability, reconnect-safe cancellation, public-event styling and staged text alert promotion. | Authorized live read/send/moderation/count validation, image emotes/sticker media and supported reaction/monetization feeds. |
| Virtual devices | [#172](https://github.com/joeblau/stream/issues/172), [#173](https://github.com/joeblau/stream/issues/173), [#174](https://github.com/joeblau/stream/issues/174) | Atomic camera format negotiation and stale-frame rejection; source-built camera and universal HAL prototype fixtures. | Signed activation/update/removal, real receiving-app camera acceptance, installed microphone capture and a validated distributable shipping microphone path. |
| Professional SDK adapters | [#160](https://github.com/joeblau/stream/issues/160), [#161](https://github.com/joeblau/stream/issues/161), [#167](https://github.com/joeblau/stream/issues/167), [#168](https://github.com/joeblau/stream/issues/168), [#176](https://github.com/joeblau/stream/issues/176), [#177](https://github.com/joeblau/stream/issues/177) | Read-only NDI/DeckLink/Zoom prerequisite detection with version, architecture, SHA-256, symbol and explicit-path checks. | Actual SDK/runtime availability, implemented native vendor media bridges, compatible hardware/SDK access, redistribution decisions, participant consent and measured media operation. |
| Recording | [#93](https://github.com/joeblau/stream/issues/93), [#171](https://github.com/joeblau/stream/issues/171) | Preserved simultaneous storage/media warnings and surfaced journal-write failures while actual synchronized recording continues. | Physical removable-volume failures with concurrent publication, native guest ISO integration and sustained per-Mac encoder/storage/source-count budgets. |
| Resilience and recovery | [#158](https://github.com/joeblau/stream/issues/158), [#159](https://github.com/joeblau/stream/issues/159) | In-flight frame retirement fences without periodic-refresh drops, independent corrupt-checkpoint review and incomplete recording inventory labeling. | Physical device/TCC/session/power lifecycle qualification, real external-media restoration and authorized provider recovery review. |
| Preflight and canvases | [#87](https://github.com/joeblau/stream/issues/87), [#132](https://github.com/joeblau/stream/issues/132), [#175](https://github.com/joeblau/stream/issues/175), [#178](https://github.com/joeblau/stream/issues/178) | Overflow-safe resource arithmetic and finite bitrate/uplink/ingest validation; native external-display controller/converter checks. | Live provider/uplink qualification, physical display/AirPlay behavior, signed consumer outputs and sustained full-resolution dual-canvas/session capacity. |
| Native quality and effects | [#90](https://github.com/joeblau/stream/issues/90), [#91](https://github.com/joeblau/stream/issues/91), [#92](https://github.com/joeblau/stream/issues/92), [#107](https://github.com/joeblau/stream/issues/107), [#108](https://github.com/joeblau/stream/issues/108) | Bounded redacted diagnostics, accurate unavailable/zero telemetry, accessible effect units/labels and current-target asynchronous LUT/color bindings. | VoiceOver/keyboard operator flows, representative physical key/LUT footage, graceful degradation under real output load and sustained Apple Silicon/Intel measurements. |
| Projects and distribution | [#94](https://github.com/joeblau/stream/issues/94), [#155](https://github.com/joeblau/stream/issues/155) | Folder-media packages, explicit missing-media failures, bounded/regular-file manifests, typed guest token remapping and actual signed-entitlement/runtime audit support. | Native Finder/drop/relink and persistent sandbox grants; matching app/extension/helper profiles, signed export, notarization, Gatekeeper and extension lifecycle qualification. |

Browser-widget audio [#124](https://github.com/joeblau/stream/issues/124) received a follow-up audit: the helper/protocol/capture foundation exists, while production per-widget audio remains gated by real process/capture isolation, program/preview routing and signed IPC qualification. Its production selector must remain unavailable until those gates pass.

## Integration validation

Initial macOS StreamCore suite: **563 tests in 80 suites passed**. The expanded suite passed **573 tests in 80 suites**. The complete unsigned StreamMac app and embedded camera/helper built, and the iOS Simulator shared-test target built for testing. Earlier baseline measurements in other documents are not fresh qualification from this run.

- Native loopback local-control fixture passed, including authoritative recording countdown snapshots, authenticated clients, reconnect/no replay and adapter revocation.
- Actual program writer fixture passed synchronized H.264/AAC and HEVC/PCM, pause/rotation, recoverable storage and simultaneous journal/storage/drop warnings.
- Source-built camera and universal microphone prototype fixtures passed; no device was installed or activated.
- Native provider/chat/preflight/display/automation/diagnostic/package fixtures cover injected failure paths; they do not establish live service or physical-device acceptance.
- Stream Deck TypeScript/tests/helper build, official Elgato validation/package and native dispatcher fixture passed.
- Actual native workspace fixture passed project/profile replacement, failed-switch fallback, shell detach/reattach, folder/LUT transfer and explicit unavailable-media errors.
- Guest preparation fixture passed legacy documents, stable independent camera/screen IDs, project isolation, all 50 layout/count combinations and malformed-document rejection. Twenty-two browser client tests and the actual headless Chrome loopback WebRTC lifecycle fixture passed; native interview media remains unimplemented in this branch.
- New CI steps exercise diagnostics export, signed-metadata audit fixtures, SDK prerequisite detection, guest preparation and native controller feedback.
- Final source verification: unsigned StreamMac build passed after the last provider, guest-decoder and portable-token changes; all six PortableShow tests passed against the final source. Actual native keyboard/palette/rundown/window-readiness fixture passed after allowing AppKit's asynchronous focus transition. The unsigned built-bundle declaration audit and CI YAML parsing passed; whitespace checks were clean.

Reproduce from the repository root after generating the Xcode project:

```sh
cd apple
xcodegen generate
xcodebuild test -project Stream.xcodeproj -scheme StreamCoreTests -destination 'platform=macOS' -derivedDataPath build/mac CODE_SIGNING_ALLOWED=NO -skipPackagePluginValidation
xcodebuild build -project Stream.xcodeproj -scheme StreamMac -destination 'platform=macOS' -derivedDataPath build/mac CODE_SIGNING_ALLOWED=NO -skipPackagePluginValidation
python3 scripts/validate_desktop_distribution.py build/mac/Build/Products/Debug/StreamMac.app
STREAM_CORE_FRAMEWORK_DIR="$PWD/build/mac/Build/Products/Debug" zsh scripts/run_guest_preparation_harness.zsh
zsh scripts/run_studio_workspace_harness.zsh
zsh scripts/run_local_shortcut_harness.zsh
zsh scripts/run_studio_diagnostics_harness.zsh
python3 scripts/test_desktop_distribution.py
zsh scripts/run_pro_input_prerequisites.zsh --test
```

The complete shared suite above will include the final additional portable-token regression, beyond the earlier 573-test run. No signing submission, device installation, live broadcast, commit, push, pull request or GitHub issue mutation was performed.

## Unfinished local engineering

The roadmap also contains unfinished software, beyond external qualification. Native guest transport/admission/returns/talkback and production browser-widget audio routing are not integrated. NDI/DeckLink/Zoom require actual native media bridges. Provider event CRUD is incomplete outside the implemented YouTube path. Stream Deck still lacks several destination/camera/sound/profile/guest/audience command families and genuine exported sample profiles; the profile instructions are not exported profiles. Graphical emote/sticker/reaction feeds and measured GPU/perceptual A/V drift diagnostics remain incomplete. The workstream table must not be read as all tasks being blocked only by hardware or credentials.

## Roadmap and epic tracking

- [#47 — [macOS] Desktop studio roadmap: Ecamm-inspired production in one window](https://github.com/joeblau/stream/issues/47): remains open until its child-task acceptance and integration gates are satisfied.
- [#48 — [macOS][EP01] One-window workspace and media foundations](https://github.com/joeblau/stream/issues/48): remains open until its child-task acceptance and integration gates are satisfied.
- [#50 — [macOS][EP03] Desktop, camera, phone, and professional inputs](https://github.com/joeblau/stream/issues/50): remains open until its child-task acceptance and integration gates are satisfied.
- [#51 — [macOS][EP04] Camera effects, keying, framing, and PTZ](https://github.com/joeblau/stream/issues/51): remains open until its child-task acceptance and integration gates are satisfied.
- [#52 — [macOS][EP05] Graphics, titles, presentations, and web overlays](https://github.com/joeblau/stream/issues/52): remains open until its child-task acceptance and integration gates are satisfied.
- [#53 — [macOS][EP06] Audio mixer, media playback, soundboard, and effects](https://github.com/joeblau/stream/issues/53): remains open until its child-task acceptance and integration gates are satisfied.
- [#54 — [macOS][EP07] Remote interviews and Zoom production](https://github.com/joeblau/stream/issues/54): remains open until its child-task acceptance and integration gates are satisfied.
- [#55 — [macOS][EP08] Destinations, multistreaming, and scheduling](https://github.com/joeblau/stream/issues/55): remains open until its child-task acceptance and integration gates are satisfied.
- [#56 — [macOS][EP09] Recording, virtual devices, and program outputs](https://github.com/joeblau/stream/issues/56): remains open until its child-task acceptance and integration gates are satisfied.
- [#57 — [macOS][EP10] Audience chat, comments, reactions, and moderation](https://github.com/joeblau/stream/issues/57): remains open until its child-task acceptance and integration gates are satisfied.
- [#58 — [macOS][EP11] Elgato Stream Deck plugin and automation controls](https://github.com/joeblau/stream/issues/58): remains open until its child-task acceptance and integration gates are satisfied.
- [#59 — [macOS][EP12] Projects, profiles, assets, and native workflows](https://github.com/joeblau/stream/issues/59): remains open until its child-task acceptance and integration gates are satisfied.
- [#60 — [macOS][EP13] Diagnostics, resilience, performance, and release readiness](https://github.com/joeblau/stream/issues/60): remains open until its child-task acceptance and integration gates are satisfied.

## Concrete external prerequisites

The local SDK probe found no NDI runtime/SDK, DeckLink runtime/SDK or Zoom Meeting SDK. The installed Zoom application is not the Meeting SDK. These tasks also need real media bridge implementations; a prerequisite diagnostic cannot substitute for one. A Developer ID certificate exists, but matching StreamMac/camera/helper provisioning profiles were not found. The read-only HAL probe did not find an installed Stream virtual microphone. No driver installation, extension activation, system-default changes, credential updates, signing submissions, public broadcasts or GitHub issue edits were performed.

## Native controls and diagnostics follow-up — 2026-10-22 UTC

A further wave used up to ten concurrent subagents, independent acceptance
review and combined validation. Original issue criteria for #91 and #147–#150
are implemented and verified closed after source publication. The
current GitHub reconciliation is recorded separately in MACOS_TASK_STATUS.json.

- StreamCore passed 584 tests in 82 suites. Its production and test trees remain
  identical to that tested snapshot after the later macOS-only integration.
- The combined unsigned Release app, browser helper and camera extension build
  for arm64 and x86_64. Bundle checks retain all six App Intents, three entities,
  sandbox declarations and the absence of transport validation hooks. The
  optional libnice backend is absent from the shipping executable.
- Combined native dispatcher/IPC checks passed exact scene/destination/event
  controls, 512 complete destination receipts, separate 256-layer Preview and
  Program receipts, real localhost RTMP acknowledgement/decoding, recording
  countdown cancellation and two independently finalized recording segments.
- All 28 combined controller/SDK tests and 21 actual Worker tests pass. A clean
  Node 24.15 install enforces engines and peer dependencies; Worker types now
  match pinned Wrangler. Official Elgato validation/packaging passes.
- Actual media PCM validates sound transport, gain/mute, native/AU bypass,
  staged isolation, PDF/markers and decoder retirement. The original audio
  sample timing grid/duration/DTS is preserved. Actor-side insert identity and
  revision checks reject stale add/remove/prune operations.
- Diagnostics distinguish timestamp offset, observed rate skew and uncertain
  delivery. Actual default RTMP/SRT media remains healthy through recorder
  storage failure. Failed publishers stop their live timers. Resource and
  clock exports are bounded and redacted.

The actual Chrome inspector and reference host/guest WebRTC flows also pass.
The browser protocol double now models host-only roster generations and exact
membership targets, including replacement-generation readmission; its earlier
stale fixture failure is retained in the local validation logs.

Genuine sample Stream Deck profile exports and remaining package/device
qualification keep #152 open. The two quiet 120-second owned workloads improve
#92 evidence without qualifying representative physical capture, Intel or
resource ceilings. Shared encoded publishing still fails its independent 80 ms
media gate; its correctly uncertain callback telemetry does not repair that
media result. The guest HTML player clock-reset fix and successful raw-track
matrices do not resolve the retained 105.104 ms failure or establish normal
rendered PCM/AEC qualification for #127. Optional TCP TURN qualifies only its
owned newer-macOS backend; the shipping UDP-only backend and unsupported TLS
remain explicit. See STUDIO_DIAGNOSTICS.md, DECK_AUDIO_MEDIA_VALIDATION.md,
DESKTOP_RESOURCE_BUDGETS.md, GUEST_RETURN_AV_ORACLES.md and
NATIVE_GUEST_TCP_QUALIFICATION.md for evidence and reproducible boundaries.
