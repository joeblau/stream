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

## Published native controls and diagnostics follow-up — 2026-10-22 UTC

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

The following paragraph records the published `40d0737` snapshot before the
final-wave fixes documented below. Its media failures and optional backend
limits are retained as historical evidence, rather than current remaining gates.

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
## Final-wave implementation and acceptance review — 2026-10-22 UTC

This review starts from combined central source `33e9bc9`, published in
`0d79056`. Tasks **#175 and #158 are closed**, and both parent checklists are updated.
Exact paginated GitHub reconciliation of the initial 61 issues verifies
**39 open and 22 closed**, with zero open PRs. Earlier sections retain
their historical source snapshots, failures and test counts. The current
remaining gates below supersede outdated remaining-gate wording in those
snapshots without relabelling a failed run as passing.

| Task | New verified evidence | Current disposition |
| --- | --- | --- |
| #175 external display output | All three original functional criteria pass independent review. An actual external display receives the borderless, non-key video surface with sRGB primaries, black letterboxing and Fit/Fill readback. Actual StreamController/Clean compositor/native-layer tests cover overlay/annotation exclusion, shared 4K30 budgeting and independent teardown. Universal Release at `230c` containing this feature and its bundle audit passed. | **Closed after publication in `0d79056`**; combined source `33e9bc9` passes universal Release and bundle audit, and the parent checklist is reconciled. Physical cable unplug, negotiated AirPlay and broad display/scanout coverage remain disclosed limits; they are not invented additional closure criteria. |
| #158 resilience | Real RTMP recovery preserves healthy SRT/session ownership. Final 22-phase/468-frame decoded source/lifecycle/permission run passes unchanged 40/80 ms limits and five-second independent reset deadline, including exact revoked-source silence. Production observation regression passes actual locked-host initialization and `[A] → [] → [A]`; root native mixer regression and two independent original-criteria reviews pass. | **Closed after publication in `159ea68`.** Final combined source `7cfa9b3` passes universal Release and bundle audit, and the parent checklist is reconciled. Physical OS/TCC/cable/interface delivery remains unmeasured; supplemental lock-marker compatibility is documented. Controlled callbacks/discovery are disclosed rather than presented as physical certification. |
| #107 / #108 keying and LUTs | The actual linear-LUT color-space bug is fixed, including small-table shadow preservation. Seven focused Core tests and actual Metal controls pass. All 48 photographed green-screen motion plates pass measured edge/temporal checks. Reserved combined 1080p30 key/mask/picture/64³ LUT work completes 1,800 frames in 60 seconds with no render-budget or cadence misses. | **Keep open for physical hardware-source qualification.** Representative photographed footage and this sustained render-cost workload are now completed evidence. The bypassed baseline's two budget/five cadence misses remain recorded; this is not all-hardware or long-broadcast capacity proof. |
| #92 performance | Actual AAC priming, startup alignment, software RTMP presentation timestamps and bounded final codec/publisher drains are corrected. Hardware and software shared-media suites pass unchanged limits. Final actual storage-failure/network integration passes all three original 80 ms cues per transport: RTMP 7.500/1.500/5.500 ms and SRT 8.278/1.900/5.522 ms. | **Keep open for representative sustained Apple Silicon/native Intel workloads, thermal evidence and measured encoder/storage/uplink ceilings.** Earlier 82/91 ms media failures are retained and now have a concrete fix with passing media evidence. These small-profile checks do not establish resource ceilings. |
| #125 / #126 / #128 / #129 / #130 interviews | Optional ARM and x86 TCP dependency/backend archives verify minOS 14.0, source hashes and retained-object replacement relinking. Native ARM full Manager/Chrome TCP media and Rosetta x86 control smoke pass; universal packaging preserves matching slices. Independent provenance review found no remaining must-fix. | **Keep open for each issue's remaining browser/network/device acceptance.** Shipping still uses UDP-only transport; the optional TCP backend is not adopted. Declared macOS 14 floors are not old-OS runtime proof; Rosetta is not native Intel full media. TLS, Internet/mobile/Safari and rendered A/V are not established by this optional artifact work. |
| #90 accessibility | Actual native palette/Escape, settings and attached-sheet dismissal restore the exact field editor/owner. Real chat and mixer updates preserve native-search focus. Actual interface fonts/caption geometry grow under the preference at 1024×640. | **Keep open for virtual SwiftUI semantic AX actions/order, virtual fader and panel-removal focus, remaining layout/operator checks and visual contrast.** Locked-session AX exposes no owned semantic window; the normal-render red reference fails before contrast comparison. Source contrast styles and root preferences alone do not qualify visual contrast. |
| #155 portable shows | Final signed sandbox content fixture passes bookmark-only video/pad/playlist/scene-sound/stinger promotion, verified preview/import bytes, private-grant exclusion, original-file removal, actual copied-video decoding and copied/repaired WAV through AVAudioFile. Twelve production-source package tests and five playback lifecycle regressions pass. | **Keep open for native keyboard chooser selection and the full imported/repaired sound-pad AVAssetReader/PCM path.** Chooser attempts cancel; the full pad decoder stalls in host AudioQueue/HAL XPC. The passing content-only mode is explicitly scoped. Signed distribution is not an additional acceptance gate for this task. |
| #124 browser audio | Missing mixer preparation now refuses capture/Resume. The actual helper/WebKit/native PCM suite verifies late registration, synchronous withdrawal, saved gain/Aux/delay restoration, all-bus/ISO silence and retained visual demand. | **Keep production disabled and the issue open.** Signed shared-container IPC, live WebKit attribution/tails, every-route exclusion, fresh live A/V and endurance remain unqualified. |
| #139 / #142 / #143 chat | Actual provider/vault/HTTP and native renderer/recording suites pass queued write cancellation before HTTP, exact historical targets, reader health after outgoing refusal and shared-vault identity pinning. | **Keep open for original authorized live-provider validation.** Controlled responses and owned artwork are not live feed, delivery or moderation evidence. |
| #152 Stream Deck profiles | Bounded supported actions in the installed editor reveal no actual author/export surface through existing public AX grants. All 11 ProfilesV2 files, 12 ProfilesV3 files and eight plugin entries remain byte-identical. | **Keep open for genuine starter-profile exports/imports and remaining target-runtime package/configuration acceptance.** Recipes do not substitute for exports; release signing or physical hardware is not invented as a prerequisite for authoring them. |

Current combined `33e9bc9` compatible Core verification passes **563 tests in
80 suites**, including HostedAudioUnitTests serialization. It excludes exactly
ChannelFXProcessorTests and VoicePolishProcessorTests because of reproduced host
HAL stalls. This is a scoped pass, **not a full-suite pass**; two earlier aborted
runs remain preserved. Log and matching xcresult use
`/tmp/stream-wave2-compatible-core-final-20261022`. Combined shipping source `33e9bc9` also passes unsigned universal Release
for Apple silicon and Intel plus the actual bundle audit. Logs:
`/tmp/stream-wave2-composed-release-20261022.log` and
`/tmp/stream-wave2-composed-bundle-20261022.log`.

The final AAC fixtures explicitly use AVAudioFile for original PCM decoding and
AVAssetReader for video, retaining all original media limits and adding a
stricter 4 ms source pulse/tail check. The original AVAssetReader PCM path remains
host HAL/XPC gated. The separate guest raw-track 105.104 ms failure and normal
rendered PCM/AEC limits under #127 are unchanged by this publishing fix.

The performance workflow is ready for a bounded longer dispatch: its timeout is
90 minutes, native architecture checks are explicit, and five tests verify
owned-process interrupt/termination cleanup. The parent dispatched actual 600-second/workload native ARM and Intel
[run 39713883982](https://github.com/joeblau/stream/actions/runs/39713883982)
at `0d79056`; results remain pending. No sustained PASS is claimed from dispatch.

Hosted CI run [39706795991](https://github.com/joeblau/stream/actions/runs/39706795991)
on exact published `40d0737` completed with iOS success and both macOS jobs
failing at the same headless `NSApp` nil unwrap in
`StudioAutomationEndpoint.swift:61`, after successful harness builds. The guarded
headless-focus fix and the unchanged managed-start harness pass locally. This
is distinct from AAC timing. Later old-run qualifications were skipped; hosted
verification of the integrated fix and the final combined source remains pending.
No old failure is represented as a green hosted run.

Current source/evidence references: [color qualification](research/color-transforms.md),
[shared media](ENCODED_SHARING.md), [storage/network integration](RECORDING_STORAGE_NETWORK.md),
[TCP portability](NATIVE_GUEST_TCP_PORTABILITY.md),
[native controls](STUDIO_CONTROLS.md),
[portable package evidence](PORTABLE_SHOW_NATIVE_ENTRY.md) and the per-issue
records and local report paths in [MACOS_TASK_STATUS.json](MACOS_TASK_STATUS.json).

Final recovery source `7cfa9b3` passes unsigned arm64/x86_64 Release and the
actual bundle audit after composed permission, initial-session/display and
scaled-badge fixes. Root repeats the production observer and full native
guest/mixer permission regressions: PASS. Logs use
`/tmp/stream-wave2-final-scaled-permission-{release,bundle}-20261022.log`,
`/tmp/stream-wave2-combined-observation-20261022.log` and
`/tmp/stream-wave2-root-permission-audio-20261022.log`.
The hosted Stream Deck Plugin run 39713800141 passed on published `0d79056`;
the native CI matrix and sustained performance workflow remain pending.

Final exact GitHub reconciliation closes #175 and #158 against their original
criteria, marks their parent checklists and verifies **39 open / 22 closed**
in the initial inventory, with zero open PRs. The remaining roadmap stays open;
controlled qualification and local builds do not make pending hosted checks green.

## Wave-three integrated fixes and measured gates — 2026-10-22 UTC

Combined source `046c4c9` is published in `4b959de`, after `d413aa1`.
This section supersedes earlier snapshots' remaining-gate wording. Independent
original-criteria review and exact paginated GitHub reconciliation close
**#128 and #129**, check their parent checklist and verify **37 open / 24 closed**
in the initial 61-issue inventory, with zero open PRs.

| Task or scope | Integrated change and actual evidence | Current disposition |
| --- | --- | --- |
| #133 provider accounts | `c85a401` fences delayed Twitch validation against credential refresh/replacement/cancellation. `e78e1f4` adds permitted exact-account Restream relay/key discovery and supported metadata; `0dd847a` adds public Twitch ingest selection and exact-account disabled-draft import. Native account/vault/API/destination fixtures pass; actual public discovery returns 14 Twitch and 19 Restream servers. | **Open.** The accepted Restream public-client OAuth broker boundary is unfinished software, not included in this frozen source. Registered consent and authorized ingest remain unqualified; public server discovery is not a live broadcast. |
| #90 accessibility | `e2a3fbf` reproduces and fixes six stale queued native-focus races across replacement/detach/reattach, moved controls, newer presentations and missing scope. Actual field-editor/current-owner, live fallback, nested bookmarks and production sheet/attachment positives pass. | **Open.** Remaining semantic SwiftUI AX labels/actions/order, virtual fader/panel/operator qualification and visual contrast are unchanged. Native focus ownership does not substitute for a semantic accessibility tree or contrast proof. |
| #155 portable shows | `180169f` adds production audio-only AVAudioFile decoding without AVPlayer/AVAssetReader or an output device. Nine actual strict lifecycle/format/timing/zero-trim cases pass. The final full signed sandbox app passes actual imported and repaired sound-pad PCM plus nonzero Program mix after original removal, alongside video/package/remap/private-exclusion/repair/restart assertions. | **Open only for successful native keyboard chooser selection.** The former full-pad HAL blocker is resolved through the production audio-only path. Actual typed drops and LaunchServices remain distinct from physical Finder gestures; distribution signing is not an extra original acceptance gate. |
| #128 / #129 Backstage and persistent slots | `7083f6a` passes the actual Manager/default native SDK/owned Worker/local UDP TURN/Chrome lifecycle: deliberate second pre-arrival slot, stable camera/screen IDs and bound automatic metadata, SceneStore reload, native decoded OnAir PCM/Backstage exclusion, full-lease rejoin without admission replay, removal/end cleanup and selected relay candidates. | **Closed after publication and independent original-criteria review.** Final universal app/bundle and locally filtered Core verification pass; the parent checklist and exact API inventory are reconciled. Explicit null AudioContext sinks and muted HTML scope this proof to media/control/native PCM. The 133 returned packets with zero HTML decoded samples do not establish normal speaker output/AEC or return-video sync. |
| Owned controller qualifications | `5efd2cf` managed-start, `987c04f` deck/audio/dual-canvas and `8245c3c` external-output generators declare an explicit simulated unlocked session only in their owned controller copies. Managed and external native suites pass; all three deck generators/source registrations and one full native IPC/512-layer/dispatcher suite pass. Production observation still detects the real locked host. | **Fixture correction integrated.** Production session defaults/guards and shared transport helpers are unchanged. Broad deck audio/dual-canvas media graphs were not rerun in this wave; no new HAL/decoder qualification is inferred. |
| #92 performance | Actual hosted ARM workloads each run 600 seconds and achieve approximately 19.5367/20.2333 rendered fps with 7/0 failed renders. `c3fda71` now preserves atomic failure metrics and separates sparse replay-source inventory from nominal capacity, while retaining the original 30fps gate. Focused tests/smoke qualify diagnostics only. | **Open; original ARM sustained qualification failed.** The diagnostic correction is not a performance fix or new 600-second pass. Intel also fails the original video-PTS versus host-arrival-duration gate. Representative mixes/thermal evidence and measured resource ceilings remain unqualified. |
| #171 isolated recording | Original `d413aa1` 10-second regression loses ISO audio while Program completes; the focused local correction passes. A local 2×60-second run retains all four ISO files, no missing camera-handoff frames, camera-A associated PCM cues within 80ms and a healthy RTMP output. | **Open; follow-up not counted integrated.** Strict guest lease-gap decoding finds a processed-ISO offline placeholder. Its factory-only fix and final unchanged 80ms/alias-repeat qualification are pending; partial positives do not supersede that gate. The measured enabled Mac class remains explicit. |
| #152 sample profiles | Current official SDK/CLI/profile/enterprise docs still require app composition/export. New official MCP support triggers configured actions, rather than authoring profiles. The session remains locked, so the known blocked editor/AX mechanism was not retried. All 11 V2/12 V3 profile files, 3,440 plugin file/symlink records and app preference hashes remain unchanged. | **Open.** No genuine stream/record/interview exports were produced. A recipe, unrelated official sample or hand-authored archive is not an imported/editor-validated starter artifact. |

Hosted [CI run 39714685947](https://github.com/joeblau/stream/actions/runs/39714685947)
at exact published `d413aa1` is a terminal failure: **iOS succeeds; ARM and Intel
each pass the full 586-test/82-suite Core run**, then both fail the same generated
`MediaValues.swift` dependency on `ResolvedAssetAccess` in step 10.
`dfa80f6` corrects that exact guest-preparation type-extraction boundary; the
actual local 80-layout preparation suite passes. Later hosted qualifications
were skipped. Local fixture corrections do not relabel this original run green.
These full Core passes supersede the earlier 563/80 AudioHAL-excluded result
only for their exact published source; all historical failures remain recorded.

The actual ARM [600-second workload run 39713883982](https://github.com/joeblau/stream/actions/runs/39713883982)
failed its original nominal gate at published `0d79056`. The original recordings
and diagnostic failure receipt remain preserved in
[PERFORMANCE_HOSTED_ARM_FAILURE_2026-10-22.json](PERFORMANCE_HOSTED_ARM_FAILURE_2026-10-22.json).
Intel is also terminal **FAIL**: its workloads report 10,123/2,209 rendered
frames, then the original 80ms video-PTS versus host-arrival-duration comparison
fails at 59.192148398s divergence. This is not a decoded waveform A/V drift
diagnosis. Both performance jobs failed; no new dispatch occurred. Artifact
upload success, a workflow dispatch and a short smoke are not sustained capacity
passes. The Intel original is retained at
`/tmp/stream-performance-intel119611316368-original.log`.

Final frozen `046c4c9` **passes unsigned universal Release and the actual bundle
audit**, including arm64/x86_64, embedded camera/helper, sandbox declarations,
six App Intents/three entities and no validation hooks. Logs:
`/tmp/stream-wave3-final-account-{release,bundle}-20261022.log`. Its new local
Core run **passes 563 tests/80 suites in 54.667s**, excluding exactly
ChannelFXProcessorTests and VoicePolishProcessorTests for the known host HAL
limitation; `/tmp/stream-wave3-shared-core-20261022.log`. This remains a filtered
pass. The earlier published `d413aa1` full 586/82 hosted ARM/Intel runs precede
the new ingest Core fields; no exact-source equivalence or new full-suite pass
is claimed. Earlier `a5524f2` universal app/bundle also passed. Source publication and
#128/#129 closure are now verified against the API. Optional TLS
positive-control/guard-masking work and the Restream broker remain WIP outside
this frozen source and are not counted as integrated acceptance.

Detailed scoped receipts: [native focus](STUDIO_FOCUS_OWNERSHIP_2026-10-22.json),
[saved slots/Backstage](GUEST_SLOT_BACKSTAGE_2026-10-22.json),
[portable shows](PORTABLE_SHOW_NATIVE_ENTRY.md),
[provider accounts](PROVIDER_ACCOUNTS.md), and the wave-three validation/report
paths in [MACOS_TASK_STATUS.json](MACOS_TASK_STATUS.json).


## Restream broker and optional TLS follow-up — 2026-10-22

`4e32ca6` replaces direct native Restream confidential-secret authorization
with a server Durable Object broker and public native S256/session client.
Both settings panels accept a trusted HTTPS broker URL and expose cancellation;
legacy credentials remain inactive and preserved. Independent review fixed
failed-delete credential restoration, missing cancellation, and a cached-refresh
revocation race. Eight actual workerd tests, strict types, local bundle dry-run,
native authority/storage/controller and account/ingest regressions pass.
`6cf420d` adds worker and native ownership CI coverage. The service is not
deployed/configured, and real consent/chat/ingest acceptance remains open in
#133. See [the broker contract](RESTREAM_AUTH_BROKER.md).

Exact broker source passes unsigned macOS universal Release, actual bundle
audit, a full iOS device-source build, and **563 tests/80 suites in 52.366s**
with exactly the same two local DSP suite exclusions described above. These
are source/build/local-fixture checks, not signed distribution or live OAuth.
Logs: `/tmp/stream-broker-integrated-{mac-release,bundle,ios-device,core}-20261022.log`.

`862ee7d` integrates an explicitly guarded source-built TURN/TLS prototype.
Trusted relay control, certificate rejection and the real socket lifetime
regression pass. Actual incoming camera/Opus is observed, but full returned
browser PCM is still zero despite a verified native host tone and allowed
capture route. **tlsQualified remains false**; SDK/default guards are unchanged.
No issue closes from this prototype. See [the scoped qualification](NATIVE_GUEST_TLS_QUALIFICATION.md).

The earlier published `b28510a` hosted ARM and iOS runs both pass all 586 Core
tests without exclusions. ARM later fails the playback fixture pause-position
assertion at `media_playback_lifecycle_harness.swift:201`; the original log is
retained and the actual clock/position cause is under investigation with
unchanged limits. This is not a whole-CI pass. The original sustained
performance failures and pending strict ISO timing proof remain unchanged.
The verified issue inventory remains **24 closed /37 open**.

Final combined `862ee7d` also passes universal Release and the actual bundle
audit after adding the guarded macOS TLS source. Its shared Core/iOS source
is unchanged from the broker integration proof. No shipping TLS guard or SDK
was adopted.
