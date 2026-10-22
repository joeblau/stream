# Scoped studio semantic controls, 2026-10-22

Source commiteaa329c fixes concrete #90 controls inb53ae5d. It does not close #90 or establish VoiceOver/contrast qualification. [Bounded source/proof receipt](STUDIO_SEMANTIC_CONTROLS_2026-10-22.json).

Scene thumbnail cards previously used a VStack with only an onTapGesture. They now use the production SceneSelectionButton containing a genuine plain SwiftUI Button. The same selectScene command preserves Preview/Direct Live behavior; thumbnail styling, drag/drop and context menus remain on the same card. The button names its scene and reports selection plus existing Preview/Program/unpublished/locked states. It relies on native Button focus semantics rather than adding a focusable wrapper; [Apple explains that buttons already manage focus](https://developer.apple.com/videos/play/wwdc2020/10042/?time=531).

Each media seek/trim slider now identifies its source and operation and reports seconds. Existing scrub commit and trim bindings/ranges are unchanged. Play/pause/stop/restart buttons name their source. Scene-folder and layer-group visibility controls name their target.

The existing mixer clip latch now has a persistent-layout CLIP text row, retaining the numeric dB readout. The passive row adds no focus stop or live announcement. The existing channel group exposes Clipping/Not clipping, or Level unavailable when no meter was supplied. No mixing, routing, meter cadence, fader behavior or source identity changes.

## Verification and limits

Strict Swift6 typechecking of the production SceneSelectionButton passed, as did parsing all four changed full views and diff checks. Source-check transcript: `/tmp/stream-wave5-accessibility-source-checks-20261022.json`. Parent integration must still compile the entire app.

The small native tool compiles that exact production control with real NSHostingView/NSWindow and two owned scene cards. It sends only local events to its own window and queries actual public in-process NSAccessibility selectors using an Objective-C bridge. It creates no virtual tree, fabricated actions, replacements for the scene controls, global input, TCC grants, app activation or personal capture. Run `zsh apple/scripts/run_scene_selection_native_harness.zsh`. A missing semantic/action/keyboard proof exits77, not success.

The current session still reports CGSSessionScreenIsLocked=Yes. Final actual transcript `/tmp/stream-wave5-scene-selection-native-limits-20261022.log` exited77: the owned window returned8AXnodes and0SwiftUIscene buttons; localSpace/Tab yielded no scene callbacks and the first responder was SwiftUI.KeyViewProxy. A separate genuine mounted NSButton queried directly had its explicit label but AXUnknown role; bridge/directAXpress returnedfalse and the callback count was1. This native control was never inserted into the SwiftUI semantic tree or counted as scene acceptance. Two earlier fixture assertions assumed that native positive control would acknowledgeAXpress; their failed logs remain in the machine receipt. No unchanged native retry is warranted in the same environment.

## Original #90 mapping

- Labels/actions/order, keyboard traversal, sliders/tables/layer controls and non-color status: concrete source gaps above are repaired. Actual complete SwiftUI semantic order/default actions, scene keyboard activation and mixer/layer accessibility actions remain unqualified.
- Configurable text, contrast, reduced motion and small layouts: existing production preferences are retained. This change does not establish rendered contrast or complete small-layout acceptance.
- Focus during live meters/chat and restoration: previous exact native focus ownership proof and fixes are retained. No repeat claim follows from the small semantic fixture. New metering copy uses a stable passive row and existing scene IDs remain stable.

Full operator VoiceOver traversal/actions/order and real visual contrast/layout checks remain open original acceptance. No additional physical-device or universal certification gate is added.
