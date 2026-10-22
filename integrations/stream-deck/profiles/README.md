# Stream, record and interview starter profiles

Three reproducible `.streamDeckProfile` candidate archives are checked in under
`com.joeblau.stream-studio.sdPlugin/profiles/` and registered in the plugin
manifest. **Actual Stream Deck importer acceptance is pending.** The official
plugin validator and packer are separate checks; they do not certify that the
application imports a profile. These files are development candidates, not
claimed editor exports or qualified release presets.

The original #152 requirement does not require manual export. This producer uses
the V1 action/state structure of Elgato's public MIT
[MemoryGame sample](https://github.com/elgatosf/streamdeck-memorygame/tree/46e9d9080e352a9d9a1ae2811bbb126e8e0bee95/Sources/Profiles),
with its notice in `ELGATO_MEMORYGAME_LICENSE.txt`. The verified public
`Memory.streamDeckProfile` SHA256 is
`f26d68efea92002d7cf7219bdf7f281084062475172c39dd2c5457c05188e04a`.
No operator profiles or credentials are inputs. No MemoryGame actions or artwork
are copied into the starters. Their compatibility with the current importer
must be established; the official sample's age is not a compatibility guarantee.

## Reproduce and inspect

From `integrations/stream-deck`:

```sh
npm run profiles
npm run profiles:check
npm run check
npm test
npm run package
```

`layouts.json` defines the three resource-free command layouts. The generator
uses fixed UUID derivation, entry ordering, ZIP timestamps, permissions and stored
bytes, avoiding compressor-version differences. `provenance.json` records each
archive's hash and its pending import status. The package check compares every
bundled archive with the checked-in bytes and verifies the MIT notice.

These first candidates target the public template's **15-key Stream Deck**
(device model `20GAA9901`, SDK type 0), with rows of five keys. They are not
Mobile, Mini, Plus or Pedal layout exports. The plugin's SDK configuration tests
separately exercise type 0 keypad, type 7 Plus dial, type 3 six-key Mobile and type 5
three-key Pedal event paths; that does not imply these 15-key files fit all devices.

| Starter | Contents |
| --- | --- |
| Stream | Open Studio, preview on/off, Take/Revert, mic mute, previous/next scene, explicit stream start/local stop, monitoring, rundown play/pause/stop/skip |
| Record | Open Studio, recording start/stop/pause/resume/new file/marker, mic mute, monitoring, Take/Revert |
| Interview | Open Studio, previous/next/show/hide queued comment, Take/Revert, mic mute, monitoring, scene navigation and rundown transport |

The interview starter does not invent guest identifiers. Add configured guest,
chat preset and saved-profile targets through the live inspector in your show.

## Explicit project rebinding

Each Studio Command carries only its command ID. **No projectID is present.**
Pressing an unbound command is rejected; this is not a wildcard binding. Select
the action in the live inspector, pair via Keychain if needed, and deliberately
apply its command to the open project. Runtime icons/titles/tally then reflect
that project's authoritative state. Open Studio is a separate launch/focus action.
No command executes merely because a profile is imported, appears, or reconnects.

The registrations are editable, with `AutoInstall:false` and
`DontAutoSwitchWhenInstalled:true`. They do not install themselves or change the
operator's active layout. Pairing tokens and ephemeral command authority never
belong in action settings or profile archives.

## Import and lifecycle qualification still required

1. In a disposable owned Stream Deck configuration, import each exact candidate
   through the application's supported profile document importer. Record the
   app/device configuration, actual import outcome and archive hash. Stop if the
   format is rejected; do not write the private profile store to bypass rejection.
2. Verify unbound keys cannot operate a project; explicitly rebind through the
   live inspector and verify authoritative dispatch/tally, rename/delete,
   independent bindings and disconnect/reconnect. The source suite already
   relaunches the real bundled plugin against owned SDK/native peers with saved
   settings and lost acknowledgements, asserting no replay.
3. Qualify actual package install/update/uninstall using an owned test namespace
   and a helper that cannot read real pairing; preserve all unrelated profiles
   and plugins. The existing CLI link/update/unlink check is development lifecycle
   evidence, not a substitute for a package installation.
4. Document the actual supported configurations. Marketplace submission remains
   a separate release action; physical delivery and release signing should be
   reported for their measured scope, not invented as profile-generation gates.

No application import/install, device interaction, session unlock or permission
change is performed by the generator, tests or package command. Elgato's
[profile guide](https://docs.elgato.com/streamdeck/sdk/guides/profiles/),
[manifest reference](https://docs.elgato.com/streamdeck/sdk/references/manifest/#profile)
and [profile packaging guide](https://docs.elgato.com/stream-deck/profiles/packaging/)
describe the supported bundling/import workflow. Manual editor export remains an
alternative producer when available, not an extra original acceptance criterion.
