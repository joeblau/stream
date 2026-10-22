# Scene reordering without dragging

This scoped #90 change on baseline `9881359` adds Move Earlier and Move Later
to each scene's context menu, named accessibility actions on list rows and
thumbnail cards, and a native Scene menu for the selected scene. The Scene
menu adds no shortcuts and does not intercept text editing or global input.

The shared resolver uses the scene's current folder or unfiled container and
its complete sibling order. Search changes what is shown, not which sibling
is adjacent. An earlier move inserts before the preceding sibling. A later
move inserts before the sibling two positions ahead, or at the container's
end. First/last boundaries have no move. Menu items disable unavailable or
locked moves; unavailable named AX actions are omitted.

Every invocation recomputes the target from its stable scene ID and executes
the existing `.moveScene` command. The dispatcher retains lock validation,
undo and persistence. Reordering neither selects nor Takes a scene, changes
its folder, edits its content, nor replaces staged or Program snapshots.
Missing or deleted scene IDs are ignored. An action surviving a refile uses
the scene's new container. The native menu also checks that its observed
runtime is still current before using the current selected ID, so a retained
old menu cannot edit either project after a workspace switch.

## Verification

The existing isolated workspace tool has a focused no-window mode:

```sh
STREAM_VENDOR_ROOT=/path/to/owned/vendor \
  zsh apple/scripts/run_studio_workspace_harness.zsh --scene-reordering
```

The runner builds the actual scene browser, menu Commands type, resolver,
dispatcher, model, store and undo stack. Its existing validation boundaries
use owned settings/storage, replace credential storage, and suppress capture.
This mode opens no window, starts no media or publisher, requests no permission,
and sends no input. It executes the shipping menu callback methods directly;
it does not claim native menu key delivery or AX action execution.

The final build and fixture passed with:

- Full sibling ordering, including a scene hidden by a search query;
  first/last boundaries in folder and unfiled containers; and insertion at end.
- Lock rejection through the actual dispatcher, preserving a locked neighbor.
- Actual undo/redo and disk reload, with folder membership, stable scene
  content/IDs, selection, unpublished preview edits and Program preserved.
- Refile-before-invocation and deleted-ID cases.
- Live selection resolution, actual workspace runtime replacement, rejection
  of a retained old menu callback, and successful rebinding to the new runtime.

The final transcript is
`/tmp/stream-wave7-scene-reordering-final-20261022.log`, with build success,
both fixture PASS lines and exit 0. The tool typechecks the actual browser
and Commands type. The App's `.commands` insertion is parsed here and still
requires the combined app build at integration.

Original #90 remains open. No locked-session native AX retry, VoiceOver
traversal/action/order qualification, actual menu keyboard delivery or visual
contrast qualification is inferred from these model and callback checks.
