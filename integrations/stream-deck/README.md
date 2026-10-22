# Stream Studio for Stream Deck

A first-party macOS plugin for Stream Studio's version 1 [local control protocol](../../apple/docs/LOCAL_CONTROL_IPC.md). One authenticated loopback connection serves every visible action on every connected device. Commands use the studio's current capabilities and shared dispatcher; keys display state acknowledged by the studio.

Requirements: macOS 14 or later, Stream Deck 7.1 or later, and a Stream Studio build with Local Control. The plugin uses the official Elgato SDK 3.0.1 and the Node 24 runtime bundled with Stream Deck. It supports keypad actions and Plus encoder actions. Device delivery and profile import acceptance are reported separately from the SDK protocol checks.

## Install and pair

1. Build the package below, then open `dist/com.joeblau.stream-studio.streamDeckPlugin` to install it in Stream Deck.
2. Open Stream Studio. In its Local Control panel, enable the server and pair a client named “Stream Deck.” Copy the pairing JSON while the token is visible.
3. Drag **Stream Studio → Studio Command** onto a key. Paste the pairing JSON into its property inspector and select **Save Pairing in Keychain**.
4. Choose a command from the live category/search selector. The key stores the command's stable ID and the current project's ID. Pairing is shared across keys and devices.
5. Add **Open Studio** to launch or focus the native studio window using macOS Launch Services.

The pairing token is stored in macOS Keychain by a universal native helper. It is sent once per connection, through the local protocol's authentication request. Tokens are excluded from Stream Deck settings, exported profiles, plugin logs, and project files. The property inspector clears its pairing text field after a valid JSON paste is submitted. macOS may request Keychain access, particularly for development builds or after changing the helper's signature.

Revoke the client in Stream Studio to remove access. **Forget pairing** in the property inspector removes the plugin's local Keychain credential. To uninstall, remove the plugin through Stream Deck and revoke its client in Stream Studio; use **Forget pairing** before uninstalling if its Keychain entry should also be removed.

## Commands and feedback

**Studio Command** discovers scenes, Take, output controls, layer visibility, audio controls, playback, and show macros that the running studio exposes. New dispatcher commands appear without a plugin update. Commands that are temporarily unavailable show their current reason. Unsupported capability notices cannot be selected. The app performs the authoritative availability check for every execution.

Scene keys show **PVW** for the staged scene and **PGM** for the program scene. Output keys distinguish idle, connecting, live, reconnecting, failed, recording, preparing, and paused states as reported by the app. Recording keys show **REC IN n** during the native recording countdown. Layer keys show visibility; macro keys show progress. An **UNAVAILABLE** label distinguishes command availability while retaining the current tally. Pressing a key never invents live or recording tally. Colors supplement visible text.

The current catalogue additionally exposes next/previous scene, explicit direct-live/preview policy, recording pause/resume/new-file/marker, explicit layer/group/global-overlay show/hide, visual-effect bypass, configured AU slot bypass, PDF next/previous/first/jump, playlist previous, and camera reactions on explicitly identified compatible devices. Gain keys configure a linear percentage from 0 to 200. PDF jump keys choose a page (the UI is one-based); recording marker keys accept optional text. All actions validate fresh stable resources and retain the native preview/program, source-sharing, permission, and recording rules. Comment previous/next/show/hide use the studio's actual queue and selected comment slot. Showing/hiding a comment stages it; **Take** publishes it. **SLOT PVW/PGM** reports actual slot visibility, not audience delivery.

**Audio Level Dial** uses native microphone, media, and program/monitor/aux bus gains. Select a live level target and a linear percent-per-tick in the inspector. Rotation batches for 50 ms, then submits a bounded relative adjustment applied against authoritative host state. Two encoders controlling the same target cannot overwrite each other's increments. Press or tap toggles its paired mute command; hold the touch strip to reset to unity (100%). The `$B1` layout shows the current channel, gain percentage, mute state, and level bar. Deltas are never replayed after a lost acknowledgement or reconnect. Page/device removal discards unsent rotation.

**Scene / Layer / Overlay / Sound Dial** selects a live resource category and stable starting target. Rotation browses without activating; press or tap activates the selected resource. Overlay browsing uses the actual global overlay visibility commands and shows **GLOBAL ON** or **HIDDEN** after the studio acknowledges the change. The `$A1` layout displays the current resource and studio tally. Deleting a selection shows Missing Resource and refuses activation; rotating again is the explicit choice of another resource. A project switch requires explicit rebinding.

Rundown play/pause/stop/skip and individual **Run Cue** commands appear in the same live catalog. Bind a configured scene cue's stable ID to run its native scene/transition/automation behavior. Resource selectors update after rename and deletion. Live feedback updates preserve unfinished gain, page, and marker edits in the property inspector; only an acknowledged binding change replaces them.

Recipe examples for local setup: a **stream** page with scene selections, Take/Revert, explicit Start/End Stream, mic mute and a monitor dial; a **record** page with Start/Stop/Pause/Resume/New File/Marker, PDF navigation and a mic dial; an **interview** page with guest admission, Program/Monitor permission, mute/solo, screen approval, removal and queued-comment controls. Guest keys show waiting/backstage or actual local Program permission; service on-air metadata alone never displays Program permission. Monitor and screen keys show their acknowledged route/approval, and removed guests become unavailable even while a catalogue refresh is pending. Program permission does not prove that a guest layer is visible or that an audience received it. Producer-authored preset-chat controls target the current supported YouTube/Twitch reader and show actual provider acknowledgement or an unconfirmed/refused outcome; they never echo a send into the public queue. Configure UUID targets in the inspector, then export these pages from Stream Deck. Three deterministic 15-key starter profile candidates are bundled; actual application import acceptance remains pending. The [profile guide](profiles/README.md) documents their public MIT template, generation, explicit project rebinding and remaining importer/package lifecycle checks. They are not claimed editor exports. Actual package install/update/uninstall and the declared device configurations still need qualification; Marketplace submission is a separate release action.

Renaming a resource updates its title while retaining its stable binding. Deleting a resource shows **Missing Resource**. Switching projects shows **Project Changed** until the operator explicitly chooses a command in that project. Bindings are never silently redirected to the scene in the same position.

Unpaired, disconnected, incompatible, and revoked states are visible. Reconnecting fetches a fresh snapshot and catalog; queued, interrupted, and completed production commands are never replayed. A rejected key press shows Stream Deck's alert and a property-inspector explanation. Repeated held-key events are suppressed per instance. Keys leaving a profile, folder, page, or disconnected device stop receiving image updates.

## Build and validate

On macOS with Xcode command-line tools and Node 24:

```sh
cd integrations/stream-deck
npm ci --ignore-scripts
npm run check
npm test
npm run package
```

Dependencies and tooling are pinned in `package-lock.json`. The build bundles the official SDK and compiles the Keychain helper for both Apple silicon and Intel macOS. It generates the original icons and runtime license notices. `npm run package` builds, validates with Elgato's CLI, and creates the `.streamDeckPlugin` artifact in `dist/`. The source tree excludes binaries, dependencies, packages, credentials, and generated logs.

`npm test` exercises the production native client over actual TCP sockets and the bundled plugin against a simulated Stream Deck WebSocket service. It verifies discovery/rename/delete/project changes, paused/countdown and connection feedback, incompatible responses, no replay on reconnect, independent keypad and Plus instances, held suppression, tick batching/shared-channel deltas, press/touch, overlay browse-before-activation with global tally, safe settings, page removal, and device removal. The actual inspector script also runs against a DOM/WebSocket fixture to verify missing-resource states and draft editing during live updates. Tests replace the native helper inside an isolated fixture and never access the user's Keychain. `apple/scripts/run_studio_local_control_harness.zsh` also checks native value/delta/PDF/marker arguments and rejection through actual Network sockets. `apple/scripts/run_studio_deck_native_harness.zsh` builds the real studio source graph and verifies staged layer/group commands, native gain/mute, and queued-comment Show/Take/Hide feedback without starting outputs.

## Release qualification

The development package is installable and passes the official manifest validator. Automated SDK simulation does not qualify a physical device or a signed release. Before distributing a public release:

- Verify pairing, Keychain access, revoke/re-pair, and launch/focus using the signed studio and signed helper on Apple silicon and Intel Macs.
- Test Stream Deck restart, app restart, sleep/wake, USB disconnect/reconnect, profile/folder changes, renamed/deleted targets, recording pause/resume, and repeated presses on physical hardware.
- Test Plus encoder and touch-strip behavior, including multiple encoders and dropped acknowledgements, on physical hardware. Test Mobile, Pedal, and Virtual Stream Deck configurations separately; SDK fixtures do not qualify every device.
- Increment the manifest/package version, sign `com.joeblau.stream-studio.sdPlugin/bin/keychain-helper` with the distribution identity, and validate/pack that signed build without rebuilding the helper afterward. Preserve the generated third-party notices.
- Review Elgato's current Marketplace submission requirements and publish through the authorized release process. No Marketplace publication is performed by this repository's build.

For signing, build first, apply the release's Developer ID signature to the universal helper, then use `npx streamdeck validate com.joeblau.stream-studio.sdPlugin` and `npx streamdeck pack com.joeblau.stream-studio.sdPlugin --output dist --force`. Exported profiles carry stable bindings only; importing into another project requires explicit rebinding.

Remaining #152 criteria: actual starter-profile import acceptance and package install/update/uninstall/configuration qualification. Generation and protocol tests alone do not close the issue.

Scene and destination/event transport behavior, explicit multi-actions, native ending confirmation, and receipt meanings are described in [Transport actions](docs/transport-actions.md).
## Guest, comment, profile and audience controls (D07)

Saved `guest.slot.<UUID>.*` keys follow the configured slot through rename and a future explicit rejoin. Admit, mute/unmute, monitor solo/clear solo and Remove use the currently assigned guest. A stale queued press is rejected using the exact host/guest/media generations; reconnect never replays admission or moderation. Offline slots remain usable for **Add to Preview Layout**, which adds ordinary editable camera/name/title PIP layers and requires Take. Assign a waiting invite to a prepared slot in Guests before using its Admit key. Native admission retains its existing one-guest capacity.

**Show Latest Public Comment**, queued selection/Show and Hide stage the actual public queue into the selected comment layer. Provider **Chat Presets** send saved producer text through the currently authorized supported reader, actual scopes and write receipt. Editing/deleting the preset, replacing its account/broadcast/reader, or retiring the show invalidates a captured write. No incoming private message or automatic send becomes a preset.

**Show Profiles** lists all saved profiles in the current show (at most50), preserving its complete catalog even when the machine catalog contains200 shows/10,000 profiles. Separate show switching remains in the studio. These keys can select another profile in the same show after a prior profile switch. Active output/recording, setup/permission choices, package work and active macros block switching. **REQUESTED** means the old runtime accepted the operation; **CURRENT** requires feedback from the actual replacement runtime. Lost acknowledgement never retries a profile switch. Old players, audio pumps, listeners, provider readers and guest authority retire with the profile graph. Connection-sensitive guest, preset-write and profile controls require an explicit press and are excluded from delayed macro steps, which would otherwise re-resolve replacement connections.

Audience controls display actual cached per-destination provider readings, including zero, unavailable, expired and clock-changed states. Multiple services are labeled **N SOURCES** and never summed. **Local Live Elapsed Time** uses acknowledged local publisher starts; **Publishing Connection State** describes local publisher lifecycle, not audience delivery or a made-up network throughput score. Native one-second snapshots and local feedback aging expire stale readings without additional provider requests. Display-only audience keys request a snapshot when pressed and cannot mutate the show.

Controller settings/exported profiles contain stable command/project IDs and typed arguments only. Per-press authority, provider scopes and live connection generations remain ephemeral. Automated actual native dispatcher/Worker/provider-decoder fixtures and bundled Elgato SDK lifecycle tests validate these paths; they do not assert a live provider account or physical device was authorized.
