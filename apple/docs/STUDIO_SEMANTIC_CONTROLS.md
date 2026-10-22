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

## Soundboard and document follow-up

On baseline `44c078e`, source commit `2db81fb` repairs another concrete
keyboard/action gap: the pad editor's eight color circles used only
`onTapGesture`. They are now plain SwiftUI buttons, matching the existing
annotation palette convention. Each identifies the pad and color and reports
whether it is selected. The existing checkmark, dimensions, color values and
`updateSoundPad` command are preserved.

Pad, playlist and scene-sound volume sliders now identify their target and
report percent; 100 percent remains unity gain and the slider range remains
0 through 200 percent. Persisted values outside that range are described
without clamping: large finite percentages use scientific notation; a finite
gain whose multiplication by 100 overflows is reported in multiples of unity
gain. Nonfinite values report “Volume unavailable.” A shared formatter avoids
trapping integer conversions and does not change the stored or playback gain.
Playlist transport and scene-sound relink/remove
buttons identify their targets. PDF page sliders, previous/next buttons and
thumbnail buttons identify the document and page; the current thumbnail
reports “Current page.” All existing bindings, dispatcher commands, identity,
disabled conditions and playback behavior are preserved.

Both complete changed views passed `swiftc -frontend -parse`, and
`git diff --check` passed. Exact source hashes and command results are in
`/tmp/stream-wave6-accessibility-source-checks-20261022.json`. These are source
checks; the combined app still requires compilation at integration. No new
native AX or keyboard attempt was made in the locked session, and no
VoiceOver, traversal, default-action or contrast qualification is inferred.
Original #90 remains open under the limits above.

The same audit identified additional controls requiring separate work:
screen-crop geometry can currently be changed only by a marquee drag, and
PTZ direction controls are drag-only while zoom buttons have empty native
button actions. A keyboard alternative for PTZ must preserve the existing
explicit stop and teardown behavior rather than starting indefinite motion.
Those behaviors are not changed or qualified by `2db81fb`.

Independent source review caught an unsafe integer conversion in the initial
percentage labels. The follow-up compiles the actual production formatter
under strict Swift 6 and exercises ordinary, negative, huge finite,
multiplication-overflow and nonfinite values. In particular, 0.5 reports
“50 percent,” 2 reports “200 percent,” and a persisted gain of `1e20` reports
“1e+22 percent.” Run the small check with:

```sh
zsh apple/scripts/run_studio_gain_accessibility_harness.zsh
```

The shipping helper check and parsing both complete views passed. This is a
numeric robustness check, not native AX action or operator qualification.
