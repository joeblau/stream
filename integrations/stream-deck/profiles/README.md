# Authoring the sample profiles

The stream, record, and interview samples still need genuine `.streamDeckProfile` exports. These are unfinished local authoring work. Signing and physical-device qualification are separate checks.

Elgato's supported [profile creation workflow](https://docs.elgato.com/streamdeck/sdk/guides/profiles/) uses the Stream Deck application: compose a profile, then export it from Preferences → Profiles. Its SDK can switch to bundled profiles, but cannot create or export profiles. The [official CLI command list](https://docs.elgato.com/streamdeck/cli/intro/) provides plugin creation, validation, and packaging; it provides no profile author/export command. The pinned SDK 3.0.1 profile API and CLI 1.10.1 agree with those docs. `streamdeck create` creates a plugin, and `streamdeck pack` produces a `.streamDeckPlugin`; neither creates a profile archive.

The Stream Deck 7.4.2 application is installed on the development Mac. Use that application's export workflow rather than reverse engineering or manufacturing its private archive format. No claim is made that profile authoring requires release signing or a physical device: Elgato also supports [Stream Deck Mobile](https://docs.elgato.com/streamdeck/cli/intro/). Each exported layout must identify the device configuration on which it was authored and tested.

## Resource-free layouts

These layouts use current native command IDs. Drag **Studio Command** to each key, then choose the listed command in the live inspector. **Open Studio** uses its separate action. Blank positions may remain empty on larger devices; create separate exports for smaller devices instead of asserting universal layout compatibility.

| Sample | Command IDs in suggested key order |
| --- | --- |
| Stream | Open Studio; `output.preview.start`; `studio.take`; `studio.revert`; `audio.microphone.mute`; `studio.scene.previous`; `studio.scene.next`; `output.stream.start`; `output.stream.stop`; `audio.monitor.toggle`; `rundown.play`; `rundown.pause`; `rundown.stop`; `rundown.skip`; `output.preview.stop` |
| Record | Open Studio; `output.record.start`; `output.record.stop`; `output.record.pause`; `output.record.resume`; `output.record.split`; `output.record.marker`; `audio.microphone.mute`; `audio.monitor.toggle`; `studio.take`; `studio.revert` |
| Interview | Open Studio; `comments.previous`; `comments.next`; `comments.show`; `comments.hide`; `studio.take`; `studio.revert`; `audio.microphone.mute`; `audio.monitor.toggle`; `studio.scene.previous`; `studio.scene.next`; `rundown.play`; `rundown.pause`; `rundown.stop`; `rundown.skip` |

The resource-free interview layout focuses on queued comments and scene transport. Native guest moderation, preset chat, show-profile selection, and audience feedback are implemented in the current catalog. Add producer-specific guest-slot, preset, or saved-profile bindings through the live inspector after import; these personalized targets do not belong in a generic starter layout.

These controls need no scene/source UUID, but **Studio Command** deliberately persists the open project's ID. Imported samples must be explicitly rebound in the destination project using the live inspector. Keep this protection; do not invent a wildcard project binding. Tokens remain in Keychain and must never be pasted into settings or archives. For a Plus variant, add an Audio Level Dial bound to the microphone or monitor bus, and export that device variant separately.

## Export, bundle, and verify

1. Install the development plugin, enable native Local Control, pair it, and create each sample on a fresh application profile. Configure the commands above through the inspector. Do not activate output actions while arranging the layout.
2. Use Preferences → Profiles → Export to save each real `.streamDeckProfile` under `com.joeblau.stream-studio.sdPlugin/profiles/`, with names identifying its layout and device, such as `stream-mobile.streamDeckProfile`.
3. Add each export to the plugin manifest's `Profiles` array. Its `Name` is the relative archive path without the extension, `DeviceType` must match the actual authored device, and `DontAutoSwitchWhenInstalled` should be `true`. Use `Readonly: false` so operators can rebind imported settings. See the [official profile manifest reference](https://docs.elgato.com/streamdeck/sdk/references/manifest/#profile).
4. Run `npm run package`; the official validator and packer must accept the actual exports and manifest. Inspect the resulting archive to confirm it contains all sample profiles and no credentials.
5. Import into a fresh profile and project. Verify the original binding cannot operate another project until explicitly rebound; verify every resource-free command resolves in the live catalog. Rename/delete a separately added UUID binding, restart the app and plugin, and verify its stable/missing state. Preserve the exported samples and record the application/device versions used.
6. Perform physical key/dial/Pedal/Mobile tests and signed install/update/uninstall qualification separately. Marketplace upload is a distinct authorized release action. Standalone Marketplace profiles follow Elgato's [profile packaging workflow](https://docs.elgato.com/stream-deck/profiles/packaging/).

No importable sample archives or manifest profile registrations exist yet. This document is an authoring plan, and does not satisfy the exported-profile acceptance criterion by itself.

## Current application authoring check (2026-10-22)

A fresh bounded check used the installed Stream Deck 7.4.2 application and the existing macOS Accessibility grant. The public AX API reported trusted access. The application's **Configure Stream Deck** and **Preferences…** menu actions each accepted AX Press, but their reported window entries were cyclic application proxies: no actual editor window, layout controls, Profiles table, or Export control was exposed. This differs from successfully capturing an owned test window and does not establish that the external profile editor can be operated in the current session. No unlock or permission change was attempted.

The application was initially stopped, was launched only for this check, and was quit afterward. All existing ProfilesV2 and ProfilesV3 file hashes and the installed plugin inventory remained unchanged. No profiles, plugin links, pairing credentials, or production actions were written. Genuine stream, record, and interview exports remain unfinished application authoring work; no private-format archive was manufactured. Complete the supported compose/export/import workflow when the actual editor is accessible. This is not a signing or physical-device prerequisite for authoring.
