# Native studio accessibility qualification (#90)

Run `scripts/run_studio_workspace_harness.zsh --accessibility` from `apple` in a logged-in macOS session. `STREAM_VENDOR_ROOT` and `WORKSPACE_BUILD_PATH` can select clean dependencies and an isolated build. The runner creates a distinct defaults suite, show/catalog, machine storage and recordings folder. Provider transport, Keychain, migration and actual capture are isolated by the existing workspace fixture. It does not start VoiceOver, request accessibility trust or change system/operator preferences.

A separate client uses public AXUIElement IPC against only its parent fixture PID. In-process AX calls can bypass IPC and evaluate SwiftUI bindings on the calling executor; directly invoking SwiftUI virtual-node informal getters also crashed inspection. These are excluded from the persistent test. Missing native AX availability returns **77 UNQUALIFIED**. Missing required labels, failed actions, geometry or focus assertions fail the test. Snapshots are retained under `build/studio-workspace-validation/accessibility/`.

On 2026-10-21, Mac15,8 / M3 Max, macOS 27.2 (26B118), Xcode 27.2 (27B5038j), the owned shipping MainWindow proved:

| Actual native exercise | Result |
| --- | --- |
| External AX tree, four studio panels | 166 elements initially; Scenes, Preview and program, Chat and Inspector have native names. |
| Annotation palette | Previously six buttons had empty accessible names and no selected values. Each now announces a distinct color and selected state. Public AX Press selects Blue in the actual annotation store and updates its native value. |
| Compact Layout toolbar action and 1024×640 content | Chat/Inspector/Settings disappear; Scenes and canvas remain. Take, Record, Preview and Public Go Live retain positive bounds inside the native window. |
| Largest app text setting | Preview-off text grows from 16 to 24 points high in the native tree; the root receives `accessibility1`. Primary production controls remain inside the compact window. |
| Reduce Motion | The actual root inherits the shipping `studioReduceMotion` environment value. Animation presentation has not been independently visually qualified. |
| Interface size/contrast controls | Native size slider exposes 20. Public AX Press turns the real contrast preference off and on. |
| Keyboard command palette | Focus actual Scene Search through public AX, deliver process-local ⇧⌘P, observe the real sheet, deliver Escape, verify the same native field editor and owning control regain focus. Previously dismissal returned a KeyViewProxy. The fix restores the stable owning text control instead of the detached shared field editor and preserves nil panel focus while native restoration runs. |

The high-contrast appearance is a **reproduced open qualification gap** on this host: `NSAppearance(named: .accessibilityHighContrastDarkAqua)` aliases DarkAqua and the actual root `colorSchemeContrast` remains `standard`, even with the preference enabled through its native control. One owned-HostingView public appearance override produced the same DarkAqua/standard result and was restored immediately. The fixture reports all preceding software results and exits **77 UNQUALIFIED** for this remaining contrast gap. It does not use the underscored SwiftUI contrast setter, a video contrast filter or a system preference change to force a pass.

This evidence does not qualify spoken VoiceOver navigation, all custom canvas actions, every inspector/settings subview, physical keyboard traversal under the operator's accessibility settings, visual contrast ratios, reduced-motion presentation, all display sizes or release signing. Those manual/native gates remain open. An AX tree inspection is not full VoiceOver qualification.
