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
screen lifecycle through the shipping handler. The focused fixture does not rebuild the full SwiftUI application. The
subsequent full-source native fixture below compiles the app's source graph and
runs the shipping controller/compositor/converter/surface route; it does not
replace the normal release build or claim every physical display is qualified.

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

## Clean compositor budget follow-up

The independent review of `a98a3a9` found that its new external Clean
subscription bypassed the existing guest Clean compositor budget. External
Clean now uses the same measured Mac-class gate and **3840×2160×30 total
pixels/second** ceiling before allocating a window or subscription. Shared
Program, Clean and Secondary work is counted by renderer, not by the number of
subscribers. Later secondary publishing, recording and guest reservations see
external Clean demand. This preserves the existing limits; it does not qualify
additional Mac classes or increase their canvas budgets.

Cancellation revokes the clean-render permit synchronously and retains its
reservation until `CompositionEngine.removeSink` acknowledges teardown. A fast
stop/restart cannot make in-flight composition disappear from accounting. New
secondary-monitor demand can revoke the optional external Clean surface, with
the actual budget reason shown in the outputs inspector.

`CompositorWorkloadBudget` is the shared production preflight policy. Focused
native tests check the exact ceiling, qualification refusal, later-secondary
cost, refusal before surface/subscription allocation, and permit revocation.
The follow-up focused result is `/tmp/stream-175-budget-focused-20261022.log`.

The full-source fixture `run_external_display_program_harness.zsh` compiles all
StreamMac production sources with isolated credential/default/storage and
refused permission boundaries. Only descriptor enumeration and native-window
placement are injected into the shipping controller; the compositor, pixel
conversion, native surface, subscription, budget and teardown paths are real.
No screen capture, audio input, publisher or system reconfiguration is needed
for this owned offscreen-surface proof.

On Mac15,8 / Apple M3 Max / 16 CPUs / macOS 27.2 (26B118), the full native run
passed in `/tmp/stream-175-clean-program-20261022.log`. Its actual rendered PNGs
and isolated project inputs are retained under
`apple/build/external-display-program-validation/artifacts-514427AC-DC78-429A-B251-49EB582D7C6E`.
It verifies:

- A 4K30 Program requesting an additional Clean renderer fails before a surface
  or pipeline demand is allocated, with the compositor-budget error intact.
- Actual Program frames show a green global overlay and red annotation. Actual
  Clean frames on the same native display-surface path retain a blue scene
  layer and purple project background and omit both overlay and annotation.
- Two 1080p60 Program/Clean renderers exactly reach the unchanged ceiling. A
  later secondary publisher or guest/recording reservation is refused.
- A real registered guest Clean subscription shares the renderer with the
  external display and is accepted without double charging. Removing it does
  not stop the external display. External stop retains demand until the actor
  acknowledges removal, and final demand reaches zero.
- Starting secondary monitors at that boundary revokes the optional external
  Clean surface and reports the budget cause.

The first full native build exposed a duplicate generated permission-boundary
file, corrected in the fixture generator. Its log remains at
`/tmp/stream-175-clean-program-fixture-boundary-failure-20261022.log`. A later
full-source build succeeded, but physical observation exited **77 / UNQUALIFIED**
because two observable displays were no longer available; that result remains
at `/tmp/stream-175-clean-program-physical-gate-20261022.log`. The successful
owned-layer route proof does not erase that gate or substitute for a fresh
physical readback. The earlier real-display sRGB/SCK result above is separate
historical evidence. Physical cable unplug and an AirPlay receiver remain
unexercised; their software availability/removal handlers were tested with
injected topology, without claiming those hardware events occurred.

Run the full-source fixture with the shared native-build slot wrapper and a
read-only vendor root. It caps Xcode/Swift at two jobs and bounds the owned tool
runtime to 90 seconds:

```sh
python3 /tmp/stream-native-build-slots-20261022.py --label external-clean-program -- \
  env STREAM_VENDOR_ROOT=/path/to/read-only/vendor \
  zsh apple/scripts/run_external_display_program_harness.zsh
```
