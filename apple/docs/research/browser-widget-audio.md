# Browser widget audio and interaction

A12 #124 remains open. The production independent audio route is not qualified. A separately launched helper and bounded PCM/mixer qualification prototype are now available; the product picker remains disabled.

Visual widgets now use the bounded [public PDF raster path](../NATIVE_BROWSER_RASTER.md), which qualifies transparent DOM, representative media and actual Program recording pixels. The previous `helperApp` option silently played inside the studio WebKit process through system output, despite being labeled an independent channel. That substitution is removed. Persisted helper-route widgets stay silent with an inline unavailable message, and the picker disables new selection of that route. Explicit System Mix remains available through the existing A06 routing controls.

Muted/unavailable routes use [WebKit's public media suspension API](https://developer.apple.com/documentation/webkit/wkwebview/setallmediaplaybacksuspended(_:completionhandler:)) in addition to autoplay restrictions and media-element muting. Apple documents that page/user playback cannot resume until the host lifts suspension. This also suspends video-element playback; CSS/DOM animations continue. Stop suspends and unloads the page. Snapshot generations reject late completions after Stop/Reload, avoiding restarted capture and negative in-flight accounting.

Frame identity now hashes the complete normalized configuration. Widgets with the same URL but different viewport/audio/interaction/CSS settings cannot overwrite one another; legacy URL-only payloads still resolve correctly. A bounded identity cache avoids encoding full CSS every render tick and does not put widget URL credentials in the frame-store key.

Interactive pages now reparent into an embedded inspector scroll view. The same WKWebView keeps its original viewport and context; it is not duplicated into another page. Closing the inspector restores the hidden click-through render host. No visible floating interaction window is created. Reload and Replay stay in the inspector.

The actual sources compile in the native app and `scripts/run_browser_lifecycle_harness.zsh`. The harness checks reparenting, absence of a floating interaction window, route warnings, and stopped-page/output state on a logged-in Mac. The earlier lifecycle-only run lacked a WindowServer session. The local helper qualification below uses an existing logged-in session and grant; it does not change permissions.

## Independent audio gate

The remaining route needs a dedicated, signed helper app with its own bundle identity, owning both widget page execution and audio. A shared channel for all helper widgets is an acceptable initial identity if explicitly labeled. Validate ScreenCaptureKit attribution of that app and its WebKit audio before committing the helper architecture: a distinct bundle ID alone is not evidence that child-process sound is correctly attributed.

Then wire helper PCM through the existing mixer conversion path, exclude the helper from system capture, and verify gain, mute, monitoring, recording, refresh/stop/hide lifecycle, and timestamps. Use two named tone/speech widgets plus an unrelated application and program monitor return. Record program/isolated/monitor buses to prove no duplicate capture and no unintended muting. This needs an unrestricted signed-app session with Screen Recording access; neither a missing helper nor failed capture may fall back to whole-system audio.

## Public API review and helper prototype (2026-10-02)

Apple's [ScreenCaptureKit audio policy](https://developer.apple.com/videos/play/wwdc2022/10155/) operates at application scope, including when a filter selects one window. The prototype therefore names one shared channel, **Browser Widgets (shared helper)**, rather than claiming separate widget PCM taps. Each helper page still has its own stop, reload, suspend, and resume commands.

[Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) can capture selected process outputs and require a separate audio-capture permission. The macOS 26+ [`CATapDescription.bundleIDs`](https://developer.apple.com/documentation/coreaudio/catapdescription/bundleids) property selects process bundle identities. It does not establish ownership of one WKWebView. The measured WebAudio process is `com.apple.WebKit.GPU`, and WKWebView exposes no public audio-process PID mapping. A global WebKit-bundle tap could include unrelated browsers and is not used. This run only enumerates process objects; it creates no process tap and requests no TCC change.

`BrowserAudioHelper/BrowserAudioHelperMain.swift` owns up to eight ephemeral WKWebViews. It uses public WebKit media suspension, unloads only the selected page on Stop, and rejects late navigation completions for removed pages. URLs/HTML are bounded private IPC content, never response/log metadata. The replies are fixed state categories. The audio-only fixture has visible test windows. The same-page backend below uses hidden windows; a helper target is embedded but its product route remains disabled.

The helper is launched through `NSWorkspace.openApplication`. A private Unix socket lives in a fresh 0700 directory, with a 0600 socket and same-user/exact-launched-PID peer validation. Launching an executable directly with `Process` is an invalid attribution candidate in the measured session: both helper-app and helper-window SCK filters captured the independent native 1320 Hz fixture instead of the widgets' 440/880 Hz tones. Those samples were rejected and discarded. Proper Launch Services launch captures the two WebAudio widget tones and excludes the independent fixture. An app bundle identifier or a successfully started SCStream alone is insufficient evidence.

`BrowserWidgetAudioCapture.startForQualification(helperPID:)` verifies the exact live helper PID/bundle and the public filter's selected identity. It registers only app/window filters, with current-process audio excluded; there is no whole-system capture branch. The inlet accepts ordered 48 kHz stereo LPCM, retains at most eight buffers / 200 ms / 256 KiB, and drains on its own queue into the existing `AudioMixEngine` conversion path. It counts rejected, shed, and shutdown-discarded buffers separately. SCK's constant-frame PCM can report zero sample-size entries, so memory accounting uses the retained block size and cached per-buffer sizes.

The opt-in helper lease reserves 80 ms of mixer delivery holdback; capture starts locally arrived up to approximately 50 ms after their original host PTS. Existing routes retain the default 5 ms margin. Multiple leases use the maximum, bounded to 100 ms within the existing ring. Holdback delays delivery without changing capture or bus timestamps, and stop releases the lease. `captureTimingSnapshot()` exposes the effective delay and lease count. The program, monitor, and ISO taps keep one media clock.

Native qualification also exposed and repaired monitor setup defects: the player graph must use non-interleaved PCM, and scheduling must wait until the graph starts. Bus/recording PCM stays unchanged; only the monitor player splits channels. Graph changes serialize with scheduling and old playback completions cannot corrupt a new generation's counters.

Run `scripts/run_browser_audio_helper_harness.zsh` for the read-only inventory, bounded protocol, and PCM-overload checks. Add `--qualify` to build ad hoc helper/independent fixtures, launch them through Launch Services, emit quiet named tones, and exercise the actual capture/mixer/monitor paths. `--direct-process-negative` deliberately measures the rejected executable-launch architecture. `STREAM_VENDOR_ROOT` and `BROWSER_AUDIO_BUILD_PATH` support isolated builds. A missing existing Screen Recording grant, WindowServer session, public SCK display, output device, or measured identity produces an explicit unqualified gate; the runner never changes TCC or the default audio device.

The qualification uses a Mac15,8 Apple M3 Max on macOS 27.0.1 with Xcode 27.2 beta. Read-only preflight found a logged-in WindowServer session, an existing screen-capture grant, and four audio devices with defaults present. This is one ad hoc local helper result, not a claim about all signed app/device/OS combinations.

The complete native tone run passes: 440/880 Hz retain stereo layout and match program/ISO levels, while the separately identified 1320 Hz application's leakage is below 2% of its measured control level. A unique 1000 Hz return is played through a second real monitor path and remains absent from helper capture; both monitor players report completed hardware playback. Half gain, mute with pre-fader ISO continuing, monitor gain, and per-page suspend/resume/reload/stop preserve the sibling widget and independent app. The live PCM inlet has zero overload loss/rejects, and program/ISO outputs share exact host timestamps. Five generated CAF files are reopened and their stereo sample rate, frame count/duration, and ordered timestamp metadata are checked. The slower-consumer fixture separately proves bounded, counted overload and stale-generation rejection.

## Remaining product integration gates

`productionRouteQualified` stays false. The qualification backend now owns **one page/state for both pixels and audio** and provides the bounded bridge described below. The supported in-app muted/System Mix backend remains separate. No duplicate widget page is loaded beside the helper. Bundled signing/sandbox IPC and final runtime/source routing still require qualification. Workspace/App/MainWindow are unchanged.

Demand, shared-channel mute/gain/monitor/ISO controls and unavailable states are now wired for explicit qualification sessions; see [operator controls](browser-widget-operator-controls.md). All concurrent system/screen-audio routes still require acknowledged exclusion before production enablement. `requiredSystemAudioExclusions` exposes the identity but does not silently alter any route. No helper failure may mute unrelated applications or substitute system audio.

Before enabling the product route, qualify generated media with the same-page visual/audio timing, signed app packaging and permission lifecycle, system-mix exclusion, named speech/media fixtures, effects/viewport/interaction workloads, supported devices/OS releases, and sustained operation. The local tone prototype does not satisfy those remaining gates, so #124 remains open.


## Same-page visual and interaction backend

`BrowserWidgetHelperSession` is an explicit qualification owner. `BrowserOverlayHost` accepts that session only for a helper-route widget; its in-app `webView` and window are nil for this backend. One LaunchServices helper owns each page's DOM, media context, viewport, CSS, native input and snapshots. The inspector receives a `BrowserWidgetRemoteInteractionView`, which shows existing frame-store pixels and forwards deliberate local mouse, key and wheel events to that same page. No global event posting, accessibility permission or duplicate WebKit page is used. Programmatic triggers and their ephemeral results are bounded private IPC, not diagnostic/archive content.

The shared session launches lazily on first demand. A host's start/reload creates a new page generation; keep-alive scene entry preserves the original page. Stop unloads only that page and immediately clears its frame store. Last demand closes the helper and both connections, stops audio and releases its holdback. Unexpected helper/page/audio failure reports a fixed category, clears frames and releases owned resources; unrelated sources and network outputs are untouched. An external owner retains the session until `waitUntilStopped()` completes. `BrowserOverlayHelperBackend.qualificationSession` is a nil-by-default seam that lets the existing capture pool's host creation/start/stop paths use this backend in an explicitly arranged qualification runtime; no launch setting or saved preference installs it.

Both command and visual Unix peers are checked against the exact launched PID and user. Frames use a separate binary connection so image transport does not block the audio inlet or command reader. The consumer pulls at most one frame at a time; the producer retains at most two reservations across WebKit snapshot callbacks and serialized writes. BGRA frames have validated 16…1920 by 16…1080 dimensions (at most 8,294,400 bytes), a 2 KiB header, exact pixel byte count, request UUID and page generation. Unsupported larger product viewports fail explicitly. Headers/bodies have five-second deadlines; malformed lengths are rejected before allocating. The receiving pixel pool has a three-buffer ceiling per demanded widget, with eight widgets maximum. Producers shed locally under pressure instead of accumulating work; failures and stale generations never restart a stopped page. Each header records actual host-clock snapshot request and completion times, with no claim that a WebKit snapshot is an exact media-frame timestamp.

The helper uses [local AppKit event dispatch](https://developer.apple.com/documentation/appkit/nswindow/sendevent(_:)) and now the [public PDF rasterizer](../NATIVE_BROWSER_RASTER.md). Earlier `WKSnapshotConfiguration` measurements below produced opaque white despite `underPageBackgroundColor = .clear`; those historical results remain useful, but the current PDF path preserves actual transparent/half-transparent pixels. The production in-app host and helper share that renderer without the older host's private `drawsBackground` KVC switch.

### Historical public WK snapshot alpha result (2026-10-21)

Before the PDF implementation, `scripts/run_browser_snapshot_alpha_harness.zsh` built the helper and a generated candidate that changed only public NSView behavior: `isOpaque == false`, a nonopaque clear backing layer, the existing clear window and `underPageBackgroundColor = .clear`. The current runner uses the shared PDF renderer for both variants and requires alpha preservation. It uses bounded command/frame IPC and validates the exact child PID. Executable launch is valid for this pixel-only experiment; it makes no app-audio attribution claim. It does not install/sign an app, capture/play audio, request permissions or change preferences.

On Mac15,8 / M3 Max, macOS 27.2 (26B118), Xcode 27.2 (27B5038j), both earlier WK snapshot variants produced:

| Actual CSS region | Premultiplied BGRA snapshot bytes |
| --- | --- |
| Transparent page corner | `[255,255,255,255]` |
| Half-transparent green | `[127,255,127,255]` |
| Opaque red | `[0,0,255,255]` |
| Intentionally opaque white | `[255,255,255,255]` |

The transparent corner and legitimate white content were identical after WK snapshotting. Removing white afterward would also remove real white widget content. That unsuccessful opacity candidate was not used as a transparency fix. The later public `WKPDFConfiguration.allowTransparentBackground` path preserves the original alpha; see the [measured raster qualification](../NATIVE_BROWSER_RASTER.md).

Each actual helper image is composited over magenta and encoded as 30 H264 frames with 96,000 frames of fixture-generated stereo 1000 Hz PCM. Native AVAssetReader reopens both two-second H264/AAC files and records counts/levels in `report.json`. The historical WK snapshot version exited **77 UNQUALIFIED** because white survived encoding. The current public PDF version exits 0: raw corner alpha and half-green are preserved, and the decoded corner matches an opaque same-frame codec reference within the existing tolerance. This is actual pixel/transport/composition/file evidence with **synthetic PCM**, not WebKit audio capture or WebAudio synchronization qualification. PNGs, movies and JSON remain in the reported build folder; `BROWSER_ALPHA_BUILD_PATH` selects an isolated output folder.

The existing `run_browser_audio_helper_harness.zsh` inventory/protocol/inlet checks still run independently. Read-only and retained-media modes now skip the unnecessary ad hoc helper build/sign operation; the existing helper build runs only with explicit `--qualify`. No signing configuration or capture policy changed.


The `StreamBrowserAudioHelper` target is packaged in `StreamMac.app/Contents/Helpers` with an independent bundle ID, hardened-runtime setting, and sandbox/network/shared-App-Group entitlements. The app builds with this target embedded. The current native fixtures use ad hoc unsigned-sandbox qualification helpers; a successful unsigned app build does not prove Developer ID profiles, notarization, sandbox enforcement, shared-container IPC access or a shipped permission lifecycle. Release packaging accepts `STREAM_BROWSER_HELPER_PROVISIONING_PROFILE` for the helper bundle and includes it in archive/export profile mapping. The bundle audit checks the embedded helper executable and declared sandbox/App Group; those checks do not validate actual signed IPC. The production transport now fails closed through the declared shared-container and signed-peer policy described below. Private `/tmp` sockets exist only in validation-compiled prototype transport. Actual provisioned shared-container access with the signed app still needs validation before enabling the route.

Run `scripts/run_browser_audio_helper_harness.zsh --qualify --visual` for the actual same-page fixture. It measures an inspector click changing one page from a red button/440 Hz tone to blue/880 Hz while its page nonce remains unchanged, native keyboard and wheel delivery, transparent-backdrop behavior, frame pull overload, keep-alive, reload while a snapshot is pending, and stop/last-demand cleanup. The sibling widget plays a right-channel 1100 Hz tone and a separately identified app plays 1320 Hz throughout lifecycle changes. The helper's actual images and program mixer audio are written through the real H264/AAC writer, then decoded to verify the color/tone transition. Earlier local runs and retained-media decode, before the 2026-10-21 lifecycle hardening below, measured 42–64 ms between the decoded blue frame and 880 Hz event; the test checks a 180 ms fixture envelope. Native unexpected-helper exit and re-demand also clear output and release the helper lease while unrelated audio continues. PNG frames, CAF outputs and bounded frame statistics are also generated. This local test establishes the fixture's measured transition envelope; it does not qualify arbitrary streaming video/speech, DRM, IME, drag/drop or long-running remote widgets.

The [operator shared strip and ISO discovery](browser-widget-operator-controls.md) and [public PDF transparency](../NATIVE_BROWSER_RASTER.md) now have software qualification. Remaining product gates include acknowledged exclusion/capture retirement across **all** concurrent system/screen-audio routes, actual signed launch/IPC/permission lifecycle, authorized helper local HTML subresource access, supported viewport/OS/device coverage, speech/media/effects and sustained operation. Program audio remains separate from pixel demand as described below. The selector stays disabled and #124 stays open.

A later repeat on this same machine reported an existing WindowServer session/grant/output but **zero `SCShareableContent` displays**. The runner now records the read-only display count and explicitly prints `GATED / UNQUALIFIED` before launching capture fixtures when that prerequisite is absent. This repeat is not a passed capture qualification. Successful earlier decoded artifacts remain the evidence for the limited local result; no permission, display or default-device repair was performed.

Retained media can be checked without a live capture session using `--inspect-visual-recording /path/to/same-page-program.mp4`. This checks actual decoded H264/AAC color/tone timing and labels the result as artifact validation, not a new live browser/capture qualification.


### Program lease and captured-PCM lifetime hardening (2026-10-21)

The actual controller now derives helper audio leases separately from its union of Program, Preview, standby/fallback and ISO pixel demands. Only current visible Program layers/project overlays and genuinely demanded Secondary output pages authorize helper playback. Preview/standby/ISO-only pages remain suspended. The controller retains the shared `.application(helperBundleID)` channel rather than pruning it as `.capture(.web(...))`; preserving a channel/fader does not authorize playback.

A page starts with public WebKit media suspension established **before** its HTML/URL loads. The session serializes each material Program boundary: synchronously close source authority and invalidate the inlet, await the old inlet/capture drain, reset channel rings/converters/FX signal history, acknowledge every removed page's generation-correlated retirement and all current pages' suspension, start the shared capture while pages are suspended, then acknowledge Resume only for current Program leases. It opens the native mixer gate only after all current acknowledgments. The helper retains a retiring WKWebView until public playback-suspension completion, closes only that view, and acknowledges Stop with its original generation/request. A stale Stop cannot kill a replacement page. Direct replacement loads wait for that same retirement barrier.

The source gate has its own short lock: revocation never takes the registry or channel lock held by an opaque insert. The final bounded sample-add loop acquires authority **after** the channel lock. Closed routes cannot contribute to Program, Monitor, Aux, guest return, either ISO or duck sidechain. ISO mailboxes also compare original output PTS to the closed boundary, so a retained old frame cannot become authorized merely because the route reopens. The source capture-PTS floor survives channel replacement; fresh-inlet buffers carrying old/invalid/future source timestamps remain rejected. Inserts, user fader, solo, delay and send configuration survive the post-drain history reset. No source timestamp or mixer clock is restamped.

Reload/stop revoke the old page before a replacement Task enters. The host checks cancellation/current generation, the session owns per-widget load claims across retirement/shutdown awaits, and shutdown cleanup is keyed to the exact shutdown generation. Queued or late capture-start completion cannot reopen an obsolete Program lease.

`requiredSystemAudioExclusions` now feeds actual system-mix exclusion calculation and the effective screen privacy settings. This does **not** prove that an opaque sharing-picker filter or an existing SCK broad route applied those exclusions. Therefore any demanded audio-bearing screen source, system-audio source or explicit helper-app recapture refuses the optional helper audio and exposes an unavailable reason; unrelated captures/audio keep running. The refusal is latched for this explicit qualification-session lifetime. Removing a source from demand is not an acknowledgment that its asynchronous capture/queued PCM has stopped; helper audio must not auto-resume on that assumption. Rebuild the explicit qualification session only after the other captures have fully stopped. A product route still needs an acknowledged install/stop/drain contract and actual every-route recapture measurements.

Run `scripts/run_browser_widget_lifecycle_harness.zsh` for the native capture-free regression. It builds the actual desktop graph with isolated defaults/storage and inert credential boundaries, launches the owned helper through LaunchServices with exact-PID private IPC, and uses silent HTML pages plus a validation-only driver containing the actual bounded PCM inlet. Its capture samples are **synthetic Float32 PCM**, not WebAudio or ScreenCaptureKit audio. The generated capture-start boundaries record real controller settings without starting camera/mic/screen/app capture, opening a sharing picker or requesting permissions.

The 2026-10-21 run on an M3 Max (Mac15,8), macOS 27.2 (26B118), Xcode 27.2 (27B5038j) exits 0. The held opaque insert/real mix-loop case measured a 0.253 ms synchronous authority revocation. The native guest private-talkback/return-PCM regression and read-only helper protocol/inlet suite also pass after the shared mixer changes. The later [public PDF alpha/encoded-pixel fixture](../NATIVE_BROWSER_RASTER.md) exits 0 and verifies an old-generation Stop cannot retire the actual blue replacement page.

The exact native lifecycle invocation used here, from `apple/`, is:

```sh
DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.3.app/Contents/Developer \
STREAM_VENDOR_ROOT=/tmp/stream-macos-vendor-20261021 \
BROWSER_LIFECYCLE_BUILD_PATH=/tmp/stream-browser-lifecycle-derived-20261021 \
scripts/run_browser_widget_lifecycle_harness.zsh
```

The regression exercises actual Program/Preview/Take/reload/shared-channel retention, required exclusion consumption and explicit unavailable state; retired-page acknowledgment hold after the real public WebKit suspension completion; queued and held stale capture starts; an opaque insert held while the real mixer tick waits on its channel; native Program/Monitor/Aux/pre/post ISO silence after retirement; retained ISO frames across close/reset/reopen; source-generation/old-PTS rejection and a real stateful insert tail; exact fader/Aux and original-grid 140 ms delay restoration; concurrent replacement claims with the actual latest helper DOM; cancellation-only cleanup during launch; last-page shutdown; and unrelated native Program PCM while helper capture is unavailable. These software checks do not qualify WebKit media attribution, audible-page suspension/tails in SCK, every-route recapture, actual signed/sandboxed IPC or any new live same-page A/V measurement.

The production selector remains disabled (`productionRouteQualified == false`, no normal startup qualification session). Public PDF pixels now preserve alpha under the documented local bounds. The earlier live same-page fixture explicitly declares both audible pages as Program leases; it must be rerun under a separately qualified signed/capture environment before treating the changed lifetime path as live-qualified.


### Page-generation media command fencing

The existing helper prototype now requires a page generation on Suspend/Resume. The host passes its own current generation; the session rejects callers holding an older lease, and the helper independently rejects a command whose generation differs from the installed page. Rejection is a fixed `stale_generation` category tagged with the attempted generation. Valid asynchronous acknowledgments remain fenced to the same WKWebView identity and carry an optional request ID for correlation.

The capture-free alpha fixture also replaces a real helper page with a blue DOM page, sends both old-generation lifecycle commands and requires explicit stale rejection, then checks current-generation acknowledgments and actual blue-page snapshots. Both shipping and public-opacity candidate pass these checks. The same regression against the pre-fix helper fails because the stale Suspend is accepted instead of rejected. Protocol/inlet regression additionally rejects generationless lifecycle commands; explicit audio-qualification fixtures now supply their page generations. This establishes page-command ownership, not Program-only audio, shared-PCM retirement, FX-tail silence or capture exclusion. No new policy abstraction or production audio route was introduced.

## Lifecycle command backpressure (2026-10-21)

Stop and Suspend/Resume now fail closed when the helper's bounded command queue
rejects the command. Previously those errors were discarded: a removed page
could remain audible while another page's demand kept the shared helper alive.
The session now reports a fixed failure category for its remaining pages and
retires its owned shared helper/capture. Healthy unrelated app-audio sources are
outside this session; no global mute or System Mix fallback is issued. Accepted
commands still target the requested widget, and suspension keeps its page
generation. Normal Stop preserves sibling demand.

`scripts/browser_helper_lifecycle_checks.swift` exercises the shipping session
with an injected command transport that rejects Stop, Suspend or Resume. It
checks visible sibling failure, shared demand retirement and transport closure,
plus successful exact-widget commands and sibling preservation. The existing
browser audio harness invokes these checks. A focused compile of the actual
session, PCM capture, socket and command/visual protocol sources passed on
Mac15,8, macOS 27.2 (26B118), Xcode 27.2 (27B5038j), using mixer/visual-state
fixtures that trap if capture or PCM delivery is attempted. This is command
lifecycle evidence; it starts no helper, capture, monitor or device and proves
no actual audio routing, exclusion, bus levels or A/V synchronization.

The production selector remains disabled. Program-only leases and shared mixer/ISO controls are integrated for explicit qualification; see [operator controls](browser-widget-operator-controls.md). Acknowledged every-route exclusions, signed shared-container IPC and actual tone/speech bus qualification remain required before #124 can close. Existing direct application capture and
permission/availability checks are unchanged.

## Capture operation ownership and Stop completion (2026-10-22)

The capture driver now allocates a run intent before its first asynchronous
retirement. Each run owns a distinct bounded PCM inlet, preparation/start tasks,
producer and mixer holdback reservation. Stop revokes that inlet synchronously,
detaches the exact resources and waits their completion. A producer returned by
late discovery is stopped before Stop returns. If startCapture was already
pending, cleanup stops its exact stream, waits that start to unwind and stops
that same stream again. Stale completion/failure cannot reacquire authority,
release a replacement holdback, invalidate a replacement inlet or report a
failure against the replacement run. Concurrent Stop also waits cleanup already
detached by an earlier Stop.

Run `scripts/run_browser_capture_authority_harness.zsh` for the actual capture
owner and AudioMixEngine actor with only the external SCK producer edges held.
Seven controlled cases cover discovery/Stop, replacement holdback, initial
retirement, successful and failed late starts, concurrent final Stop, and exact
inlet-generation retirement. The callback case posts **synthetic PCM sentinels**
to the actual inlet: late old-run samples are rejected while the replacement
continues. It opens no SCK capture, output device or user media.

Run the same script with `ipc` for the shipping helper launched at its exact
owned app path/PID over the existing private sockets. Two silent WKWebViews load
suspended. Removing one page during a held capture start requires its real
retirement acknowledgment before the sibling resumes; evaluation confirms that
only the sibling survives. Final release waits mixer lease cleanup and actual
helper exit. The script ad hoc signs only its own temporary helper. This is an
**unsandboxed prototype IPC** regression, not signed shared-container provenance,
WebKit audio attribution, capture exclusion or audible routing qualification.
Both modes passed locally on 2026-10-22. The production selector and startup
remain disabled; all original #124 product/audio validation requirements remain
open.

## Production transport policy and peer provenance (2026-10-22)

Normal helper sessions now default to production transport. Before resolving an
App Group container or launching the helper, the host validates its live code
against the Apple-generic signing anchor and fixed host identifier, derives its
verified team, verifies the complete local bundle seal, and requires signed
sandbox/group entitlements without debugger access. It checks the sealed helper
at the exact embedded bundle/executable path against that same team and fixed
helper identifier. Only then does it resolve `group.com.joeblau.Stream` and
atomically create a short owned0700 directory/socket0600 within it. An oversized
UNIX socket path or missing group access fails; there is no temporary fallback.

Both socket directions retain effective-UID/exact-PID checks and obtain the
connection's kernel `LOCAL_PEERTOKEN`. Security.framework resolves the live
principal using that audit token, validates its code requirement, then compares
its actual executable path, identifier, team and CodeDirectory hash with the
sealed expected peer. Both command and frame channels must have the same audit
token/hash principal. The helper derives the production host path from its own
embedded bundle, not an arbitrary path supplied by an argument. It authenticates
both channels before Ready, page content or its command reader starts.

The private `/tmp` policy, prototype launch mode and ad hoc signature factory
compile only with `STREAM_NATIVE_VALIDATION`. Existing qualification callsites
select that policy explicitly, and their helper builders compile the same flag.
The shipped helper rejects prototype/missing/unknown launch mode and never
falls back to stdin/private sockets. Validation-only stdin/frame-only legacy
pixel/audio fixtures remain explicitly prototype; they confer no production
capability. The production selector and normal startup remain disabled.

`scripts/run_browser_socket_authority_harness.zsh` uses actual owned sockets and
Security.framework with ad hoc signed fixture executables. It checks successful
bidirectional pinned identity, wrong PID/path/identifier/hash refusal, a re-sign
at the same path after the authority snapshot, different second-channel process
refusal, and default production rejection of an ad hoc process before group
access. It also retains an actual negative compiler diagnostic proving that the
production policy has no prototype case. Optional
`BROWSER_SOCKET_HELPER_MODE_PROBES=1` builds the actual helper without validation
and checks no Ready/content from refused modes/authority. These are prototype
identity and negative production-boundary proofs, not a successful signed
sandbox/shared-container launch.

The actual silent helper IPC/retirement fixture remains
`scripts/run_browser_capture_authority_harness.zsh ipc`; it explicitly opts into
validation transport. No capture, audio output, permission or default-device
operation is involved. Its two silent WebKit pages use the existing real
suspension/retirement acknowledgments and exact mixer/capture lifetime.

The declared `group.`-prefixed identifier requires macOS provisioning authority;
see [Apple's App Group authorization guidance](https://developer.apple.com/documentation/xcode/accessing-app-group-containers)
and [UNIX socket/group requirements](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.application-groups).
Current local profiles do not authorize this group for the macOS host/helper,
so no positive provisioned sandbox result is claimed. No profiles, entitlements,
identities, containers or trust settings were changed for qualification. Real
signed/group IPC, every-route exclusion/install/stop/drain acknowledgment and
actual WebKit tone/speech Program/ISO/Monitor/A/V measurements remain required;
#124 stays open.
