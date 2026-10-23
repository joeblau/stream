# Owned scene semantic observation

The scene fixture now requires a genuine stock SwiftUI button and a separate native AppKit button to expose their actual roles/labels and invoke their observed callbacks before it assesses production scene controls. It corrects the previous unsupported `locked-session` explanation: missing scene nodes alone establish neither a lock nor a production accessibility defect.

The production `SceneSelectionButton.swift` is unchanged. Its existing two-button label/value/action and local Space → Tab → Space callback oracles remain. Once the genuine baselines qualify, missing production controls fail. An unsuccessful local-key oracle in a non-key or inactive owned host is unqualified because delivery and control behavior cannot be separated. It does not pass the keyboard criterion. Neither a physical keyboard nor human listening is introduced as an acceptance requirement.

The reusable runner snapshots its five inputs, hashes artifacts, uses strict Swift 6 with `-j2`, and bounds compilation and runtime. Each invocation needs a fresh `SCENE_SEMANTICS_DIR`. Public C AX modes query only the current process or its own parent; client messages have a one-second timeout, a bounded tree, and a ten-second client guard. The outer runtime is limited to thirty seconds and terminates only its owned process group. No fabricated semantic tree is substituted.

```sh
SCENE_SEMANTICS_DIR=/absolute/fresh/output \
  zsh scripts/run_scene_selection_native_harness.zsh \
  --owned-bundle --public-cax-child
```

`--owned-bundle` creates a minimal app with `NSPrincipalClass=NSApplication` and executes its binary directly. Other diagnostic modes are the default Objective-C mounted-object walk, `--public-cax-self`, and metadata-only `--public-cax-raw-child`. The last mode deliberately cannot qualify the baseline. Raw Objective-C CF access independently checks the AXWindows element without Swift CF-array conversion. These modes do not activate the app, request AX trust, toggle VoiceOver, change settings, or send global input.

## Preserved first outcomes

The machine receipt binds all nine outcomes and their compiled sources, logs, binaries, public facts, and raw reports. The archived paths are local evidence, not portable inputs.

| Boundary | Actual observation |
| --- | --- |
| Original public Objective-C walk | Genuine stock SwiftUI baseline unavailable; exit 77. Direct AppKit press invokes its callback even though it returns false. |
| Public C AX self, original title selection | AXWindows succeeded but title selection refused the candidate; exit 77. |
| Public C AX self, role/owner/geometry recorded | The candidate was AXApplication, target-owned, size zero; AXSize returned −25205. It was refused as a window; exit 77. |
| First own-parent client compilation | `String(CGFloat)` compile error; no runtime. The exact conversion was corrected without changing gates. |
| Own-parent external C AX client | Same AXApplication candidate; exit 77. A self-only explanation was insufficient. |
| Own-parent raw Objective-C CF query | AXWindows returned a CFArray containing the same AX element as the application (`CFEqual` true). Swift bridging was insufficient to explain it; exit 77. |
| Proper app bundle, same accessory binary | Bundle name was recognized, but the same AXApplication candidate persisted; exit 77. Bundle metadata alone was insufficient. |
| Proper app bundle, regular policy | Only `.accessory` changed to `.regular` in the host. Same candidate and unavailable baseline; exit 77. Activation policy alone was insufficient. |
| Ordinary LaunchServices `open -n -W` | Exact regular-policy binary, unique bundle ID/path. Own app and client reported AX trust false; AXWindows returned −25211 (API disabled). Baseline unqualified. `open` exited 0; **that is not the native application's exit status or a passing test**. |

The direct-execution boundaries reported AX trust, session present, on-console, and owned window visible as true; key window and active application as false. The LaunchServices boundary reported trust false and the other facts unchanged. Lock state is unknown: the fixture uses no undocumented lock-state key or private API. No cause is inferred from these facts. The direct bundled executions also retain their sandbox-extension diagnostic without attributing causality.

The LaunchServices observation used ordinary activation behavior from `open`, without an explicit `NSApp.activate` call. It never made the owned host key or active. Its exact-executable lookup observed only the owned app/client PIDs and confirmed both had exited. No permission, preference, signing, registration, capture, hardware, network, other app tree, or global-input action followed. No additional native attempt was made.

## What was validated

The last compiled/executed host is the regular-policy snapshot identified by the receipt. After that run, two conservative diagnostic classifications were added: require the AppKit baseline in the original Objective-C mode too, and report inactive/non-key local-key ambiguity as unqualified. The reusable bundle-runner option was added from the retained app packaging recipe. These final edits passed Swift syntax parsing, zsh syntax, embedded Python compilation, and diff checks; **the final runner and changed classifications were not executed**. The runtime outcomes are bound to their actual earlier source snapshots.

No production scene action or keyboard acceptance followed any of these unavailable genuine baselines. Full studio labels/actions/order, keyboard traversal, tables/sliders, stable focus, and smaller-window acceptance remain separate original #90 requirements. The actual owned production-style contrast proof is recorded separately in `STUDIO_CONTRAST_PIXELS.md`; it does not supply the missing semantic or keyboard evidence here.

## Isolated hosted observation

The manual-only `native-scene-semantics.yml` workflow prepares one ARM macOS 26 component observation using the exact bundled own-parent C AX command above. This clean hosted OS/session is a distinct boundary from the nine local macOS 27.2 beta outcomes. The production component and all five runner inputs are unchanged. The workflow uses a fresh run-specific directory and retains the environment, source snapshots, compilation logs, runtime outcome and receipt even on failure.

The observation is pending; no hosted semantic or keyboard result is claimed. Exit 77 remains non-passing and means unavailable/unqualified. The first outcome ends the attempt; no automatic retry, observer fallback, trust request, settings change or global input follows. A component pass would cover only its existing two-button oracles after genuine baselines qualify, leaving the broader original #90 requirements above open.
