# Layer geometry keyboard control work

The selected staged layer now has numeric position, width, height and rotation fields in the inspector. Previously, the canvas supported keyboard translation, but general resize and rotation required pointer handles. The new native text fields have operation, unit and layer labels; Apply and Reload use native buttons. Typing changes only the draft. Apply uses the existing validated command and produces one undo operation, separate from a nearby pointer drag or another Apply.

The draft retains its identity and text through unrelated scene publications. It merges only edited fields into the current transform, preserves unrelated style and transform values, and rejects conflicting edits to the same field. Losing the original selection, staged scene, applied canvas profile or workspace runtime permanently retires that draft, including selection changes away and back. Current scene, group and layer locks still run through the dispatcher. Project-switch intent retires drafts before asynchronous replacement completes.

A retired draft exposes **Start New Geometry Draft**, with an explicit notice that it replaces the retired edits with current layer values and the current canvas profile. This creates a distinct editor after rechecking the same live workspace, runtime, staged scene and single selected layer. It never revives the old editor. The recovery callback must still identify the current retired editor, so an old callback cannot discard a newer draft. This also supports same-runtime profile changes and rapid selection changes away and back when SwiftUI retains the inspector subtree.

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

## Presentation recovery follow-up

The original source/model proof was committed as `4c1608fc71f3aab8b5087e540b6b08371c5c073a`. Final source review found that the ancestor view identity changes only with the runtime, while the geometry subtree identity contains the runtime, scene and layer. A same-runtime profile change can therefore leave the retired editor visible; rapid selection changes can also retire it before SwiftUI renders an intermediate selection. Reload correctly refuses retired authority, so a distinct recovery action was needed.

The [follow-up receipt](LAYER_GEOMETRY_RECOVERY_2026-10-22.json) preserves the original receipt and binds the recovery source and actual tool logs. The extended fixture uses the shipping presentation owner. It checks recovery after selection changes away and back and actual Apply Settings, fresh values and current-canvas minimum dimensions, successful new Apply, permanent old-editor retirement, and rejection of recovery after runtime replacement. It also verifies that current editor changes publish to the presentation while old binding, Apply and recovery callbacks neither alter a newer dirty draft nor publish changes through its presentation. Each rendered view captures its editor locally rather than resolving the latest editor when a retained callback executes.

These are actual model, callback and compiled-view checks. They do not assert mounted SwiftUI identity behavior or native event delivery.

## Remaining verification

This proves the compiled controls and their shipping model, ownership, undo and rendering behavior. It does not prove native keyboard or accessibility delivery, VoiceOver interaction, full-window layout at 1024 × 640, operator text-size/contrast behavior, or the parent combined universal application build. No global accessibility, permission, session, input or device settings changed. Original issue #90 remains open for its remaining acceptance checks.
