# Hosted owned-window keyboard setup: source preparation

The first branch-scoped hosted attempt ended at exit 77. Both compilers passed,
and the genuine stock/AppKit and production scene AX checks passed. The one
owned activation request did not establish an active app and key owned window
within the unchanged two-second deadline. No keyboard focus calibration or
production key sequence was reached, and no fallback or rerun followed.

The earlier hosted outcome is unchanged in
`HOSTED_SCENE_SEMANTIC_OBSERVATION_2026-10-22.json`. All nine earlier local
outcomes and their original machine receipt remain unchanged. The new companion
`HOSTED_SCENE_KEYBOARD_SETUP_2026-10-22.json` binds this attempt and its separate
compile-only history. This component evidence does not complete #90 or #155.

The opt-in `--owned-keyboard-setup` addresses that missing setup boundary. It
requires `GITHUB_ACTIONS=true`, `RUNNER_ENVIRONMENT=github-hosted`, the exact
owned bundle identifier, regular activation policy and the existing own-parent
C AX mode. A missing guard returns 77 without requesting activation. Child AX
processes take their existing early client entry before application setup.

After all original genuine AX baselines and the scene-two AX action have passed,
the fixture requests `NSApp.activate()` once and orders only its own eligible
window key/front. It observes actual `NSApp.isActive`, `window.isKeyWindow` and
`NSApp.keyWindow === window` within a two-second monotonic deadline anchored
before the request. Activation is advisory; a late or unavailable observation
returns 77 without another request or fallback. No other app is queried or
directly controlled; forced activation and LaunchServices are not used.

The opt-in view contains two genuine stock SwiftUI buttons with compact visual
titles, preserving the first baseline's existing accessibility label and callback.
The second is identified as “Owned SwiftUI keyboard second.” Fixture FocusState
intent requests stock button one, then the same public own-parent PID/window/
geometry observer reads actual `AXFocused` values. It performs no AX action in
these focus observations. A complete tree, exactly the requested focused button,
unchanged selection/callbacks and an active/key owned window are required.
Global AX trust is recorded, not introduced as an additional eligibility gate.

Real window-local Space, then Tab and Space, must produce the stock callback
suffix `[1, 2]` and exactly one callback at each step. There is no focus request
or reset between Tab and Space. If the stock chain cannot calibrate delivery,
the result is 77 before production keyboard assessment. The public read-only
`NSApp.isFullKeyboardAccessEnabled` property is recorded as
`keyboardNavigationEnabled`; it is not necessarily the separate Accessibility
Full Keyboard Access setting and does not excuse a failed calibrated oracle.

Next, fixture FocusState requests scene one without invoking an action or
changing selection. Actual public owned focus and no setup callback must again
be observed. The original production Space → Tab → Space calls and callback
suffix `[1, 2]` predicate remain unchanged. A lost active/key condition is
unqualified. With genuine stock delivery and initial scene focus qualified, a
failed production oracle remains a failure, including a failed first Space.
No keyboard-navigation preference-based masking is added.

Focus observations use phase-specific child artifacts and a two-second child
alarm, so they cannot overwrite the earlier baseline or scene-action reports.
Setup and before/after-key facts record actual state and callbacks. Default
observation retains its original controls, labels, actions, key calls and gates;
it requests no activation and adds no second stock button. The fixture view
now includes focus-state/change-observer structure, so identical native grouping
in default mode has not been demonstrated. The production
`SceneSelectionButton.swift` is unchanged.

The manual workflow remains single ARM macOS 26, with no matrix, automatic
trigger, retry, trust/defaults/HID change, other-app query, Core build or full
studio launch. It adds the explicit flag to the existing bundled child command
and retains the original 120/120-second compile and 30-second owned runtime
limits. The executable was launched directly from its properly formed bundle;
LaunchServices was not used in this hosted attempt.

## Retained first outcomes

Source preparation was committed as `2abb8bf8db5490cb6c3742be4e71195275ae0fb2`.
The first compile-only batch passed the Objective-C bridge and failed Swift
compilation on the imported API name `canBecomeKeyWindow`. No executable ran.
A separate one-token correction, `e597907ce1c9238aa4f5872cfc317941485bbccd`, used
`canBecomeKey`. The single fresh corrected compile-only batch passed both
compilers without invoking its executable. Both batches retain their original
sources, logs and receipts.

The first hosted run was [39889238145](https://github.com/joeblau/stream/actions/runs/39889238145),
job `120204727369`, at exact commit `e597907ce1c9238aa4f5872cfc317941485bbccd`.
Its ARM host reported macOS 26.6.2 (25G83), Xcode 26.6 (17F113), and Swift 6.3.3.
The Objective-C and strict Swift 6 compilers returned zero; the native runtime
returned 77. The archive retains the executable, five actual input snapshots,
receipt, raw logs, capability facts and before/after activation facts.

The external own-parent C AX baseline observed actual `AXButton` roles for the
stock SwiftUI and AppKit controls. Both AX presses returned success and caused
the expected callbacks. The direct in-process AppKit API separately reported
`AXUnknown` and returned false from its press method while still causing a
callback; that is not treated as the external baseline result. The actual
production scene buttons had the expected names and status values, and the
scene-two AX press changed selection and recorded callback `[2]`.

Before and after the one activation request, the window was visible, but
`NSApp.isActive`, `window.isKeyWindow` and `NSApp.keyWindow === window` were all
false. `activationQualified` was false at the two-second deadline. Scene
callbacks stayed `[2]`; stock callbacks stayed `[1]`. The stock `[1]` callback
came from the earlier AX press, not a keyboard event. There were no stock-focus,
stock-keyboard, scene-focus or production-keyboard phase artifacts. Thus the
stock Space → Tab → Space calibration and original production keyboard oracle
were not reached. Read-only `keyboardNavigationEnabled=false` is descriptive;
it is not an established cause or permission diagnosis.

The first native outcome ends this attempt. It demonstrates neither a keyboard
control defect nor a lock-state cause. No settings, TCC, VoiceOver, global HID,
other-app observation or production source change was made. The original
keyboard and contrast requirements remain in scope; full workspace action,
focus, dialog and small-window delivery are not inferred from these component
AX checks. Any different launch boundary requires a separately reviewed plan.
