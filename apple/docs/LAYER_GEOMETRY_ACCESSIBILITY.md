# Layer geometry keyboard control work

The selected staged layer now has numeric position, width, height and rotation fields in the inspector. Previously, the canvas supported keyboard translation, but general resize and rotation required pointer handles. The new native text fields have operation, unit and layer labels; Apply and Reload use native buttons. Typing changes only the draft. Apply uses the existing validated command and produces one undo operation, separate from a nearby pointer drag or another Apply.

The draft retains its identity and text through unrelated scene publications. It merges only edited fields into the current transform, preserves unrelated style and transform values, and rejects conflicting edits to the same field. Losing the original selection, staged scene, applied canvas profile or workspace runtime permanently retires that draft, including selection changes away and back. Current scene, group and layer locks still run through the dispatcher. Project-switch intent retires drafts before asynchronous replacement completes.

Dimensions use the existing four-canvas-pixel resize minimum. Off-canvas positions and enlarged boxes remain supported. Validation rejects nonfinite arithmetic and overflow in the existing corner/midpoint and raster/cache byte calculations. The renderer's existing 64 MiB generated-cache limit is shared as a read-only constant; its policy is unchanged.

Camera PIP has existing special framing: widths below 100% use a 10–40% PIP range, source-derived height and a 24-pixel inset at edge anchors. The inspector discloses that behavior, disables the ignored PIP height field and rejects newly entered widths that would be silently clamped. Proposed width determines the mode; width of at least 100% allows ordinary box height editing. Existing unedited legacy values are preserved.

## Executed proof

On arm64 macOS 27.2 (26B118), the actual workspace tool built and its `--layer-geometry` mode exited zero. It compiled the new SwiftUI view and actual editor, dispatcher, renderer and fresh Core source using an owned derived directory and independently owned pinned dependencies. The invocation used the shared two-slot wrapper and `xcodebuild -jobs 2`:

```sh
STREAM_VENDOR_ROOT=<owned-vendor> STREAM_XCODE_JOBS=2 \
  zsh apple/scripts/run_studio_workspace_harness.zsh --layer-geometry
```

The fixture executes shipping code and checks:

- No scene, Program or undo mutation while typing; 50 same-scene publications preserve the draft.
- Unedited field precision, live metadata and unrelated style/transform edits survive Apply; conflicting same-field edits require Reload.
- Adjacent drag → Apply → Apply has three separate undo and redo operations, without timing sleeps.
- Current locks, selection/staged-scene changes away and back, actual applied-profile changes and actual project/runtime replacement reject stale callbacks.
- Invalid numbers, tiny edited dimensions and midpoint, raster-product and cache-addition overflow reject; ordinary off-canvas and enlarged boxes remain valid.
- Actual synthetic camera rendering measures 96 × 54 pixels for 30% PIP and 160 × 90 pixels for an ordinary box, with the original two-pixel tolerance. It uses owned synthetic frames, without camera capture.

The machine-readable [receipt](LAYER_GEOMETRY_ACCESSIBILITY_2026-10-22.json) binds the nine source/fixture hashes, successful log and executable hash. It also retains both intermediate failed logs: an edge-anchor fixture clipped by existing PIP inset behavior, and an invalid Swift argument label corrected before the successful build. Centering the synthetic anchor isolated the full rendered extent; neither the expected dimensions nor rendering behavior changed.

## Remaining verification

This proves the compiled controls and their shipping model, ownership, undo and rendering behavior. It does not prove native keyboard or accessibility delivery, VoiceOver interaction, full-window layout at 1024 × 640, operator text-size/contrast behavior, or the parent combined universal application build. No global accessibility, permission, session, input or device settings changed. Original issue #90 remains open for its remaining acceptance checks.
