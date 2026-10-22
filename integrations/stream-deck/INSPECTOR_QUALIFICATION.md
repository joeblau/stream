# Inspector and development lifecycle verification

The inspector filters the studio's existing paged command catalog by live
resource type and category. It does not generate source/target combinations or
create resource IDs. Scene, layer/source, overlay, guest/slot, destination/event
and show-profile bindings retain their stable IDs after rename, deletion,
project changes and reconnect. Missing resources stay visible and require an
explicit replacement; a disconnected source is distinguished from a deleted
source. Feedback-only audience keys are explained as displays, and remote
ending keys explain that exact-target confirmation occurs in Stream Studio.

Camera/screen assignment uses the bounded `argument: "source"` descriptor with
`sourceKind: "camera" | "screen"`. A separate picker reads matching existing
`source.<UUID>.effects.bypass` descriptors, including their `sourceAvailable`
state. Choosing the layer does not silently choose a source. Apply submits
only the command ID and selected source UUID in `text`. Native/plugin owners
validate and execute this additive descriptor after integration; the inspector
never persists authority, confirmation, session or event-approval tokens.

Gain, dial step, PDF page and marker UTF-8 length are checked before submission.
Live snapshots preserve drafts and readable validation errors. New acknowledged
settings replace drafts. Old socket callbacks and another action's context
cannot replace a new inspector registration or silently redirect a binding.

## Reproduce

From this directory on macOS with Node 24 and Xcode command-line tools:

```sh
npm ci --ignore-scripts
npm run check
npm test
npm run test:browser
npm run package
npm run test:install
```

`test:browser` launches a separate headless Chrome with a unique temporary
profile and owned loopback HTTP/WebSocket peers. It uses the shipped HTML/JS,
real DOM selection and actual WebSocket registration. `CHROME_BIN` can identify
a Chrome executable; missing Chrome fails the check. It covers resource
filtering, rename/delete, project changes, draft preservation, UTF-8 validation,
confirmation visibility, a 320px panel, typed source selection, context
isolation and a real socket close/new registration retaining the binding without
replaying a bind. `STREAM_INSPECTOR_SCREENSHOT` optionally saves an owned PNG.
It never opens Stream Deck, reads an operator browser profile or uses Keychain.

`test:install` is an explicit development-link check using the pinned official
CLI. It copies the built plugin under a random, collision-checked fixture UUID,
replaces its credential helper with a stub that returns no pairing, validates
it, links/discovers it, updates and relinks its version, then unlinks it. Cleanup
removes only the exact verified owned symlink. The original plugin inventory
must match afterward. It never changes developer mode, imports/switches a
profile or touches the production plugin's pairing. This is a real supported
development link/update/unlink test; it is not a signed package-install test.

Local results on 2026-10-21: typecheck passed; all 14 protocol/SDK/inspector tests
passed; the real Chrome test passed and its 320px screenshot was inspected;
official CLI 1.10.1 validation/packaging passed; the owned development lifecycle
passed with the original plugin inventory unchanged. The built native helper
contains both x86_64 and arm64 slices. The package is generated under `dist/`.

## Requirements still open in #152

Three deterministic stream/record/interview 15-key profile candidates are now
bundled and registered. Their public MIT template, reproducibility and package
contents are checked; actual target-app importer acceptance remains pending.
Manual editor export is an alternative producer, not an original issue
requirement. See [profile candidates](profiles/README.md).

The bundled SDK suite explicitly exercises standard keypad, Plus dial,
six-key Mobile and three-key Pedal configurations against owned peers. It saves
stable settings, loses an acknowledgement, stops and relaunches the actual
plugin process and restarts the owned native TCP listener. Fresh feedback and
explicit dispatch return without command replay or settings rewrite. These are
protocol/configuration proofs, not physical device delivery measurements.

Actual package install/update/uninstall remains separate from the existing
owned development-link lifecycle. Marketplace submission remains a distinct
release action. No profile import, personal device action, app configuration,
session unlock or permission change is performed by these software checks.

Official references: [property inspector protocol](https://docs.elgato.com/streamdeck/sdk/references/websocket/ui/),
[profile creation and bundling](https://docs.elgato.com/streamdeck/sdk/guides/profiles/),
[CLI commands](https://docs.elgato.com/streamdeck/cli/intro/), and
[profile export/packaging](https://docs.elgato.com/stream-deck/profiles/packaging/).
