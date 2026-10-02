# Horizontal and vertical canvases (#178)

The studio can render a Program canvas and a separately composed secondary
canvas on the same host-clock tick. The secondary frame comes from its own
`SceneRenderer` and pixel-buffer pool. It is not a resized Program frame.
Secondary rendering runs only while an actual secondary sink is registered.
Both canvases observe the same taken scene, source registry, sequence and PTS;
staged changes reach their Preview monitors until Take.

## Layout and source ownership

`Scene.secondaryCanvas` is an optional, additive persisted value. Existing scene
documents decode with no secondary layout. A scene without a valid secondary
layout produces black on that canvas, with no project branding over the black
frame. Output starts require a configured layout taken to Program.

Secondary placements override geometry and visibility by stable layer ID.
Missing placements explicitly follow Program. Copy Program Geometry snapshots
placements; Follow Program removes an override. These operations use the common
command dispatcher, effective layer locks and staging/Undo behavior. Duplicating
a scene or importing a portable show remaps placements with their layer IDs.

Source IDs and payloads remain shared. A source pool owns one media/PDF/capture
instance even when both canvases use it. Timers retain their common layer ID.
The real PDF player caches bounded per-canvas fill rasters while sharing page
selection. This does not add guest capture support: current guest availability
continues to be governed by the guest runtime. Duplicating a scene creates new
layer IDs, including independent timer identity, while retaining source IDs.

The secondary Preview supplies adjustable top/bottom/left/right safe-zone
guides. Guides are editor chrome and never enter recorded/published pixels.
An independent secondary visibility change cuts on Take; scene-to-scene
transitions use the existing host-clock transition duration on both canvases.
Primary per-layer visibility fades are not applied to independently visible
secondary placements. Program annotations and branding retain their common
overlay identity rather than acquiring a separate secondary editing tool.

## Output ownership and resource preflight

Each destination stores an optional `canvas`, defaulting to Program for old
documents. Its immutable started runtime captures that selection, and its
bounded video mailbox receives only frames from that canvas. Both receive the
one mixed Program audio bus. Starting/stopping a secondary output reconciles
shared capture and audio demand; opening its Preview cannot unmute staged-only
sources. A failing destination removes only its own media demand.

Clean-display and virtual-camera feed pickers also expose the actual secondary
composition. A camera consumer still negotiates the camera extension's supported
landscape format; a portrait feed is aspect-fit into that format. Selecting a
secondary feed does not grant OS activation or qualify a consumer application.

A separate `RecordingController(outputCanvas: .secondary)` records the actual
secondary frames and the common mixed audio. It has separate preferences and
filename prefix, and keeps the writer, isolated-track and chat-archive contracts.
Primary and secondary start/stop independently. Source ISOs are shared physical
source reads with separately counted encoder/writer sessions.

One studio ledger reserves a Program encoder plus every requested video ISO
before countdown/preflight starts. It includes all primary and secondary
recordings and active per-destination publishers, and holds reservations until
writer/ISO/segment finalization completes. Segment rotation reserves its
temporary overlapping encoders before creating another segment. Any start that
would exceed four total encoders fails before allocating partial outputs.
Cancelling a preflight also releases the geometry ownership and promotes staged
settings. Additional canvas recording is disabled outside the existing qualified
multi-encoder machine class. Both-canvas public-output preflight also caps the
aggregate compositor workload at 4K30 pixels per second; that conservative bound
is not a promise of sustained cadence on every Mac.

## Desktop integration hooks

- Embed `SecondaryCanvasPanelView` beside the existing Program/Preview row and
  supply the existing controller/dispatcher/preview-program/scene-store/primary
  recorder environment objects. Its appearance owns secondary monitor demand.
- Call `controller.bindSecondaryRecordingChat(runtime.chat)` after the shared
  runtime chat coordinator exists. Creating a secondary recorder then binds the
  same normalized messages to its accepted-frame chat archive.
- On close/quit, call `controller.stopSecondaryRecording(completion:)` and await
  its completion as well as the primary recorder before allowing termination.
  The controller also requests secondary stop on a privacy/lifecycle event.
- Include `controller.secondaryRecordingActiveOutputURLs` in session recovery
  observations. Reading it does not construct an idle secondary recorder.
- Existing `outputSessionActive` now includes pending recording reservations,
  protecting project and output-profile changes during countdown/preflight.

## Native validation and remaining qualification

Run `DUAL_CANVAS_BUILD_PATH=<derived-data> zsh
scripts/run_studio_dual_canvas_harness.zsh` from `apple`. The fixture builds the
shipping host components without provider account/Keychain initialization. It
checks legacy decoding, portable ID remapping, independent staging and Undo,
atomic resource rejection, profile promotion after cancelled preflight, routed
publisher video/shared audio and independent client disconnect. The transport
for the disconnect case is a protocol fixture, not a provider service.

The native GPU/AVFoundation portion renders 320×180 and 180×320 compositions with
different placements, checks identical per-sequence PTS and actual distinct
pixels, and writes independent H.264/AAC files. AVAssetReader decodes both
tracks, verifies dimensions, track starts within 40 ms and track ends within
80 ms, and verifies the secondary continues after the primary file finishes.
Both canvases must render an actual privacy-override sentinel rather than the
original layout. Foreground automation includes capture permissions for a
source visible only in the proposed secondary output.
The actual PDF player verifies common page selection and cached per-aspect fill
rasters. Cancellation before secondary mailbox registration cannot revive a
sink. Existing recording-controller regressions continue to exercise pause,
resume, segment rotation, isolated audio and preference behavior.

Full-resolution simultaneous cadence, service acceptance of portrait profiles,
physical clean displays, installed/signed virtual-camera consumers, guest media,
and manual desktop UI/a11y qualification remain separate gates. The small paired
file fixture is software timing/lifecycle evidence, not a full-resolution
hardware qualification. Default adaptive publishers retain their own encoders.
The desktop's explicit [fixed H.264/AAC sharing option](ENCODED_SHARING.md)
reuses compressed samples across matching RTMP/RTMPS/SRT destinations on the
same canvas. Different canvases always retain separate groups; recording and
unsupported codec/transport combinations still reserve separate encoders.
