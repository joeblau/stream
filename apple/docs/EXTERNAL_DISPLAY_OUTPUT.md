# External display output

The outputs inspector offers Program (including composed overlays), Clean Program
(the taken scene without global overlays or annotations), a saved destination's
canvas, and the taken secondary layout. External output is an optional,
borderless, non-key video surface. It creates no audio output or publisher.
Destination framing converts the taken source into the selected canvas before
the display's Fit/Fill policy. Clean Program uses the existing clean compositor
subscription and the same Program geometry, rather than hiding overlays in the
studio or changing the scene document.

The studio shell explicitly attaches its window identity. Changing the key
window to Settings or a sheet cannot change display ownership. Every display
intersected by the studio window is excluded; selection fails closed until the
shell attaches. Movement, resizing and system display-parameter notifications
refresh that ownership. Unchanged topology neither moves the video window nor
restarts its presentation timer. Refresh notifications are coalesced, and a
real refresh-rate change updates the bounded presentation cadence.

There is one pending image. A stalled consumer overwrites old images instead of
accumulating work, and disconnect/stop finishes that mailbox before removing
the subscription and closing the surface. A removed display or a display that
now contains studio controls stops the optional output. Reappearance requires a
new deliberate start. macOS AirPlay-as-display follows the same NSScreen
availability path; this feature does not create or configure an AirPlay session.
The window and produced images explicitly use sRGB. No display mode, default
audio device, system color profile or capture permission is changed.

## Native evidence, 2026-10-22

Named host: Mac15,8 (Apple M3 Max), macOS 27.2 (26B118), Swift 6.4.2. The focused
fixture compiles the shipping display controller, surface and converter, plus
the exact extracted `CompositedFrame` value. A copied, immutable StreamCore
framework supplied `OutputProfile`; that source is unchanged from its built
revision. `STREAM_CORE_FRAMEWORK_DIR` avoids an unrelated full application build.
Without that override the runner caps its Xcode build at two jobs.

`/tmp/stream-175-baseline-regression-20261022.log` retains the old production
controller's failure: ten unchanged refreshes still moved the surface and
restarted its cadence. The fixed run is retained in
`/tmp/stream-175-native-final-20261022.log` and artifacts under
`apple/build/external-display-validation/artifacts-AE5D7AE7-463B-4222-A1E9-CFEFAB0D6E6C`.

The completed native fixture verifies:

- Actual system display 4 at `(-3008, 0, 3008, 1692)` receives the shipping clean
  video surface. Using an already granted ScreenCaptureKit permission, it
  captures **only that fixture-owned window**, never another app or the whole
  display. The 320×180 readback has exact sRGB red/green/blue primaries and opaque
  black letterboxing. Switching Fit to Fill changes the negative letterbox
  control to the expected image color. Stop closes the actual window.
- Actual AppKit layer rendering of another owned, offscreen surface verifies
  Fit/Fill pixels and a resize to 80×160. Borderless/non-key/non-main,
  mouse-transparent behavior and absence of child controls are checked.
- Its actual run-loop timer presents 12 new images in 0.38335 seconds at a 30 fps
  target while 40 unchanged display notifications arrive. Empty ticks do not
  duplicate images; rate is bounded by the selected profile/display rate.
- Injected descriptor removal, relocation, studio overlap and reappearance use
  the shipping notification handler. Rearrangement preserves the subscription;
  removal closes it, rejects late callbacks, and does not auto-restart.
- Actual converter pixels verify portrait destination letterboxing, opaque
  black, sRGB color and unchanged source PTS. Selection includes Program,
  Clean Program with Program geometry, and a portrait destination canvas.
  Independent controllers, bounded image shedding, invalid canvas, failed
  surface allocation and failed subscription cleanup are exercised.

An initial screenshot with ScreenCaptureKit's default color-space selection
returned `[7, 0, 255]` for the blue control; that failed observation is retained
in `/tmp/stream-175-native-color-observation-20261022.log`. Explicit sRGB capture
makes the observer match the surface's sRGB contract and returns `[0, 0, 255]`.
The three-LSB assertion was unchanged. This is observer configuration, not a
claim about physical panel calibration.

## Acceptance and limits

O09 #175's software paths now select a real separate system display, expose the
required feeds and active state, render the video-only surface, and handle the
screen lifecycle through the shipping handler. The focused fixture does not
rebuild the full SwiftUI application or run its live compositor through every
feed; the small `StreamController` clean-subscription and studio-shell binding
changes still need the normal integration build. Existing clean composition
preserves the taken scene and removes global overlay/annotation rendering.

The actual consumer-window readback is distinct from the injected topology
proof. No cable was unplugged, system layout changed, or physical AirPlay
receiver negotiated. Those are unmeasured hardware cases, not evidence inferred
from a descriptor name. The output is intentionally video-only, so it has no
encoded tracks, audio stream or audio/video mux synchronization claim. The test
measures image presentation cadence and original input PTS; it does not claim
panel scanout latency, sustained qualification of every display, or hardware
memory-exhaustion behavior. Allocation/subscription refusal and bounded queues
are software failure tests.

To reproduce without a full app build:

```sh
STREAM_CORE_FRAMEWORK_DIR=/path/to/owned/StreamCore-framework-directory \
  zsh apple/scripts/run_external_display_harness.zsh
```

If existing capture permission or two observable displays are absent, the
own-window system-display observation is reported unqualified in `report.json`;
no permission request, unlock, virtual display or system reconfiguration occurs.
The owned layer/pacing/topology checks remain separate evidence.
