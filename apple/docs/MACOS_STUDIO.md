# Stream Studio for macOS

Generate the project with `cd apple && xcodegen generate`, open `Stream.xcodeproj`,
and run the StreamMac scheme. The deployment floor is macOS 14.
The pinned transport archives omit SRT/WebRTC implementation symbols in their
Intel slices. CI resolves packages into its own derived-data directory, then
`python3 scripts/repair_desktop_transport_archives.py build/desktop` rebuilds
missing implementations from pinned sources with static OpenSSL at the same
macOS 14 floor. Install CMake for this step. Source revisions and license notices
remain in `build/desktop/TransportSourceBuild/<architecture>`. Use the same
resolve/repair step before an Intel local build. The script changes only that
build's downloaded artifacts and retains the other architecture's slice.
CI builds the
desktop app and runs the shared logic suite on Apple Silicon and Intel hosted
macOS 26 runners; the existing iOS simulator job is retained. Unsigned local
validation uses `xcodebuild -scheme StreamMac -destination 'platform=macOS'
CODE_SIGNING_ALLOWED=NO build`.

## Shows, profiles, and storage

The toolbar's show name opens the embedded project browser. Create, rename,
duplicate, or archive shows; create independent or duplicated profiles. Selecting
a show stages it. Apply stops local preview and reconstructs the studio only
after streaming and recording stop. Creating or duplicating a show leaves the
active output untouched. Local shows need no account.

Desktop data lives in the app's Application Support `StreamStudio` folder:
`Projects/<project UUID>/<profile UUID>`. Each profile owns scenes, overlays,
assets, mixer settings, source selections, destination metadata, shortcuts,
annotations, and presentation state. Device identities are references that can
need repair on another Mac. Permissions, interface preferences, global shortcut
consent, and installed adapters belong to the Mac. Destination secrets belong
to stable IDs in Keychain, not project JSON. The older desktop App Group files
are copied once without removing them; desktop settings then use a separate
versioned file and Keychain service. The iOS app keeps its original settings
store and publishing policy.

Backup History previews valid scene snapshots and restores one explicitly while
outputs are stopped. Up to 20 previous valid versions are retained per saved
document. Atomic saves leave either the previous or new complete JSON. Corrupt
or newer scene documents retain their original bytes in a quarantine backup.
An unreadable scene file offers the last valid backup in an attached recovery
sheet; accepting it restores the previewed scene names without starting outputs.
Catalog recovery requires explicitly accepting the recovered catalog. Assets
are not duplicated on every autosave.

Export Show writes a versioned `.streamshow` package with SHA-256 file checks.
Choose the selected scene (including nested scene dependencies) or the whole
profile, and whether to include readable library media. Without media, import
keeps repairable asset entries. Stream keys, credentials, remote widget URLs,
machine device selections, and sandbox bookmarks are omitted. Account and PTZ
configuration are not included. Finder opening, a package dropped onto Shows and Profiles, and the Import Show button show
a preview; import creates a separate show, remaps IDs, then stages it for Apply.
Relink missing sources/assets and configure destinations before production.
Raw legacy media bookmarks without library registrations need importing into
Assets before transfer. Copied HTML/media can contain the producer's own content.
Native file delivery and sandbox/restart evidence, including the remaining
picker and physical gesture limits, are documented in
[Portable show native entry](PORTABLE_SHOW_NATIVE_ENTRY.md).

## Desktop and shared boundaries

| Owner | Responsibility |
| --- | --- |
| `StreamMac` | Retained show/profile runtime, versioned desktop persistence, machine-scoped bookmarks/consent, macOS capture adapters, mixer/control integration, scene compositor, recording/output orchestration and embedded UI |
| `StreamCore` | Cross-platform serializable models, protocol/credential primitives, validation, telemetry/adaptive policy and reusable Apple media/audio utilities behind their supported platform APIs |
| `StreamBroadcast` | Existing process-independent publisher adapters, network recovery and raw-sample encoding; compiled into the app targets without importing desktop UI/capture adapters |
| iOS `Stream` | Its existing settings store, screen-capture lifecycle and publishing UI/policy; it does not compile `StreamMac` or link its Syphon/AppKit adapters |

Desktop settings use a version-1 wrapper and an independent profile-scoped
Keychain service, while destinations use machine Keychain entries keyed by their
stable IDs. Migration reads/copies legacy protocol slots and leaves the iOS
files/accounts intact. Existing legacy signing entitlements remain for that
access; their presence does not make new desktop documents shared with iOS.
Unknown/corrupt desktop documents are preserved. Shared tests, retained iOS
simulator checks and native desktop lifecycle/media fixtures verify these
boundaries; real provider acceptance is a separate transport qualification.

## Production

Grant camera and microphone access when requested. Screen capture uses the
system picker and Screen Recording permission; denied access can be repaired in
System Settings. The Sources inspector adds cameras, screen selections, media,
PDFs, Syphon feeds, and web overlays. Capture resources are shared by their
stable identities and unavailable sources show inline health.

Preview edits are staged. Take publishes the staged scene to Program; Revert
discards unpublished edits. Explicit Direct Live Editing publishes each edit.
The mixer sends selected channels to Program, Monitor, and guest return buses;
headphone monitoring avoids acoustic feedback. Per-channel effects and delays
remain separate from source capture. Program recording receives the mixed
audio bus and compositor clock independently of live output. See
[recording policy and measured evidence](../PROGRAM_RECORDING.md) and
[keyboard/accessibility controls](STUDIO_CONTROLS.md).

RTMP/RTMPS and SRT use the existing publisher adapters. WHIP is experimental;
unsupported bearer-only endpoint authentication and HEVC combinations are
explicitly rejected rather than silently substituted. Codec support at a
provider must be checked against that provider. NDI, DeckLink and Zoom inputs remain gated by their actual installed adapters.
Native browser-interview guest media is not implemented. Provider accounts and
public readers have [documented granted-scope controls](PROVIDER_ACCOUNTS.md);
authorization, real ingest and provider completion acceptance remain unqualified.
Installed AVFoundation/Continuity Camera and Syphon paths do not establish
universal device or service support. Optional [virtual outputs](VIRTUAL_OUTPUTS.md)
need their own signed installation, OS activation and consumer qualification.

## Optional outputs and automation

Recording presets and stable isolated-track selections belong to the active
profile. The selected recording folder remains a machine-scoped permission.
Available microphone/device, application/system, media/soundboard channels and
Program/Monitor/Aux buses select isolated WAV or M4A taps. Channel taps choose
before or after the insert chain; bus taps contain their mixed processing.
Files share program pause, rotation and host-clock alignment. Missing sources
fail their own tracks while the program recording continues. Independent widget
audio and native interview guest capture are unavailable; an explicitly routed
System Mix is the supported widget recording path.

Recording Options chooses MP4/MOV, H.264/HEVC, quality, folder, filename prefix,
optional record-only countdown, auto-record on Go Live, and size/duration splits.
Pause/Resume and New File affect recording independently of network delivery.
Recording uses a separate encoder; encoded network-stream sharing is not
implemented (#132). High quality, HEVC and overlapping file finalization can
consume additional storage/encoder budget. The [recording guide](../PROGRAM_RECORDING.md)
records the actual media checks and limits.

Open Recording Library beside the recording controls. It groups captured
project/profile sessions and shows actual files, thumbnails, duration, size,
track/gap manifests and complete/recoverable/partial status. Add Marker uses
accepted recording time. Export markers as JSON/CSV/text; preview a readable
file inline, trim to a new MP4/MOV clip, reveal it in Finder, or deliberately
share/open it in a chosen editor. Active/finishing files and invalid/overwriting
clip exports are blocked. Native picker/share/editor acceptance remains manual.

External Display Output selects an eligible secondary display, including an
AirPlay display that macOS exposes as an extended screen. Fit and Fill control
presentation without changing program or network media. Unplugging stops that
output; reconnect it explicitly. Native tests use injected display topology;
physical AirPlay latency and consumer hardware remain unqualified.

The app provides typed Shortcuts actions for state, scene selection, Take,
Revert, local preview/recording, and staged layer visibility. Actions target the
current profile and stable resource IDs. Finish onboarding and visible permission
or modal choices first. Scene/profile switches invalidate stale targets. Native
App Intent tests pass; installed, signed Shortcuts discovery and cold launch need
release qualification.

Application settings can register optional adapter manifests against dedicated
paired local-control clients. Registrations start disabled and allow only the
listed command IDs. Disable disconnects the client and cancels its macro;
Remove and Revoke also removes its Keychain pairing. Media source/output roles
are declared contracts but are not supported transports in this version.

## Distribution and support

Distribution is a Developer ID-signed, hardened-runtime, notarized ZIP outside
the Mac App Store. With a Developer ID identity and saved notarytool keychain
profile, run `STREAM_SIGNING_IDENTITY='Developer ID Application: …'
STREAM_NOTARY_PROFILE=stream-notary zsh scripts/package_desktop_release.zsh`.
The script resolves and repairs transport artifacts, then archives the host's
native architecture, exports, verifies, notarizes, staples, and assesses the app.
Build Intel and Apple Silicon release artifacts on their respective hosts.
Signing credentials are never committed. Updates replace the app bundle while
retaining Application Support projects and Keychain data; there is no automatic
updater. Uninstall by removing the app. Keeping/removing project data is an
independent user choice, as is deleting credentials or revoking paired clients.
Optional system/device extensions require their documented packaging, install,
activation and receiving-application checks for a release.

The sandbox grants camera, microphone/audio input, outgoing networking, and
user-selected file read/write plus app-scoped bookmarks. Audio Unit hosting
uses its declared temporary exception; hardened-runtime loading of third-party
plugins needs separate distribution qualification. Local-control listeners
must remain explicitly enabled and loopback-bound, with their own authenticated
pairing/revocation. The distribution audit checks the built bundle and declared
entitlements; it does not claim unsigned CI is a notarized release.

Measured locally: MacBook Pro Mac15,8, M3 Max, macOS 27.0.1, Xcode 27.2 beta.
Native synthetic chroma/LUT alpha/channel ordering/color-space controls pass;
live hair/key-camera qualification remains outstanding. The recorder decodes
three seconds of 60 fps H.264/AAC static video with aligned tracks and a measured
flash/tone difference of 0.0000417 seconds. Injected low-disk, removed-volume,
writer failure, and overload probes pass. These are specific observations, not
a sustained workload limit for other Macs, physical device unplug, or every
provider. Include Mac model, OS/toolchain, output profiles, reproduction steps,
and relevant local recording journals with a support report; redact credentials
and media before sharing.

Authoritative release requirements: [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
[Apple packaging](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution),
and [GitHub runner architectures](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

## Diagnostics

Health Details separates new camera/screen deliveries from paced compositor
frames. Static screens may report zero new deliveries while Program and its
recordings keep their configured cadence. Each output shows its acknowledgment
state, measured encoder frames/bitrate when the backend reports them, socket
queue, and independent bounded-mailbox drops. Compositor render time, subscriber
queues, audio underruns/tap drops, recording track endpoint difference, storage,
CPU, memory, thermal state, and recording reservations plus active publisher
sessions identify resource pressure. Encoder reservations include primary and
secondary recording, isolated video, countdown/preflight, overlapping rotation
and finalization; they are reserved capacity, not a hardware utilization reading.
The track endpoint difference is not a clock drift or perceptual A/V sync test.
Live clocks persist across reconnect and hidden panels. Recording clocks use
writer progress, including pause/rotation semantics.

Export Diagnostics writes a bounded JSON snapshot with hardware policy,
configuration dimensions, stable resource IDs, aggregate counters, and the last
256 lifecycle events. It omits names, endpoints, secrets, error descriptions,
file paths, and captured media; audio channel labels are pseudonymized. Use the
actual recording sync harness for decoded-media evidence. GPU utilization and
end-to-end network latency are not inferred from render or socket counters.

[Local controller pairing, revocation, protocol and sample client](LOCAL_CONTROL_IPC.md)
are documented separately. Enable the listener explicitly in embedded Controls,
pair each client, and revoke it there. Switching shows disconnects paired client
sessions and requires a fresh handshake; stored pairings remain machine scoped.

## Repeatable workload baseline

Run `zsh apple/scripts/run_studio_performance_harness.zsh` from the repository root.
The tool builds the actual compositor and writer, then measures four ten-second
synthetic static-screen/camera scenes with twelve editable layers, H.264/AAC
recording, a slow secondary sink, and main-actor scheduling probes. Each run
uses a new artifact directory and writes JSON alongside its synthetic recordings.
[Recorded baseline](PERFORMANCE_BASELINE.json): Mac15,8, macOS 27.0.1, 720p30,
1080p30, 1080p60 and 4K30 completed with valid tracks, zero recorder drops, about
30/60 achieved fps and under 4 ms maximum main-actor scheduling delay in that run.
All timestamps use the same host clock as audio; rendering skips overdue
opportunities instead of compressing the video timeline. Slow sink drops remain
isolated and visible.

An earlier 4K30 run failed with a writer-wide encoding error while other builds
were active; two subsequent runs completed. Completed writers now release their
encoder objects promptly. These observations do not establish a guaranteed
4K session budget. Physical camera/screen/media capture, simultaneous real
network publishers, long thermal runs, unplug/suspend, Intel workload baselines,
and signed/sandboxed deployment remain independent qualification work. The
hardware policy is a conservative ceiling, not a benchmark certificate.

[Stream Deck installation, pairing and development package](../../integrations/stream-deck/README.md)
uses the same live command catalog and shows authoritative state. Its signed
helper, hardware models and Marketplace release need their documented checks.


## Public chat and comment preparation

The sidebar and Settings share one runtime-owned Restream session. Configure the Restream app in Settings, then connect the sidebar. Destinations → Provider Accounts and Events also offers explicit **Read Public Chat** for authorized YouTube/Twitch accounts. Account authorization and ingest do not start a reader. Only documented public events enter the common feed; private whispers and unknown kinds are excluded. Canonical provider/message IDs deduplicate relay and direct delivery. Reconnect preserves the curated queue and favorites. See [direct reader scopes and acceptance limits](DIRECT_CHAT.md).

Filter by platform, destination, author or event type; search author/message text and favorite messages. Queue a message and use Previous/Next to select it. Selection remains independent of the displayed comment. Disable Follow to retain a reading anchor while messages arrive; the feed is bounded to 1,000 messages, 200 favorites and 100 queued items.

Create a Comment Slot in the staged scene, choose it, and use Show or drag a normalized message onto it. Hide changes staged visibility. Take publishes those changes; Direct Live Editing applies them immediately. Resize and style the layer in the inspector. Complete long/Unicode text uses fitted pages rather than clipping; Previous/Next Page stages the selected page and Take publishes it. The full message remains in the queue and scene payload.

Avatar is off by default. When enabled, Show loads only an available supported public provider image with bounded ephemeral fetching; completion still follows the Preview/Take policy. Missing metadata reports a warning, and saved scenes do not preserve avatar URLs or image bytes. Plain emote text remains intact; image emotes and chat alert styling are unavailable. Supported send/reply/delete controls require their actual granted scopes and ownership. YouTube threaded replies and unauthorized moderation remain disabled. Per-provider viewer readings expire or become unavailable; no synthetic zero or remote LIVE state is inferred. The queue is session-local; only slot IDs persist with the profile. Authorized live feeds, avatar delivery and audience visibility still need acceptance.

## Two canvas tutorial

1. Expand **Secondary Canvas** below the main monitors and choose **Copy Program Geometry**. Select 720 × 1280 or 1080 × 1920 while outputs are stopped.
2. Drag layers in Secondary Preview or change their visibility to create independent placements. **Follow Program** removes a layer override; **Link All Geometry** links every layer again. Sources, playback, timers and PDF page selection remain shared.
3. Adjust the safe-zone guides for the destination. Guides never enter recorded or published pixels. **Take** publishes both layouts; staged edits remain in their Preview monitors.
4. In Destinations, select **Program** or **Secondary layout** as the composed canvas, then select the output profile and enabled state. Starting a secondary output requires a configured layout already taken to Program.
5. Use the secondary recording controls for an independent file with the common mixed Program audio. Both recordings and publisher/ISO encoders use one reservation budget, including overlapping file changes. Other Mac classes and full-resolution simultaneous cadence remain qualification gates.

The secondary output is an independent composition. A missing layout produces black; it does not resize or substitute Program. Output dimensions stay fixed while its output demand is active. The [dual-canvas contract and native pixel/timing checks](DUAL_CANVASES.md) describe routing, privacy and remaining portrait-service/consumer qualification.

## Deliberate ending

Destinations exposes **Stop Local / End Remote / End All**. Stop Local detaches captured publisher sessions and sends no provider completion request; the provider may still apply its own disconnect/auto-stop policy. End Remote freshly verifies and completes a supported permitted YouTube event while local publishing continues. End Both/All reports each remote/local result independently; unsupported connectors require their manual provider controls. Recording continues.

A failed preliminary check or lost/sent/cancelled reply leaves remote state unknown. Receipts become visibly stale after 60 seconds; Review Remote reads state without retrying a mutation. An optional saved outro or black scene goes through Select Scene/Take and the normal transition. Program or output-session changes cancel delayed ending, and restart never replays a plan. Provider completion can extend the minimum hold. See [clean ending authority, receipts and validation](CLEAN_ENDING.md); no real public provider completion has been qualified.

## Qualified evidence and limits

| Area | Reproducible software evidence | Qualification boundary |
| --- | --- | --- |
| Native media | Mac15,8, Apple M3 Max, 16 CPUs, macOS 27.0.1; decoded H.264/AAC MP4, MOV/HEVC and WAV/M4A, static-source cadence, bounded failures and paired small canvas files | Specific local observations only. Other Macs, oldest deployment OS, physical capture/unplug, sustained thermal/network workloads remain unqualified. |
| Platform builds | Unsigned StreamMac/shared suites on Apple Silicon and Intel CI; retained iOS simulator/shared checks | Build coverage does not qualify physical devices, signed sandbox installation or macOS 14 runtime behavior. |
| Providers | Protocol validation and independent injected publishers; granted-scope YouTube/Twitch account/public-chat HTTP/WebSocket fixtures; Restream public-event fixtures | No live-provider account, ingest, public feed, remote completion or audience acceptance is qualified. Missing approvals/scopes stay gated. |
| Optional adapters/outputs | Explicit prerequisites, native lifecycle and bounded-frame fixtures; native virtual-camera/microphone source builds | Installed/signed device consumers, NDI/DeckLink/Zoom/browser guest media and physical display/AirPlay behavior remain separate gates. |
| Controllers and transfer | Shared dispatcher, stable IDs, actual local sockets and profile/package/recovery fixtures; Stream Deck SDK simulation | Physical Stream Deck/Plus, signed helper pairing, native share/editor/picker and VoiceOver flows still need manual qualification. |

The supported deployment floor is macOS 14; it is not a certification matrix for every Mac or provider. Reproduce the linked native harnesses and [performance baseline](PERFORMANCE_BASELINE.json) with Mac model, OS/toolchain, profile dimensions and diagnostic output. Export Diagnostics for bounded allowlisted counters/configuration and recent lifecycle events; inspect recording journals for actual track/gap/failure evidence. Do not include credentials or captured media in a support handoff unless deliberately chosen and redacted.

## Interrupted-session review

At launch, Recovery reviews the last unclean session without starting streams, recordings, macros or cues. The machine-local checkpoint contains project/profile IDs, scene/layer geometry and visibility, paused media/PDF positions, output IDs and bounded recording journal basenames. It excludes tokens, endpoints, source payloads and machine grants.

Choose Restore Local Context to explicitly open the saved project/profile and restore available references. Missing or deleted content needs Backup History or relinking; recovery does not recreate unsaved layers, text or effects. Review Recordings opens the attached library. Local connection state cannot establish whether a remote provider event ended or can reconnect. Normal Quit drains the recorder, stops outputs and saves final metadata; a blocked writer or inaccessible drive retains a conservative recovery record.


A local Developer ID signing check can run before notarization credentials are available:

```sh
STREAM_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
STREAM_NOTARIZE=0 zsh apple/scripts/package_desktop_release.zsh
```

This explicitly produces a signed, unnotarized development qualification artifact. It does not staple or claim Gatekeeper acceptance. The default remains `STREAM_NOTARIZE=1`, requiring an existing `STREAM_NOTARY_PROFILE` and completing submission, stapling and Gatekeeper assessment.


For the current desktop entitlements, install a **macOS Developer ID** provisioning profile authorizing `com.joeblau.StreamMac`, `group.com.joeblau.Stream`, and the declared Keychain access group. Set `STREAM_PROVISIONING_PROFILE` to its exact name or UUID; the release script passes it to the app-only `STREAM_MAC_PROVISIONING_PROFILE` build setting and includes it in export options. An iOS development profile cannot satisfy this requirement. Keep these entitlements intact when provisioning; removing them would change access to existing credentials and legacy settings.

On 2026-10-02 the local Developer ID certificate was present, but no matching macOS profile was installed and the Xcode developer-account session could not load valid credentials. Manual archive stopped at provisioning; automatic signing also rejected the explicit Developer ID identity. A signed/notarized artifact has therefore **not** been qualified. The unsigned app and native integration fixtures build and pass with Xcode 27.2 (27B5019j).
