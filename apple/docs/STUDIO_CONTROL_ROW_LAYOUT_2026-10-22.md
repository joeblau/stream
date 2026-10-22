# Studio control rows on smaller displays

The studio declares a 1024×640 minimum window. Its default pane minima are
180 points for Scenes, 320 for Canvas, 260 for Chat, and 240 for Inspector,
before split dividers. The unscrollable transport row required 514 points
when its canvas was offered 320. The resulting pane-width lower bound was
1194 points plus dividers. The transition row also wrapped excessively:

| Interface text | Original transport size at 320-point proposal | Original transition size |
| --- | --- | --- |
| 11 points | 514×48 | 320×146 |
| 13 points | 514×48 | 320×166 |
| 20 points | 514×48 | 320×336 |

These are owned offscreen AppKit/SwiftUI measurements of the extracted
shipping rows and actual studio text style on Mac15,8 / Apple M3 Max,
macOS 27.2 (26B118). Runtime owners are memory-only stubs; the options/library
children retain their native icon-button labels without opening popovers.
The absent recovery button makes the measured transport a conservative case.

`StudioControlRow` places each existing row in one persistent native horizontal
scroll container. It retains the row's intrinsic height, and its minimum
content width follows the viewport so the existing Spacer still fills a wide
canvas. There is no conditional replacement of control trees. Main-window
changes add only the two wrappers; button actions, child ownership, panel
visibility, focus restoration, meters, chat, and output state remain unchanged.

Run the bounded source/layout check with:

```sh
python3 apple/scripts/test_studio_control_rows.py
```

The test extracts the actual current transition/transport/status/button bodies
and compiles the real text-style and scroll-container implementations with
inert owners. It creates hidden, non-key owned windows, with a fresh hosting
hierarchy for each explicit overlay/legacy scroller style. It checks all ten
configured text sizes, 11 through 20 points, at a 320-point canvas and after
resizing to 844 points. Its 40 row/style cases passed:

- Both rows accept the 320-point canvas proposal without wrapping vertically.
- The native scroll document retains all content: transport width 838 points;
  transition width 465.5–579.5 points across the text-size range.
- Programmatic scrolling of the owned native container reaches its trailing
  edge, and the wider viewport retains at least 844 points of document width.
- After native realization, the fixture uses exactly the reported intrinsic
  height, with no added scrollbar allowance. On this host both explicit styles
  reported 65/57-point transport/transition heights for 48/40-point content.
  The whole native scroll frame fits, and its visible document height covers
  the entire control row, including with a classic scrollbar.

The same test against the unmodified `9881359` main-window source fails its
first width check: 514 points exceeds the 320-point canvas minimum. Use
`--main-window-source PATH` for that exact source comparison.

This proves the specific row-sizing and native scroll-geometry correction.
It does not qualify every panel configuration at 1024×640, visible readability,
visual contrast, keyboard/VoiceOver delivery, focus restoration, live meter or
chat updates, or delivery of a changed system scrollbar preference. Reusing a
fixture hierarchy while manually changing native scroller styles can retain a
stale hosting measurement; the static-style cases deliberately use independent
containers. No system preference, permission, capture/audio device, studio
runtime, project document, or global input is used by this test.
