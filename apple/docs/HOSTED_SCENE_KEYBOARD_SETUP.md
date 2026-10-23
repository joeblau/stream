# Hosted owned-window keyboard setup: source preparation

This is an unexecuted fixture change. No compiler, native UI, workflow dispatch,
trust request or settings change has been performed for it. The first hosted
outcome remains unchanged in `HOSTED_SCENE_SEMANTIC_OBSERVATION_2026-10-22.json`:
actual AX baselines and scene actions passed, while window-local keyboard
delivery was unqualified with a visible, non-key window and an inactive app.
All nine earlier local outcomes and their original machine receipt are retained.

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

The prepared manual workflow remains single ARM macOS 26, with no matrix,
automatic trigger, retry, trust/defaults/HID change, other-app query, Core build
or full studio launch. It adds the explicit flag to the existing bundled child
command and retains the original 120/120-second compile and 30-second owned
runtime limits. Publication and one possible branch-scoped hosted dispatch
require parent review and are not performed by this preparation.

A future first outcome must retain all inputs, compile/runtime results, phase
facts and callback oracles, including any unavailable baseline or first failure.
No success is predicted. Even a complete component pass would not close #90 or
qualify #155's separate native chooser/sandbox keyboard flow.
