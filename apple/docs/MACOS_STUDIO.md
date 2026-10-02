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
provider must be checked against that provider. Optional NDI, DeckLink, Zoom,
virtual devices, browser interview service, and provider account integrations
are still separate qualification work; installed AVFoundation/Continuity Camera
and Syphon paths do not imply those integrations are supported.

## Optional outputs and automation

Recording presets and stable isolated-track selections belong to the active
profile. The selected recording folder remains a machine-scoped permission.
Isolated microphone/application/system tracks select pre- or post-insert audio;
WAV and M4A files share program pause, rotation, and host-clock alignment. A
missing source fails its own track while the program recording continues.
Web-widget audio needs an actual capture channel or a selected system mix.

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
Optional system/device extensions will need their own packaging/install checks
before inclusion in a release.

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
CPU, memory, thermal state, and estimated encoder use identify resource pressure.
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

The sidebar and Settings share one runtime-owned Restream session. Configure the Restream app in Settings, then connect the sidebar. Only public documented events enter the feed; private whispers and unknown event kinds are excluded. Connection identifiers separate destinations, with provider message IDs used for replay deduplication when available.

Filter by platform, destination, author or event type; search author/message text and favorite messages. Queue a message and use Previous/Next to select it. Selection remains independent of the displayed comment. Disable Follow to retain a reading anchor while messages arrive; the feed is bounded to 1,000 messages, 200 favorites and 100 queued items.

Create a Comment Slot in the staged scene, choose it, and use Show to replace its text. Hide changes staged visibility. Take publishes those changes; Direct Live Editing applies them immediately. Resize and style the text layer in the inspector. Avatars, image emotes, automatic long-message layout, direct provider sessions, replies, moderation and viewer metrics remain unavailable. The queue is session-local; only slot IDs persist with the production profile.

## Interrupted-session review

At launch, Recovery reviews the last unclean session without starting streams, recordings, macros or cues. The machine-local checkpoint contains project/profile IDs, scene/layer geometry and visibility, paused media/PDF positions, output IDs and bounded recording journal basenames. It excludes tokens, endpoints, source payloads and machine grants.

Choose Restore Local Context to explicitly open the saved project/profile and restore available references. Missing or deleted content needs Backup History or relinking; recovery does not recreate unsaved layers, text or effects. Review Recordings opens the attached library. Local connection state cannot establish whether a remote provider event ended or can reconnect. Normal Quit drains the recorder, stops outputs and saves final metadata; a blocked writer or inaccessible drive retains a conservative recovery record.
