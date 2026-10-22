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


## Playback CI fixture correction — 2026-10-22

`7898737` changes only the playback fixture and its generated clock boundary.
Controlled scheduler starvation reproduced both the original pause-range and
loop-reset failures while actual playback followed the measured host clock.
The exact elapsed time in the failed hosted job remains unknown. The correction
preserves the original **0.39...0.49** pause range and exact **0.3** loop reset
under controlled time, and adds separate measured real-host pause/PCM/PTS/end
checks. Normal and deliberately delayed runs pass all ten cases; independent
review and the parent integrated runner pass. Production playback is unchanged.
Parent log: `/tmp/stream-wave4-root-media-lifecycle-20261022.log`. Fresh hosted
CI remains required.

Exact published `a346f56` iOS now passes all586 Core tests/82 suites in180.802s;
the broker and browser interview workflows also pass. These results do not
claim the whole desktop CI succeeds. The pending ISO branch now passes all
four decoded files at the unchanged80ms gate, with exact cue counts, identities,
marked black/silence and common origins/frontiers. Its complete workload still
fails the separate RTMP frame count:3143 over123.9s versus the unchanged>3400
requirement, despite continuous media and68ms maximum frame spacing. That
production publisher discrepancy is under investigation. #171 remains open;
the verified inventory remains **24 closed /37 open**.


## Combined native completion follow-up — 2026-10-22

Frozen source `9cbe0b9` passes unsigned universal macOS Release, actual bundle
audit, a full iOS source build, and **563 Core tests/80 suites in 52.689s**.
Exactly the two previously documented local DSP suites remain excluded; this is
not a local full-suite claim. Earlier exact `a346f56` hosted ARM, Intel and iOS
each pass all **586 tests/82 suites**; both desktop jobs then fail the same old
playback fixture pause assertion, corrected here without loosening its bounds.
A fresh hosted run is still required.

The complete ISO test uses an identical source tree (`9cbe0b9`/`dff65bd`) and
passes both 60-second four-encoder workloads. All four ISO files contain1809
frames, correct source identity/effects/audio policy, common origins/frontiers,
marked disconnect gaps and no recording render/audio drops. Maximum planned
flash/tone error is49.104167ms against the unchanged80ms gate. Actual RTMP
remains continuous for123.9s with3714 compressed packets (nativeReader3715
includes a leading edit-gap pixel) and76ms maximum frame spacing; the original
>3400 gate passes. The fixed raw and shared publisher paths preserve input
PTS and intentional profile/thermal frame-rate limits. Sourcehistory is bounded
and opt-in; paused cursor mapping cannot borrow post-pause source pixels.
Independent review finds all three original #171 criteria satisfied on the sole
enabled M3 Max class and recommends closure after publication. Physical device
IO and other Mac classes remain unmeasured. Full receipt: [isolated validation](ISOLATED_VIDEO_SUSTAINED_VALIDATION.md).

The batch also corrects compositor due-tick idling and exact-owned-UID virtual
microphone feedback routes, adds CI coverage, and produces auditable build-only
virtual microphone evaluation packages. Actual extracted-driver callbacks and
20 refusal/preservation cases pass; no driver was installed or activated and no
Developer ID identity/notary service was used. #173/#174 remain open.

The optional guest return diagnostic proves positive native PCM/Opus and actual
Chrome RTP receipt, but Chrome emits zero jitter-buffer samples and zero meter
PCM. Its original positive gate remains failed. Normal playback/AEC, TLS/full
return qualification and the earlier #127 timing failure remain open. The new
compositor helper's virtual-clock success is not sustained GPU/Intel capacity;
#92 and its original failures remain open. #155 still lacks successful native
keyboard chooser selection in the locked session.

GitHub remains37open/24closed until the verified source is published and #171
and parent #56 are reconciled; this section does not anticipate closure.


## Published issue reconciliation — 2026-10-22

Verified source and its measured ISO receipt are published in `1322847`.
**#171 is closed**, its three acceptance checkboxes are checked, and parent
**#56** now checks O04. Fresh paginated GitHub reconciliation of the original61
issues confirms **25 closed /36 open**:25 feature tasks and11 trackers remain
open, with zero open pull requests. No other task closes from this batch. The
source and qualification limits above remain in force; no unmeasured Mac class,
physical capture, signed installation, browser PCM or sustained GPU result is
implied by this scoped completion.


## Reviewed accessibility and browser capture integration (2026-10-22)

Fresh paginated GitHub state remains **25 closed / 36 open** for the original 61 issues, with zero open pull requests. This batch adds no issue closures.

The final combined shipping source `16e8782` passes unsigned universal macOS Release for arm64 and x86_64 and the actual embedded-bundle/sandbox/App Intents audit. Later changes affect only scripts, CI and documentation; exact shipping source equality was verified. StreamCore, iOS, broadcast and project source remain unchanged from `b53ae5d`; the current full hosted Core/iOS results are retained without rerunning an unchanged local suite. Exact source and log hashes are in [the task ledger](MACOS_TASK_STATUS.json).

- Scene thumbnails now use real selection buttons. Media seek/trim/transport and folder/group controls name their targets; the mixer exposes passive non-color clipping status. Independent source review is clear. The locked-host semantic/keyboard fixture explicitly exits 77, so **#90 remains open** for complete native accessibility and contrast acceptance. See [the scoped receipt](STUDIO_SEMANTIC_CONTROLS.md).
- Browser capture intent is established before any await. Each run owns its inlet, producer tasks and timing token; stale cleanup cannot affect a replacement, and Stop waits exact final retirement. Seven controlled resource cases, actual silent helper sibling-page IPC and independent review pass. CI now runs the capture-free cases. **#124 remains open** for genuine SCK/WebKit audio, signed sandbox IPC and complete routing/exclusion qualification. See [the lifecycle scope](research/browser-widget-audio.md).
- CI explicitly selects and checks an RTMP/SRT-capable FFmpeg receiver using the actual Homebrew prefix, and opts into real Deck transport validation. Four parser tests, actionlint and a small existing-tool RTMP decode smoke pass. Earlier CI did not opt into that transport branch; this change does not claim its coverage retroactively.
- A diagnostic source-availability check now uses the original 17,850 total-frame allowance; decoder grace and all original nominal/render/A/V gates remain unchanged. The new real ARM run still **fails**: 16,957 and 17,047 rendered frames, approximately 28.26/28.41 fps, versus 17,850 required. Both recordings complete, and replay decodes all 16,956 available source frames. Intel also fails at 17,366/17,058 rendered frames; replay decodes all 17,366 available frames and both recordings complete. The earlier long stall did not recur, while the nominal frame deficit remains. **#92 remains open**; see [the preserved ARM](PERFORMANCE_HOSTED_ARM_39724736435.json) and [Intel](PERFORMANCE_HOSTED_INTEL_39724736435.json) measured failures.

The older `b53ae5d` CI run has passed both macOS Core and lifecycle steps, and iOS passed all 586 tests in 82 suites. Its later Mac stages are still active at this snapshot, so no complete macOS CI pass is asserted. New-source CI must validate the newly enabled checks.

## Current controls, authenticated IPC and font cohort — 2026-10-22 UTC

Read-only paginated GitHub reconciliation of all original 61 issue bodies keeps
**25 closed / 36 open**: 25 feature tasks and 11 trackers remain open, with zero
open pull requests and no state changes. This cohort makes no closure decision.
PTZ issue **#165 is already closed and is outside this original 61-issue
inventory**; its regression fix neither reopens it nor changes these counts.

Canonical shipping source `b6994ef` and the CI-only follow-up `28263d3` include
the following reviewed changes. The parent validates exact `28263d3`: unsigned
universal Release for arm64/x86_64 and the actual bundle audit pass, as do all
four focused gain/PTZ/socket/font checks. Shared Core, iOS, broadcast and project
source are unchanged from `44c078e`; no unchanged local Core/iOS suite was rerun
for this documentation pass. Exact root receipts and log hashes are retained
under `wave6Review` in [the ledger](MACOS_TASK_STATUS.json).

| Scope | New integrated evidence | Original acceptance disposition |
| --- | --- | --- |
| #90 accessibility | Pad color controls are named selection buttons; pad/playlist/scene-sound gains and PDF controls identify their targets. Gain labels handle huge/nonfinite persisted values without integer traps. Numeric crop fields/steppers validate complete finite geometry and preserve the displayed basis; zoom reports its target/value. Real PTZ native actions request bounded nudges with exact input ownership. Source/model checks and controlled native target-action tests pass. | **Open.** No new complete semantic AX/VoiceOver order, platform keyboard traversal, virtual fader/table/layer action, visual contrast or whole-window/small-layout operator acceptance is claimed. Offscreen PTZ AX delivery remains explicitly UNQUALIFIED77. |
| #165 PTZ regression, already closed | Entered sends complete before old-target Stop/disconnect; superseded queued motion, timers, pointer release and callbacks cannot affect a replacement. Actual NSButton target-action and controlled pointer cases pass. | **Closed state preserved.** A 250 ms nudge bounds controller intent. Local network content processing/timeout is not camera acknowledgment or guaranteed physical movement duration. This adds no new closure or physical acceptance claim. |
| #124 browser audio | Production defaults to the declared shared container and sealed same-team Apple-anchored peer identity, pinned executable/hash and kernel audit-token authority on both channels. Private-/tmp/prototype mode compiles only with native validation. Real owned socket/SecCode identity/refusal, negative production compile and silent validation helper IPC/retirement pass. | **Open; selector/startup stay disabled.** No macOS profile authorizes this declared group here. Actual provisioned sandbox/group launch, genuine WebKit attribution/tails, every-route acknowledged exclusions and live audio/A/V validation remain pending. NoReady probes establish fail-closed refusal; a locked session may exit at the initial CGSession guard, so those probes do not prove delivery through every parser branch. |
| #127 guest return diagnostics | Shipping generated Opus independently decodes through existing libopus: 109 payloads/104640 stereo frames with retained 960-step source/RTP framing and correct channel identity. Exact browser source distinguishes WebAudio FIFO ticks from the platform receive-decoder clock. | **Open.** No production media behavior changes or successful network sends follow from the cross-decoder proof. The clock explanation remains a hypothesis. Owned browser discriminators exit77 before connected measurement; the old 931-RTP/zero-PCM and 105.104 ms results, normal output/AEC and broader routing/sync qualification remain unresolved. |
| #92 title-font preparation | A bounded local 20-second static/replay comparison removes repeated font preparation. All four cases render 601 frames, but original replay decodes **601/601** and candidate replay **600/601** available frames. Registry/locale/language invalidation and complete-buffer renderer/owned-font/nested-bake checks pass. | **Open.** The measured candidate precedes the final separately tested nested-retention guard. Lookup counts are not cache-miss counts; a warm pixel hash is not every-frame parity. Static Core Image time increased. No universal speedup, repeated 600-second/hosted pass, waveform A/V or resource ceiling is inferred; all original hosted failures remain failed. |

See [semantic control scope](STUDIO_SEMANTIC_CONTROLS.md),
[PTZ authority and limits](PTZ_CONTROL_AUTHORITY_VALIDATION.md),
[browser production/prototype policy](research/browser-widget-audio.md),
[guest wire/clock audit](NATIVE_GUEST_RETURN_WIRE_AUDIT.md) and
[the bounded font receipt](TITLE_FONT_CACHE_PROFILE_2026-10-22.json).
The remaining original tasks and trackers retain their previous acceptance
limits. Local fixes do not stand in for native AX, signed provisioned IPC,
authorized provider/device flows or the original measured performance gates.

At the current read-only snapshot, published source is still `44c078e`.
[Its hosted CI run](https://github.com/joeblau/stream/actions/runs/39728335886)
is active, with **Intel failed**, ARM still running and the iOS job successful.
Intel passes the full **586 Core tests/82 suites in 192.316 seconds**, then fails
Deck receiver step 11 with exit132 because the receiver rejects generated
native media. Diagnosis is pending; no unmerged fix or root cause is counted.
The exact original 5,214,080-byte log is retained at
`/tmp/stream-ci-44c078e-119657621592-original.log`, SHA256
`bd50bd7481d39d4cbac75da423ebac3a3dec5d700d7be9d41a90c68479c2e87d`.
Neither the passing Core/iOS result nor the new local universal checks are a
whole desktop CI pass. Later cancellation, terminal results or a published fix
must be recorded as a new receipt without relabelling this failure.


### Final publication follow-up

Final shipping source `a5e1728` passes the unsigned universal Release build and
actual bundle audit after the manual Facebook/LinkedIn persistence repair. This
follow-up changes shared Core: 27 freshly rebuilt provider/template tests in two
suites pass, and the actual native Session fixture passes. The earlier
`28263d3` unchanged-Core statement applies only to that earlier receipt. Manual
drafts retain the previous Program-following output settings, disabled state,
empty credentials and no event binding; guidance survives rename, duplication
and metadata reload. **#169 remains open** for actual API connectors and
authorized provider acceptance.

The Deck fixture now retains owned receiver/decoder logs and status receipts
under the always-uploaded `artifacts-*` directory. Its actual modified target
compiles, and controlled nonzero/Unicode-tail/cleanup regressions pass. Exit-zero
and strict decode checks remain required. The original Intel receiver cause is
**unknown**: its stderr/status were deleted, and no runtime transport retry or
failure-resolution claim is made. The next hosted run must supply new evidence.

The final read-only GitHub refresh at 06:29 UTC still reports **25 closed / 36
open** original issues and zero open PRs. This publication closes no additional
task. Final source boundaries, fresh test receipts and exact hashes are in
`wave6Review.publicationFollowup`; later changes are scripts, CI or documentation
only. New-source CI and sustained performance remain separate from these local
passes.


### Terminal CI and fractional fixture correction

The `44c078e` run finished **failure**, with no cancellation. All three full Core
runs passed 586 tests in 82 suites: ARM 118.874 s, Intel 192.316 s and iOS
291.969 s. ARM passed native Deck transport, simultaneous RTMP/SRT fanout and
the subsequent rendering/chat/event fixtures through step 22, then failed to
compile the fractional ISO fixture's old renderer closure at step 23. Intel
failed its receiver-status check at step 11; iOS completed successfully.

The one-line fixture adaptation in `7eed009` uses the current typed Render
initializer and six arguments. The original compiler errors were reproduced;
fixed compilation and the first/only run of all five unchanged synthetic
AAC/PCM scenarios pass. Zero rational cue difference, best zero lag, identical
decoded windows/source grid and genuine gap counts remain required and pass.
This changes no production source and does not qualify the whole hosted run.
The Intel receiver cause remains unknown.

The 06:38 UTC read-only refresh confirms the same 25 closed / 36 open original
issues and zero open PRs. The next published source needs fresh hosted CI; all
old failing logs and exact original hashes remain in the terminal receipt.

## Paragraph lifetimes, scene ordering and control-row cohort — 2026-10-22 UTC

The 07:21 UTC read-only refresh of all original 61 issues still reports **25
closed / 36 open**, including 25 open feature tasks and 11 open trackers, with
zero open PRs. This cohort closes no issue. **#90, #92, #124 and #127 remain
open**, as do all other previously incomplete original tasks. Already-closed
#165 remains outside this inventory.

Exact integrated source `2ea819a` passes generation, the unsigned universal
arm64/x86_64 Release build, the actual bundle audit and the integrated **40-case
native control-row probe**. Exact source bindings and log hashes are retained
under `wave7Review` in [the ledger](MACOS_TASK_STATUS.json). These are new local
receipts; previous failures and their source scopes remain unchanged.

- `617fa81` keeps Core Text paragraph setting values and their array alive until
  `CTParagraphStyleCreate` returns. All 23 focused Core tests pass, and an
  optimized actual getter probe verifies 18 alignment/wrapping/overflow combinations
  after factory return and stack pressure. Independent recording review is
  clear. This fixes a pointer-lifetime defect without claiming previously
  observed visual corruption or changing text policy. See [the lifetime
  receipt](TEXT_PARAGRAPH_STYLE_LIFETIMES.md).
- `5b1d2fe` adds per-scene Move Earlier/Later menus, named accessibility actions
  and a native Scene menu. Reordering uses the complete current sibling order,
  stable IDs and current runtime authority, preserving selection, Preview and
  Program. Actual workspace/model/menu-callback, undo, persistence and stale
  callback checks pass; independent pro_adapters review is clear. Actual menu
  keyboard or platform AX delivery remains unqualified. See [the scene
  ordering scope](SCENE_BROWSER_REORDERING.md).
- `2ad4899` preserves both transport and transition control trees inside
  persistent horizontal native scroll containers. The exact integrated probe
  passes 40 static cases across both rows, ten configured text sizes and two
  scroller styles, checking narrow/wide viewports, exact native intrinsic
  height, full document extent and trailing-edge programmatic scrolling.
  Independent providers review is clear. `2ea819a` adds CI wiring and a 90 s
  process guard without changing layout assertions. Hidden owned row windows
  do not qualify whole-window layout, readable operator states, focus,
  keyboard/AX traversal or contrast. See [the control-row
  receipt](STUDIO_CONTROL_ROW_LAYOUT_2026-10-22.md).

Shared Core changes in this cohort. The published `9881359` iOS result of
**587 tests in 82 suites** predates the paragraph fix and does not qualify the
new Core head. At the timestamped snapshot, [native CI
39735328975](https://github.com/joeblau/stream/actions/runs/39735328975) still has
both macOS jobs running; its iOS job succeeds. [Browser interview CI
39735328995](https://github.com/joeblau/stream/actions/runs/39735328995) succeeds.
No whole desktop CI pass or newer-source hosted result is asserted. Routine
publication is deferred until that live native run reaches a terminal state.

The separate `9881359` [performance run
39735454725](https://github.com/joeblau/stream/actions/runs/39735454725) finishes
**failure on both hosts**. ARM renders **17,252 / 17,306** frames and Intel
**17,232 / 16,434**, below the unchanged 17,850 gate for each 600 s workload.
ARM replay decodes **17,251 / 17,252** available source frames; Intel decodes
**17,232 / 17,232**. All four writers report completion and zero audio/video
drops, with video sample counts equal to rendered counters. Both ARM media
inspections and the first Intel inspection pass. **Intel's second inspection
remains pending at the original 1,380 s owned-process deadline**; writer counts
do not establish its encoded-frame verification. Endpoint duration errors are
below 80 ms, which is not independent waveform drift qualification. No cause,
universal font-cache benefit or eventual inspection result is inferred.

The exact failed gates, statuses, source and artifact hashes are preserved in
[the performance receipt](PERFORMANCE_HOSTED_39735454725.json) and [the readable
resource budget account](DESKTOP_RESOURCE_BUDGETS.md). Those receipts are owned
by commits `db9fabf` and wording follow-up `dc80bd1`; they preserve the previous
hosted failures and distinguish deliberate slow-sink drops from recorder loss.
**#92 remains open.** Local source repairs and bounded checks do not replace
original performance, native accessibility, provisioned browser IPC or the
other outstanding acceptance requirements.

### Native CI follow-up: retained Intel encoder/receiver failure

The later 07:36:29 UTC read-only snapshot supersedes the earlier two-running-Mac
status: published `9881359` native run `39735328975` remains active, but **Intel
job `119679560505` has failed Deck transport step 11**. ARM has passed through
step 20 and remains active. Browser interview CI and iOS remain successful;
there is no whole native CI success.

At 07:23:24 UTC, the Intel receiver exits **234** because required mapping
`0:v:0` has no video stream. Retained diagnostics contain **47** VideoToolbox
`failedToCreate(status: -12902)` errors. Intel's full **587 Core tests / 82
suites pass in 248.041 seconds**, and controller step 10 passes before the Deck
failure. The original 5,239,806-byte log is preserved at
`/tmp/stream-ci-9881359-119679560505-original.log`, SHA256
`0ee5b521ddc4d41fa56a18490785258d43c1830febadac6d08e088a247b91722`.
Uploaded artifact `12408597560` preserves the normal, non-cleanup receiver exit
and stderr; no received MP4 exists. Exact artifact hashes and the timestamped
job/step snapshot are under `wave7Review.hostedCI.nativeFollowup`.

Missing encoded video is the observed failure boundary; exact rejected VT
arguments and the host capability cause are not established. The Deck owner is
implementing a narrowly reviewed vendor candidate, **not a proven Intel fix**.
No manual cancellation, rerun or dispatch is counted. All 25 closed / 36 open
original issue states and their acceptance limits remain unchanged.

## Optional encoder fallback and terminal native CI — 2026-10-22 UTC

Exact integrated source `ec95f20` now passes generation, unsigned universal
arm64/x86_64 Release, the actual bundle audit, the focused production-source
encoder fallback regression and the actual native Deck localhost transport
fixture. Root receipts and all five log hashes are retained under `wave8Review`
in [the ledger](MACOS_TASK_STATUS.json). This cohort changes the encoder vendor
and its fixture/CI wiring; it adds no newer-head full Core/iOS qualification.

The owned fork's `d9fceedc` handles an explicitly requested optional
low-latency encoder setting rejected with `kVTParameterErr`: it retries once
without that optional setting, preserving all other encoder requirements and
error behavior. Failed sessions are invalidated. Input pixel attributes use
the actual format subtype rather than the generic media type. The exact-source
regression preserves six refusal cases and proves a real software encoder's
`-12902` first create, successful ordinary create, unchanged options/preparation,
ten encoded H.264 frames and ten correctly decoded pixels. It separately checks
the actual codec's BGRA source-format derivation. The fork gitlink and CI
invocation are integrated; this is a local software-encoder proof, **not a
proven hosted Intel repair or hardware-throughput result**.

The exact combined native Deck fixture also passes real localhost RTMP
acknowledgment and H.264/AAC decoding. Independent recording countdown
cancellation and Start/Pause/Resume/New File/Stop finalize two real segments.
Native IPC source bindings, bounded visual receipts and controller ownership
checks pass. No physical controller, public ingest service or operator
qualification is inferred from this local fixture.

At the frozen **07:47:11 UTC** read-only snapshot, published `9881359` [native
CI run 39735328975](https://github.com/joeblau/stream/actions/runs/39735328975) is
**terminal failure**: ARM job `119679560262` succeeds at 07:46:25 UTC, iOS
succeeds, and Intel job `119679560505` fails as recorded above. The original
Intel receiver exit 234 and 47 VT `-12902` errors remain failed evidence. The
new local passes do not relabel that job or establish an Intel hosted fix.
All three original Core logs pass **587 tests / 82 suites**: ARM 107.384 s,
Intel 248.041 s and iOS 224.605 s. These published-source tests precede the
new paragraph fix; exact retained log hashes are in the ledger.
Browser interview CI remains successful. There is no whole native CI success
or hosted result for the newer `ec95f20` cohort.

The final **07:56:14 UTC** read-only refresh of all 61 original bodies/states
confirms **27 closed / 34 open**: 23 open feature tasks and 11 trackers, with
zero open PRs. The parent actually closed [#125](https://github.com/joeblau/stream/issues/125#issuecomment-6335726529)
and [#130](https://github.com/joeblau/stream/issues/130#issuecomment-6335641886)
after original-criteria and independent evidence review. Parent #54 now checks
I01 and I06 and **remains open**. Exact write receipts are retained in the
ledger; this documentation agent performs no GitHub writes.

For #125, the original up-to-ten target is conditional on supported budgets.
The reviewed [capacity document](NATIVE_INTERVIEW_CAPACITY_GATE.md) publishes
**one admitted media peer** on the named M3 Max/OS/Chrome/Node setup, with a
second-peer refusal. It is a conservative tested lower bound, **not a measured
maximum or resource-derived hardware/network budget**. Actual one-peer native
media/rejoin/Program/ISO synchronization and the separate controlled-media-host
refusal have distinct receipts. Shipping UDP and the separately pinned optional
TCP SDK qualification stay distinct. Broader Internet/mobile/deployment/endurance
coverage is a qualification limit; original validation permits supported
browsers or the validated SDK across reconnect and restricted-network cases.
Neither capacity above one nor a universal ten-guest limit is required.

For #130, explicit host approval, independent stable camera/screen identities
and framing, denial/retry/revoke/share-end and fresh rejoin preserve the guest
connection. Actual browser/Worker/native receiver, Program/ISO and separately
validated TCP-only local endpoint evidence satisfy the original supported
scope. Physical chooser interaction, every browser/mobile network, Internet
deployment and endurance are not claimed. #126 keeps its browser/mobile
requirements; #127 keeps its failed raw-return timing and unqualified normal
playout/AEC. Incoming synchronization does not relabel those failures.

Current local `1967f30` adds only reviewed documentation after validated
`ec95f20`. The exact new capacity document is 4,519 bytes, SHA256
`39cead406dc8af1c3d4bbde61cad07e525a6b65af72034d677fc484a19941363`;
its four retained execution hashes and named scope have independent
providers/guests review. Published main remains `9881359` at the final refresh.
No new media run accompanies the documentation or closures.

All other outstanding original requirements retain their previous limits,
including **#90, #92, #124 and #127**. The separate failed performance receipts,
Intel pending inspection and prior source-scoped evidence remain unchanged.

## Generated row-fixture initializer correction — 2026-10-22 UTC

Published `78796d1` [native CI 39744489372](https://github.com/joeblau/stream/actions/runs/39744489372)
finishes **failure**: both Mac jobs fail generated `FixtureControlsView(kind:)`
compilation in row-probe step 10 because its synthesized initializer is private.
The layout executable never runs. All three full Core runs pass **588 tests /
82 suites**: ARM 231.091 s, Intel 158.415 s, iOS 177.642 s. Both actual paragraph
probes pass. Encoder/Deck and later gates are not reached, so this run provides
no new Intel fallback or Deck media qualification.

`181bf6f` adds one explicit initializer in the generated fixture. Production
app/Core/vendor source equals `78796d1`; all 40 layout assertions and timeouts
are unchanged. The exact checked-in probe passes all 40 cases under **local
Xcode 27.2**, which does **not** certify hosted Xcode 26.6. Fresh exact-head hosted
execution remains required. Original terminal logs and the local probe hash are
bound under `wave9FixtureCIReview` in [the ledger](MACOS_TASK_STATUS.json).

Counts remain **27 closed / 34 open**, with #125/#130 closed. No issue state,
original acceptance gate or earlier failed receipt is changed by this fixture
correction or local pass.

## Ownership, numeric geometry and candidate artifacts — 2026-10-22 UTC

Counts remain **27 closed / 34 open** (23 features / 11 trackers); no new issue
closure follows from this cohort. Exact local `873dddd` passes generation,
unsigned universal arm64/x86_64 Release, the actual bundle audit and all four
combined numeric-geometry source/pixel/presentation gates. Exact receipts and
hashes are under `wave10Review` in [the ledger](MACOS_TASK_STATUS.json).
Shared Core source is unchanged by this cohort; no new full Core/iOS pass is
claimed. Published `a1bb23d` [native CI 39748453209](https://github.com/joeblau/stream/actions/runs/39748453209)
is **still active** at the recorded snapshot, with iOS successful. Its Mac jobs
are not a whole desktop CI pass or hosted validation of the newer local source.

- Provider Forget Authorization immediately retires local account/token
  authority, uses a separate nonsecret denial marker and reports failed durable
  cleanup. Controlled storage/refresh/generation and targeted audience
  invalidation checks do not qualify real OAuth or provider-side revocation.
- Numeric layer position/size/rotation drafts use existing validated commands,
  preserve unrelated values and undo, and reject retired/conflicting authority.
  Explicit recovery creates a new current-target draft; retained old callbacks
  cannot mutate it. Actual combined model, renderer and presentation checks
  pass. **#90 stays open** for native keyboard/AX delivery, mounted identity,
  full-window layout and contrast; see [geometry scope](LAYER_GEOMETRY_ACCESSIBILITY.md).
- Composition-clock tokens reject retired tick and missed-deadline work after
  stop/restart/output replacement. Five guard-only negative cases fail and six
  actual positive cases pass. This is lifecycle correctness, not performance
  qualification; see [clock authority](COMPOSITION_CLOCK_AUTHORITY.md).
- **#152 now has three reproducible 15-key stream/record/interview candidate
  archives**, registered and packaged with public MIT-template provenance.
  Actual SDK saved-binding/restart and package-metadata checks are scoped
  software evidence. **Actual target-app importer acceptance and package
  install/update/uninstall remain unproved.** Manual editor export is an
  alternative producer, not a required acceptance clause. See [candidate
  profiles](../../integrations/stream-deck/profiles/README.md).
- An evaluation-only virtual-microphone Program producer now exercises the
  actual mixer and dynamically loaded driver PCM/lifecycle through owned HAL
  syscall boundaries. Its public OS transport is compiled but unexecuted;
  shipping targets and routing stay disabled. This does not qualify installed
  IPC/sandbox, another app's input, latency or signed distribution. **#173/#174
  stay open**; see [producer scope](../prototypes/VirtualMicrophone/README.md).

The [generated-only thread trace](PERFORMANCE_LOCAL_THREAD_TRACE_2026-10-22.json)
is one invocation of two 20 s workloads based on `78796d1`: static 600/601
rendered/attempted, replay 601/601; both movies contain 600 writer frames, and
replay decodes 599/600 available source frames. These counters remain distinct.
Profiler-only pixel hashing contributes the largest healthy callback peaks;
synchronous caller CPU and the measured tick-body interval are not total GPU
utilization or a complete async tick. No hosted-like whole skip is reproduced.
Later generator compatibility preserves the new clock guards without a new
trace. **#92 stays open**: no sustained capacity, resource ceiling, waveform
sync or cause/fix for the retained hosted failures is inferred. All original
failed receipts and remaining acceptance limits are preserved. Chat diagnostics
were reviewed separately in the follow-up below.

### CI queue policy follow-up

CI-only `34bea18` retains the same `ci-${{ github.ref }}` group and sets
`cancel-in-progress` to `${{ github.event_name == 'pull_request' }}`. Main pushes
retain active acceptance while newer pending runs coalesce; superseded PR runs
still cancel. This promises neither FIFO order nor execution of every commit.
Parent official-documentation/YAML review passes; production source remains
identical to validated `873dddd`. The recorded active `a1bb23d` result remains a
point-in-time snapshot, not a new hosted pass or a publication claim.

### Diagnostic cleanup follow-up

Test/docs-only `7037a30` integrates bounded pre-cleanup failure snapshots and
source-owned RTC process monitoring, including reviewed fixes for terminal
abort handling, surviving process groups and replaced temporary directories.
All 37 portable client tests pass on the combined source; the owned fake-process
suite passes 13 checks. Shipping app/Core/vendor source remains identical to
validated `873dddd`. No replacement browser experiment ran, and the original
interrupted attempt remains unqualified. This does not close #127.

## Settings semantics and bounded diagnostic evidence — 2026-10-22 UTC

Exact `77f5081` passes generation, unsigned universal arm64/x86_64 Release and
the actual bundle audit. Current local `75fab97` preserves all 316 validated
shipping files and the vendor gitlink; later changes are diagnostic workflow,
helper labels and documentation. Root receipts and hashes are in `wave11Review`
in [the ledger](MACOS_TASK_STATUS.json). Settings' four slider construction
sites now expose native operation names and unit-bearing values; existing
bindings/ranges/steps/identity remain unchanged. Independent source review is
clear. **#90 stays open**: compilation and labels do not prove mounted AX,
keyboard/VoiceOver delivery, full-window layout or contrast.

One repaired-wrapper owned RTC diagnostic at published `ea3c834` completes
**exit 77 / UNQUALIFIED in 11.429 s**, before connection or the original 12 s
measurement. Both null contexts run and sender source PCM is positive, but both
ICE/connection states remain `new`: sender outbound Opus reports zero packets
and bytes, while receiver inbound/selected-transport rows are absent. An absent
row is not an explicit received-packet counter. Receiver PCM remains zero.
Retained callback counts are capped lower bounds; the byte counter includes
discarded batches. Independent cleanup evidence confirms the owned process
group/browser/directory are retired. Reviewed [receipt](NATIVE_GUEST_RETURN_NULL_OUTPUT_WAVE11_2026-10-22.json)
and [wire audit](NATIVE_GUEST_RETURN_WIRE_AUDIT.md) make no native codec,
receive-clock cause, normal-output/AEC or timing claim. **#127 stays open**;
this is a completed negative attempt; no further attempt or replacement of old failures is claimed.

The reviewed manual-only `native-composition-attribution.yml` defines fixed
ARM/Intel jobs with **two 20 s workloads each**, one unchanged trace invocation per job,
a seven-file tool/workload hash gate, independent noncancelling concurrency,
90-minute job bounds and seven-day retention of partial evidence. Two neutral
labels change; production behavior and original 600 s / 17,850-frame / 80 ms /
1,380 s gates do not. **It has not been dispatched at this snapshot. #92 stays
open.** Any later run ID/result needs its own receipt.

The 09:36 UTC preflight confirms **27 closed / 34 open**, zero open PRs and
published main `ea3c834`. Older `a1bb23d` native CI remains active; EA native CI
is pending. EA browser foundations pass 21 Worker tests, 37 client tests and
actual synthetic Chrome 156 loopback; the older `3be6110` Deck workflow succeeds.
These source-scoped passes are not a whole native CI result or native/physical
media qualification. All original failed receipts and other open gates remain.

## Native CI completion and short attribution data — 2026-10-22 UTC

Exact `a1bb23d` [native CI 39748453209](https://github.com/joeblau/stream/actions/runs/39748453209)
finishes **SUCCESS on all three jobs**. Full Core passes **588 tests / 82 suites**:
ARM 105.135 s, Intel 162.553 s, iOS 200.147 s. Both hosted paragraph probes and
all 40 static offscreen row cases pass. Actual Intel software encoder creation
rejects optional low latency with `-12902`, retries ordinary creation successfully,
and encodes/decodes ten red frames. Actual localhost Deck H.264/AAC and two
independent recording segments pass, along with shared RTMP/SRT and all later
native gates. This qualifies that named CI source and fixture scope; it does
not relabel earlier failed runs or prove physical/operator, sustained throughput
or signed distribution acceptance. Newer `a9cfd98` native CI is separate.

The `a9cfd98` [attribution run 39757372776](https://github.com/joeblau/stream/actions/runs/39757372776)
finishes **diagnostic SUCCESS** on ARM and Intel, one fixed two-case 20 s
invocation per job with verified source identity. All original short-run checks
pass their **450-frame minimum**, not the original 17,850-frame / 600 s gate.

| Host/case | Attempts + whole skips | Rendered / writer video | Post-warmup counter | Replay input decoded / available | Writer audio drops |
| --- | --- | --- | --- | --- | --- |
| ARM static | 561 + 40 | 553 / 553 | 531 | — | 0 |
| ARM replay | 574 + 27 | 574 / 574 | 544 | 553 / 553 | 0 |
| Intel static | 547 + 54 | 528 / 528 | 517 | — | 16 |
| Intel replay | 566 + 35 | 565 / 565 | 535 | 528 / 528 | 0 |

ARM's 22/30 valid warmup frames explain its post-warmup counters; deliberate
slow-sink drops are separate from healthy writer delivery. Independent ARM and Intel
source/event/counter binding reviews are complete; Intel
static audio-drop cause remains unproven. Mean render time is not total frame latency, and diagnostic success
does not prove 30 fps capacity, a sole bottleneck or any new clock candidate.
**#92 remains open.** Exact original logs, archives and case bindings are under
`wave12Review` in [the ledger](MACOS_TASK_STATUS.json).

A fresh retrospective check confirms old 600 s run `39735454725` is terminal
**FAILURE on both hosts**. Intel's second decode inspection was **incomplete /
UNQUALIFIED at the original 1,380 s owned-process teardown**, not still running.
Original log line 6229 explicitly reports the deadline failure; raw
`validationComplete:false` / inspection `pending` remains its last persisted
snapshot. The 0.198536 s field is pre-inspection overhead, not final inspection
duration. No eventual success or blocking-API cause is inferred. Both writers,
the first inspection pass and all original capacity failures retain their
recorded outcomes; no media rerun, duplicate download or gate change occurred.

The separately reviewed clock source requests `tolerance: .zero` on the existing
sleep call. It changes no FPS, PTS, deadline arithmetic, renderer, mailbox,
encoder or QoS. It does not guarantee on-time resumption or establish a cause
or timing improvement.
Actual six-case lifecycle and CPU-only helper epoch/reset checks pass. New
generated request/return observations include executor/host resumption and do
not subtract CPU across suspension; their per-run epoch atomically fences events
and aggregates against case reset. Loop iteration is not a rendered-frame ID.
A new real comparison has not run. See [the source/proof scope](COMPOSITION_SLEEP_TOLERANCE.md).

Exact combined `7419966` passes generation, unsigned universal arm64/x86_64
Release and the actual bundle audit after the clock source change. This build
result is separate from the old `a1bb23d` CI success and the baseline `a9cfd98`
short diagnostic; a new timing comparison has not run. It does not establish a
performance improvement, and every original sustained gate remains unchanged.

Current local `639e49a` adds the independently approved [ARM baseline account](COMPOSITION_HOSTED_SLEEP_BOUNDARY.md)
and [bound raw-counter receipt](PERFORMANCE_HOSTED_ATTRIBUTION_39757372776_ARM.json)
after validated `7419966`; all 316 shipping files and the vendor gitlink remain
identical. Counts stay **27 closed / 34 open**. The new post-clock comparison is
**not dispatched at this snapshot**; independent Intel binding/counter review is
complete while causal interpretation remains unqualified. Browser exclusions remain separate, unmerged #124 work. No open
issue or original qualification gate is closed by this cohort.

## Ending fixture receipts and bounded capture exclusions — 2026-10-22 UTC

The 10:32:53 UTC read-only refresh of all original 61 issue bodies/states confirms
**27 closed / 34 open**, zero open PRs and published `06b895a`. No new closure is
justified by this cohort. #124's verified live browser route and original full
recapture/lifecycle acceptance remain gated; #133's real provider-account/API
acceptance is unchanged. Already-closed #135/#147 retain their original scope.

The original `a9cfd98` ARM failure at 10:21:29 is reproduced with exact ending,
vault and account source: fixture replacement reused a consumed configure grant
receipt and threw `CancellationError` before its intended stale-response/media
checks. Fixture-only `06b895a` obtains fresh deliberate receipts in both setups,
checks the installed replacement and retains captured old generations and every
original zero-POST/stale-response/independent-output assertion. The full actual
fixed harness passes once, including healthy independent output and a decoded
one-second H.264/AAC recording. Production/Core/vendor are unchanged by this
fixture correction; the original hosted failure remains failed evidence.

The separate browser capture change provides owner-revision acknowledgments for
supported system-mix and pinned-display exclusions. Filter installation, serial
callback drain and affected mixer-history retirement precede helper permission;
missing/retiring/failed owners and opaque/picker/window/direct-helper routes
remain conflicts. Controlled actual-class/mixer/session proofs and build-only
whole-source compilation establish software ordering. They do not qualify live
SCK, every-route recapture, actual WebKit attribution/tails, signed provisioned
shared-container launch, permission/device workflows or local HTML/subresources.
**#124 stays open; production selection/startup remain disabled.** Source and
scope are in [the exclusion receipt](BROWSER_CAPTURE_EXCLUSIONS.md) and
`wave13Review` in [the ledger](MACOS_TASK_STATUS.json).

Exact capture source `46153b1` passes generation, unsigned universal arm64/x86_64
Release and the actual bundle audit. Current `a428d23` adds only the reviewed CI
harness invocation; all 317 validated production paths/vendor remain identical.
The root proof and source manifest are bound in the ledger.

At the recorded snapshot, `a9cfd98` native CI remains active with ARM failed and
iOS successful; published `06b895a` native CI is pending. The older pending-only
`a4d0122` native run coalesced automatically with zero jobs; no manual cancel is
inferred. The separate `a4d0122` clock diagnostic is terminal **SUCCESS on both jobs**
at 10:39:03 UTC; Intel artifact interpretation is separate/pending. Its audited
ARM sample renders **551 / 562** frames versus baseline
**553 / 574**, with **10 / 0** audio drops: no observed output-throughput
improvement in these samples. Independent binding review passes; this does not
prove a kernel/coalescing cause or qualify the unchanged 600 s gates. Detailed
timing interpretation remains separate from run conclusions. **#92 stays open.**

## Reviewed software cohort and final short clock comparison — 2026-10-22 UTC

Exact local `5c7dbea` passes generation, unsigned universal arm64/x86_64 Release
and the actual bundle audit. The expanded source/recipe manifest binds 659 paths
and the vendor gitlink, including StreamBroadcast, helper and shared/native
sources; its count differs in scope from the earlier 317-path manifest. Root
receipts and exact source hashes are bound under `wave14Review` in
[the ledger](MACOS_TASK_STATUS.json). Published main is still `c90de17` at this
snapshot. Current local `4376dad` adds the approved comparison documents and
exact threshold-label correction; all 659 validated paths/vendor remain
unchanged. Counts remain **27 closed / 34 open**; no new closure is justified.

- Native effect/AU parameter names and truthful units, secondary-canvas controls
  and cue-specific rundown operations now have explicit labels. Independent
  source reviews and the combined application typecheck pass. Mounted
  AX/keyboard/VoiceOver delivery, full-window layout and contrast remain
  unqualified; **#90 stays open**.
- Actual compositor mailbox retirement releases pending surfaces without waiting
  for already-active callbacks. Eight actual mailbox cases and six unchanged
  clock cases pass. Removing only three removal-close calls makes the unchanged
  pressure-recovery assertion fail. The four-surface pool threshold remains;
  active callbacks or external raw-buffer owners cannot be revoked. This proves
  the bounded ownership repair, not historical holder attribution or sustained
  throughput. See [the proof](COMPOSITION_MAILBOX_RETIREMENT.md).
- Local HTML now has an explicit library file/folder path, bounded immutable
  copies, generation/lease checks and Stop/exit-bound cleanup with persistent
  quarantine admission. Actual file-store/session checks use inert capture,
  mixer and transport boundaries; helper typecheck and whole-source compilation
  pass. No real WebKit/App Group sandbox subresource, media, capture or signing
  qualification follows. **#124 stays open and production routing/startup stay
  disabled.** See [the local-content scope](BROWSER_WIDGET_LOCAL_CONTENT.md).
- Bounded pre-RTP RTC failure/signaling diagnostics pass 18 Node tests and six
  syntax checks with independent review. No new RTC/media attempt or return-audio
  repair ran; **#127 stays open**. See [the diagnostic scope](NATIVE_GUEST_RETURN_PRE_RTP_DIAGNOSTICS.md).

The final independently audited [two-architecture clock comparison](COMPOSITION_HOSTED_CLOCK_COMPARISON_2026-10-22.md)
and [machine receipt](PERFORMANCE_HOSTED_ATTRIBUTION_39762992882.json) bind exact
baseline `a9cfd98` and zero-tolerance `a4d0122`. Both diagnostic jobs pass all
original short checks with their **450-frame minimum**:

| Host | Baseline static / replay output | Zero-tolerance output | Baseline → candidate audio-chunk drops |
| --- | --- | --- | --- |
| ARM | 553 / 574 | 551 / 562 | 0 / 0 → 10 / 0 |
| Intel | 528 / 565 | 553 / 569 | 16 / 0 → 0 / 0 |

ARM has no observed output improvement. Intel's static difference coincides
with cold measured-tick time 1,018.380 → 418.638 ms and first skips 29 → 11;
separate virtual instances and new observer work prevent a controlled causal
or general performance claim. Return lateness includes executor/host resumption;
there is no baseline sleep-return observation. Intel's extra legacy entry 568 is
rejected before the production body: actual attempts are 567. Iteration, rendered
output, warmup, replay-source decoding and writer audio accounting remain distinct.
No 600 s workload ran for this cohort, and **#92 remains open** with all original
600 s / 17,850-frame / 80 ms / 1,380 s gates and failed receipts unchanged.

Older `a9cfd98` native run `39757320250` is now terminal **FAILURE**: both Mac
jobs fail the owned-ending fixture with top-level `CancellationError`; iOS
succeeds. All three Core suites pass 588 tests / 82 suites (ARM 140.215 s,
Intel 238.018 s, iOS 185.470 s). The later fresh-receipt fixture correction does
not rewrite that result. At the frozen **11:10:54 UTC** watcher snapshot,
published `c90de17` native run `39764965913` remains **active**: ARM is in
controller step 10, Intel in Core step 9, and iOS passes 588 / 82 in 210.314 s.
This is not a whole native CI success. The separate publisher-cache candidate
is excluded from this validated cohort; no new run, issue write or publication
was performed for this documentation update.

## Program repeat-cache ownership and one completed RTC diagnostic — 2026-10-22 UTC

Exact `eecaddc` passes generation, unsigned universal arm64/x86_64 Release and
the actual bundle audit. The expanded source/recipe manifest binds 662 paths
and vendor; `wave15Review` in [the ledger](MACOS_TASK_STATUS.json) records the
receipts. Published main remains `e803303` at this snapshot. Counts stay
**27 closed / 34 open**; no new closure follows.

Both raw publisher actors now clear their unused repeat cache before the first
accepted Program audio call's existing await, and avoid caching later Program
video. Rejected calls, legacy repeats, Program duration, admission and PTS
behavior remain unchanged. Whole actual actors pass six positive cases and four
expected negative ownership failures, using real one-buffer Core Video pools.
Selected SDK media effects are inert: no publisher start, transport, encoder,
device or capture ran. Independent review verifies source/proof bindings. This
fix does not prove opaque SDK/VideoToolbox release, identify historical surface
holders or qualify full isolation or sustained performance. **#92 stays open.**
See [the cache evidence](PUBLISHER_PROGRAM_REPEAT_CACHE.md).

One authorized owned all-Chromium diagnostic at exact `e803303` finishes
**UNQUALIFIED / exit 77 after 11.398 s**, with no retry. The 10 s connection gate
fails before the original 12 s positive measurement begins. All ten observed
description/candidate API calls fulfill; each peer exposes an unselected
ICE/DTLS-`new` transport, no remote-candidate/pair rows and four local candidate
rows. Positive sender source PCM coexists with explicit zero outbound Opus
packets/bytes; receiver inbound rows are absent and measured PCM is zero.
API fulfillment establishes neither internal candidate handling nor wire checks,
connectivity or cause. Independent review binds the raw/source evidence and
owned-process/group/directory cleanup. No native SDK, normal-output/AEC/A/V or
whole-task acceptance follows; **#127 stays open**. The earlier failed/partial
attempts retain their original outcomes.

The [reviewed RTC receipt](NATIVE_GUEST_RETURN_NULL_OUTPUT_WAVE12_2026-10-22.json)
and [diagnostic account](NATIVE_GUEST_RETURN_PRE_RTP_DIAGNOSTICS.md) retain the
bounded originals. In the pinned collector, remote-candidate rows are emitted
while constructing pair stats; their absence is coupled to missing pairs, not
independent candidate-resolution evidence. Internal handling remains unknown.

At the frozen **11:26:56 UTC** watcher snapshot, published `c90de17` native run
`39764965913` remains **active**: ARM managed-event step 13, Intel controller
step 10; iOS passes 588 tests / 82 suites in 210.314 s. The earlier `a9cfd98`
both-Mac ending-fixture failures remain failed. Neither local compilation nor
the owned diagnostic implies whole native CI success, mounted AX delivery,
real WebKit/capture qualification or sustained performance acceptance.
