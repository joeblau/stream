# Scoped studio semantic controls, 2026-10-22

Source commit `eaa329c` fixes concrete controls for #90 on baseline `b53ae5d`.
It does not close #90 or establish VoiceOver or visual contrast qualification.
See the [bounded source and proof receipt](STUDIO_SEMANTIC_CONTROLS_2026-10-22.json).

Scene thumbnail cards previously used a `VStack` with only an `onTapGesture`.
They now use the production `SceneSelectionButton`, containing a genuine plain
SwiftUI `Button`. The same `selectScene` command preserves Preview and Direct
Live behavior. Thumbnail styling, drag and drop, and context menus remain on
the same card. The button names its scene and reports selection plus the
existing Preview, Program, unpublished changes, and locked states. It relies
on native button focus semantics instead of adding a focusable wrapper;
[Apple explains that buttons already manage focus](https://developer.apple.com/videos/play/wwdc2020/10042/?time=531).

Each media seek and trim slider now identifies its source and operation and
reports seconds. Existing scrub commit and trim bindings and ranges are
unchanged. Play, pause, stop, and restart buttons name their source.
Scene folder and layer group visibility controls name their target.

The existing mixer clip latch now has a `CLIP` text row with a stable layout,
retaining the numeric dB readout. The passive row adds no focus stop or live
announcement. The existing channel group exposes “Clipping,” “Not clipping,”
or “Level unavailable” when no meter was supplied. Mixing, routing, meter
cadence, fader behavior, and source identities are unchanged.

## Verification and limits

Strict Swift 6 typechecking of the production `SceneSelectionButton` passed,
as did parsing all four changed full views and checking the diff. The source
check transcript is `/tmp/stream-wave5-accessibility-source-checks-20261022.json`.
Parent integration must still compile the entire app.

The small native tool compiles that exact production control with a real
`NSHostingView`, `NSWindow`, and two owned scene cards. It sends only local
events to its own window and queries actual public in-process
`NSAccessibility` selectors through an Objective-C bridge. It creates no
virtual tree, fabricated actions, replacement scene controls, global input,
TCC grants, application activation, or personal capture. Run:

```sh
zsh apple/scripts/run_scene_selection_native_harness.zsh
```

Missing semantic, action, or keyboard proof exits with status 77, not success.

The current session still reports `CGSSessionScreenIsLocked = Yes`.
The final actual transcript,
`/tmp/stream-wave5-scene-selection-native-limits-20261022.log`, exited with
status 77. The owned window returned 8 AX nodes and 0 SwiftUI scene buttons.
Local Space and Tab events yielded no scene callbacks, and the first responder
was `SwiftUI.KeyViewProxy`. A separate genuine mounted `NSButton`, queried
directly, had its explicit label but an `AXUnknown` role. The bridge and direct
AX press methods returned false; the native callback count was 1. This native
control was never inserted into the SwiftUI semantic tree or counted as scene
acceptance. Two earlier fixture assertions assumed that the native positive
control would acknowledge an AX press; their failed logs remain in the machine
receipt. No unchanged native retry is warranted in the same environment.

## Original #90 mapping

- **Labels, actions, order, keyboard traversal, sliders, tables, layer controls,
  and non-color status:** the concrete source gaps above are repaired. Complete
  SwiftUI semantic order and default actions, scene keyboard activation, and
  mixer and layer accessibility actions remain unqualified.
- **Configurable text, contrast, reduced motion, and small layouts:** existing
  production preferences are retained. This change does not establish rendered
  contrast or complete small-layout acceptance.
- **Focus during live meters and chat, and restoration:** previous exact native
  focus ownership proof and fixes are retained. The small semantic fixture adds
  no further focus qualification. New metering copy uses a stable passive row,
  and existing scene IDs remain stable.

Operator VoiceOver traversal, actions and order, plus actual visual contrast
and layout checks, remain open acceptance requirements. No additional physical
device or universal certification gate is added.
