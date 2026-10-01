import Combine
import Foundation
import StreamCore

/// The shared command and state layer for studio actions (W05, issue #68).
///
/// UI controls, keyboard shortcuts, and — later — automation and hardware
/// controllers (D-series) all express their intent as a `StudioCommand` and
/// hand it to the ONE `StudioCommandDispatcher`. Commands address stable S01
/// `GraphID`s (scene/layer), never view state, so a Stream Deck button and a
/// menu item say exactly the same thing.
///
/// Ordering: the dispatcher is `@MainActor` and `execute(_:)` is synchronous,
/// so commands run strictly one at a time, in call order — validation and
/// execution of command N complete before command N+1 is even looked at.
///
/// Rejection, not double-execution: `execute` validates against the CURRENT
/// session state first ("start stream" while connecting/live returns
/// `.unavailable`, a missing scene/layer returns `.invalidTarget`) and a
/// rejected command performs no work. Every result carries the post-command
/// `StudioState` snapshot, and the dispatcher's published `state` is the
/// snapshot SwiftUI views (and future subscribers) observe.
///
/// W03 (issue #66): scene edits and selection go to the `PreviewProgramModel`'s
/// STAGED snapshot only — never straight to the program path. `.take`
/// publishes staged → program (persisting it as the source of truth),
/// `.revert` discards unpublished staged edits, and
/// `.setDirectLiveEditing` toggles the explicit mode where every edit and
/// selection takes immediately (standard single-composition switcher
/// behavior).

// MARK: - Commands

/// S04 canvas alignment (issue #72): which edge/center of the selected
/// layers' UNROTATED frames line up (against the selection's union bounds).
enum LayerAlignment: String, CaseIterable, Sendable {
    case left, horizontalCenter, right, top, verticalCenter, bottom

    var displayName: String {
        switch self {
        case .left: return "Left"
        case .horizontalCenter: return "Horizontal Center"
        case .right: return "Right"
        case .top: return "Top"
        case .verticalCenter: return "Vertical Center"
        case .bottom: return "Bottom"
        }
    }
}

/// S04 canvas distribution (issue #72): evenly spaces the selected layers'
/// centers between the outermost two, along one axis.
enum LayerDistribution: String, CaseIterable, Sendable {
    case horizontal, vertical

    var displayName: String {
        switch self {
        case .horizontal: return "Horizontally"
        case .vertical: return "Vertically"
        }
    }
}

/// One studio action. Explicit start/stop, show/hide, set-value, and Take
/// commands — not toggles: a caller states the desired end state, and the
/// dispatcher rejects it when the system is already there (or can't go).
enum StudioCommand: Equatable, Sendable {
    // Output sessions (W02 state machines).
    case startStream
    case stopStream
    case startPreview
    case stopPreview
    case startRecording
    case stopRecording

    // Scenes (S01 layer graph).
    case selectScene(SceneID)
    /// 1-based position in the scene list (the ⌘1…⌘9 shortcuts).
    case selectSceneAt(Int)
    /// Adds a default scene (same template as the scenes panel's + button).
    case addScene
    /// Appends a fully-formed scene built from the `Scene` factories (the W06
    /// first-run sample scene) and selects it.
    case insertScene(Scene)
    case renameScene(SceneID, to: String)
    case deleteScene(SceneID)
    /// Replaces a whole scene (the inspector's layout/PIP bindings edit the
    /// compatibility surface; the graph stays the source of truth).
    case updateScene(Scene)

    // Scene browser organization (S02, issue #70). Folders, ordering, and
    // locks are browser-side metadata in SceneStore: they apply immediately
    // and are NOT staged preview/program content. A LOCKED scene rejects
    // rename/delete/reorder and every content edit — the lock toggle itself
    // is the one command it still accepts.
    /// Copies the scene (new stable scene/layer/group IDs, unlocked) right
    /// after the original, in the same folder.
    case duplicateScene(SceneID)
    /// Moves a scene in the browser: `toFolder` re-files it (nil = top
    /// level), `before` anchors it ahead of a sibling (nil = end of the
    /// destination folder, or end of the list when unfiled).
    case moveScene(SceneID, toFolder: SceneFolderID?, before: SceneID?)
    case addSceneFolder(named: String?)
    case renameSceneFolder(SceneFolderID, to: String)
    /// Removes the folder only; its scenes become unfiled.
    case deleteSceneFolder(SceneFolderID)
    case setSceneFolderCollapsed(SceneFolderID, collapsed: Bool)
    case setSceneLocked(SceneID, locked: Bool)

    // Layer set-value commands (W03: they mutate the STAGED scene; `in: nil`
    // targets it, an explicit ID must name it).
    case setLayerVisibility(LayerID, visible: Bool, in: SceneID?)
    case setLayerTransform(LayerID, LayerTransform, in: SceneID?)
    case setLayerEffects(LayerID, [LayerEffect], in: SceneID?)
    case setLayerAudio(LayerID, AudioBinding, in: SceneID?)

    // S03 layer-panel structure commands (also staged-only). Locks are
    // enforced in validation: an effectively-locked layer or group rejects
    // the edit with a reason instead of silently no-op'ing.
    /// Adds a layer of a renderable kind (camera/screen today) at the FRONT
    /// of the z-order, bound to the matching project source when one exists.
    case addLayer(LayerPayload, in: SceneID?)
    case removeLayer(LayerID, in: SceneID?)
    /// Copies the layer (new stable ID, unlocked) directly in front of it.
    case duplicateLayer(LayerID, in: SceneID?)
    case renameLayer(LayerID, to: String, in: SceneID?)
    case setLayerLocked(LayerID, locked: Bool, in: SceneID?)
    /// Moves a layer to `toIndex` in the back-to-front array (index as
    /// counted AFTER removing the layer) and reassigns its group — a drag
    /// onto an ungrouped row passes nil, onto a group's row its GroupID.
    case moveLayer(LayerID, toIndex: Int, group: GroupID?, in: SceneID?)
    /// Creates a group from the given layers, moved adjacent at the position
    /// of their frontmost member.
    case groupLayers([LayerID], named: String?, in: SceneID?)
    /// Dissolves a group; members keep their z-order, now ungrouped.
    case ungroupLayers(GroupID, in: SceneID?)
    case renameGroup(GroupID, to: String, in: SceneID?)
    /// Cascades visibility to every member (group show/hide writes member
    /// `isVisible`, so the render path — which reads only `isVisible` —
    /// composes it). Rejected when the group or any member is locked.
    case setGroupVisibility(GroupID, visible: Bool, in: SceneID?)
    /// Non-destructive group lock: members become effectively locked via
    /// composition (`member.isLocked || group.isLocked`) until unlocked.
    case setGroupLocked(GroupID, locked: Bool, in: SceneID?)

    // S04 canvas geometry commands (issue #72, also staged-only). They act
    // on the layers in `SceneStore.selectedLayerIDs` of the staged scene,
    // skipping locked ones — the same editable set the canvas interaction
    // view moves — so a menu item, the context menu, and automation say the
    // same thing. Unrotated frames are what align/distribute.
    /// Aligns the selected, editable layers (≥2) to the selection's union
    /// bounds along one edge/center.
    case alignLayers(LayerAlignment, in: SceneID?)
    /// Evenly distributes the centers of the selected, editable layers (≥3)
    /// between the outermost two along one axis.
    case distributeLayers(LayerDistribution, in: SceneID?)

    // G11 presentation annotations (issue #117): pen/highlighter strokes and
    // the laser pointer drawn over the preview canvas. Annotations live in
    // their own per-scene-keyed document (AnnotationStore — the A03
    // soundboard-document precedent), NOT in the S01 scene graph: they are
    // never staged scene content, so Take/Revert never gates them, scene
    // locks don't apply (like project overlays), and they are NOT S12-
    // undoable scene edits — strokes carry their own stroke-level history
    // (undo/redo below IS that history). Per-scene visibility and the
    // explicit "part of program" choice apply immediately to BOTH monitors
    // (the S07 project-overlay precedent). `in: nil` targets the STAGED
    // scene (the canvas the presenter draws on); an explicit ID must name an
    // existing scene.
    /// Commits one finished pen/highlighter stroke to the scene's
    /// annotations (the canvas drag commits on mouse-up).
    case addAnnotationStroke(AnnotationStroke, in: SceneID?)
    /// Stroke-level undo/redo of the scene's annotation edits (add/clear) —
    /// the acceptance criterion's "undo", deliberately separate from ⌘Z
    /// scene-edit undo.
    case undoAnnotationStroke(in: SceneID?)
    case redoAnnotationStroke(in: SceneID?)
    /// Removes every stroke from the scene (undoable at stroke level).
    case clearAnnotations(in: SceneID?)
    /// Per-scene visibility: hidden annotations paint nowhere — not the
    /// preview chrome, not the program output.
    case setAnnotationVisibility(visible: Bool, in: SceneID?)
    /// The explicit per-scene "annotations are part of program" choice: on,
    /// strokes (and the broadcast pointer) composite into the program output
    /// through AnnotationRenderer; off, they stay preview-only telestrator
    /// marks. Applies immediately, like project overlays.
    case setAnnotationsInProgram(Bool, in: SceneID?)
    /// Selects the canvas drawing tool (nil = normal selection mode).
    /// Session state, like layer selection — validated and routed here so
    /// toolbar, menu/hotkeys, canvas Escape, and automation agree.
    case setAnnotationTool(AnnotationTool?)

    // S07 project-wide overlays and backgrounds (issue #74). Overlays are
    // PROJECT-level content — NOT bound to the staged scene: these commands
    // mutate the SceneStore overlay list directly and apply immediately to
    // BOTH the staged and program compositions (live-safe shared branding,
    // the Ecamm-style behavior the issue describes), so they never appear as
    // pending staged edits and Take/Revert does not gate them. The per-scene
    // pieces — hiding an overlay in one scene and a scene's own background —
    // ARE scene content and ride the normal staged→program path.
    /// Adds a project overlay (text/shape today — branding that needs no
    /// capture) at the FRONT of the project overlay stack.
    case addOverlay(LayerPayload)
    /// G09 (issue #116): adds a project overlay bound to a NEW registry
    /// media source (animated image or alpha video) in one atomic command —
    /// the source registration carries the bookmark and the playback policy
    /// (loop/autoplay/end action, editable in the Media Playout section) and
    /// gives the overlay its playout identity: pool demand and the render
    /// path key media by source ID. Format validation already happened at
    /// the file pick (`MediaOverlayClassifier`) — an unsupported format
    /// never gets this far.
    case addMediaOverlay(name: String, payload: MediaSourcePayload)
    case removeOverlay(LayerID)
    case renameOverlay(LayerID, to: String)
    case setOverlayVisibility(LayerID, visible: Bool)
    case setOverlayLocked(LayerID, locked: Bool)
    case setOverlayTransform(LayerID, LayerTransform)
    case setOverlayEffects(LayerID, [LayerEffect])
    /// Moves an overlay to `toIndex` in the back-to-front array (index as
    /// counted AFTER removing it — same semantics as `moveLayer`).
    case moveOverlay(LayerID, toIndex: Int)
    /// Per-scene override: hides/shows a project overlay in the STAGED scene
    /// only (`Scene.hiddenOverlayIDs` — staged scene content, taken/reverted
    /// like any scene edit).
    case setOverlayHiddenInScene(LayerID, hidden: Bool, in: SceneID?)
    /// Sets the STAGED scene's own background (nil = inherit the project
    /// default). Scene content: stages and Takes like any scene edit.
    case setSceneBackground(SceneBackground?, in: SceneID?)
    /// Sets the PROJECT default background — every scene without its own
    /// background falls back to it (then to black). Project-level: applies
    /// immediately, like overlay edits.
    case setDefaultBackground(SceneBackground?)
    /// S09 (issue #100): sets the STAGED scene's transition override (nil =
    /// inherit the project default). Scene content: stages and Takes like
    /// any scene edit.
    case setSceneTransition(SceneTransition?, in: SceneID?)
    /// S09 (issue #100): sets the PROJECT default transition — Takes into
    /// scenes without their own override render it. Project-level: applies
    /// immediately, like the default background.
    case setDefaultTransition(SceneTransition)

    // E01 per-source framing and picture adjustment effects (issue #101).
    // Layer OVERRIDES are staged scene content (Take/revert/undo like any
    // layer edit); source DEFAULTS and presets are project-level (apply
    // immediately to staged AND program, the S07 overlay-edit precedent) —
    // and neither is undoable-scene-edit state beyond the staged scene (the
    // source registry and presets live outside the S12 undo snapshot, like
    // the mixer document).
    /// Sets/clears a STAGED-scene layer's effect overrides (nil = inherit the
    /// bound source's defaults). The value is complete — overrides replace
    /// the source defaults wholesale, bypass included.
    case setLayerSourceEffects(LayerID, SourceEffects?, in: SceneID?)
    /// Sets/clears a registry source's effect DEFAULTS (nil = identity).
    /// Render-side only: never re-keys the capture pool.
    case setSourceEffectDefaults(SourceDefinitionID, SourceEffects?)
    /// Saves a reusable named effect preset (project-level).
    case addEffectPreset(SourceEffectPreset)
    case updateEffectPreset(SourceEffectPreset)
    case removeEffectPreset(EffectPresetID)

    // G03 layer styling (issue #106): masks, borders, shadows, opacity,
    // perspective. LAYER styles are staged scene content (same targeting,
    // lock, Take/revert/undo rules as `.setLayerSourceEffects`); OVERLAY
    // styles are project-level and apply immediately to staged AND program
    // (the S07 overlay-edit precedent); presets are project-level documents
    // (the E01 effect-preset precedent — outside the S12 undo snapshot).
    /// Replaces a STAGED-scene layer's style (a complete value; `.identity`
    /// is the reset).
    case setLayerStyle(LayerID, LayerStyle, in: SceneID?)
    /// Replaces a project overlay's style (applies immediately, like
    /// `.setOverlayEffects`).
    case setOverlayStyle(LayerID, LayerStyle)
    /// Saves a reusable named style preset (project-level).
    case addStylePreset(LayerStylePreset)
    case updateStylePreset(LayerStylePreset)
    case removeStylePreset(LayerStylePresetID)

    // G02 text layers (issue #110): text content + title style. LAYER
    // payloads are staged scene content (same targeting, lock,
    // Take/revert/undo rules as `.setLayerStyle`); OVERLAY payloads are
    // project-level and apply immediately to staged AND program (the S07
    // overlay-edit precedent); title-style presets are project-level
    // documents (the E01/G03 preset precedent — outside the S12 undo
    // snapshot).
    /// Replaces a STAGED-scene text layer's payload (the string + the whole
    /// style surface; a complete value). The target must be a text layer.
    case setLayerText(LayerID, TextSourcePayload, in: SceneID?)
    case setLayerMotionIdentity(LayerID, UUID, in: SceneID?)
    /// Session transport: doesn't alter staged content or create undo entries.
    case setDynamicOverlayTransport(LayerID, OverlayTransportAction, in: SceneID?)
    /// Replaces a project text overlay's payload (applies immediately, like
    /// `.setOverlayStyle`). The target must be a text overlay.
    case setOverlayText(LayerID, TextSourcePayload)

    // G01 image layers (issue #81): image payload (asset/file binding +
    // content mode). Same targeting, lock, Take/revert/undo rules as the G02
    // text payloads: LAYER payloads are staged scene content; OVERLAY
    // payloads are project-level and apply immediately. Format validation
    // happened at the pick/drop (`ImageAssetValidator`) — an unsupported
    // file never gets this far.
    /// Replaces a STAGED-scene image layer's payload (a complete value). The
    /// target must be an image layer.
    case setLayerImage(LayerID, ImageSourcePayload, in: SceneID?)
    /// Replaces a project image overlay's payload (applies immediately, like
    /// `.setOverlayText`). The target must be an image overlay.
    case setOverlayImage(LayerID, ImageSourcePayload)
    /// Saves a reusable named title-style preset (project-level).
    case addTextStylePreset(TextStylePreset)
    case updateTextStylePreset(TextStylePreset)
    case removeTextStylePreset(TextStylePresetID)

    // G08 browser overlay widgets (issue #115): the web payload is a
    // complete value (widget URL/local HTML plus the whole
    // BrowserOverlayConfiguration surface — viewport, fps, interaction,
    // audio route, CSS overrides, scene-entry refresh). LAYER payloads are
    // staged scene content (same targeting, lock, Take/revert/undo rules as
    // `.setLayerText`); OVERLAY payloads are project-level and apply
    // immediately to staged AND program (the `.setOverlayText` precedent).
    // Every edit re-keys the capture pool (payload identity = capture
    // identity, the C03 pattern), so the widget reloads deliberately.
    /// Replaces a STAGED-scene web layer's payload. The target must be a
    /// web layer.
    case setLayerWeb(LayerID, WebSourcePayload, in: SceneID?)
    /// Replaces a project web overlay's payload (applies immediately, like
    /// `.setOverlayText`). The target must be a web overlay.
    case setOverlayWeb(LayerID, WebSourcePayload)

    // A02 media transport (issue #97): play/pause/stop/restart/seek for a
    // registry media source. These are SESSION state — playback position is
    // never part of a scene document — so they are not undoable scene edits,
    // and scene/layer locks don't gate them (they edit no scene content).
    // They act on the ONE shared playback instance per source (the pool's),
    // so transport can never fork preview vs program playback.
    case mediaPlay(SourceDefinitionID)
    case mediaPause(SourceDefinitionID)
    /// Rewind to the trim-in point and clear the frame (black fallback).
    case mediaStop(SourceDefinitionID)
    /// Rewind to the trim-in point and keep playing.
    case mediaRestart(SourceDefinitionID)
    /// Seek to an absolute file position in seconds (clamped to the trim
    /// range by the playback engine).
    case mediaSeek(SourceDefinitionID, to: Double)

    // G06 presentation navigation (issue #113): next/previous/jump page and
    // fit/fill framing for a registry PDF source. These are PROGRAM-AWARE
    // like the A02 media transport: they act on the ONE shared per-source
    // deck state (`PDFDeckStore`), which both composition engines read on
    // their next tick, so a page change is live on program the moment the
    // source is on program and can never fork preview vs program playback.
    // Page state is session/document state, never scene content: not staged,
    // not undoable, and scene/layer locks don't gate it.
    case pdfNextPage(SourceDefinitionID)
    case pdfPreviousPage(SourceDefinitionID)
    /// Jump to a 0-based page (clamped to the loaded page count by the store).
    case pdfGoToPage(SourceDefinitionID, page: Int)
    /// Per-source page framing (fit/fill), applied at rasterization.
    case pdfSetFraming(SourceDefinitionID, framing: DeckFraming)

    // Output profile (W07 staged-vs-active rules live in the controller).
    case setOutputProfile(OutputProfile, destination: StreamProtocol?)

    // A04 embedded mixer (issue #83): the live session mix — NOT scene
    // content and NOT undoable scene edits. Capture-channel program levels
    // are owned by the S05 `AudioBinding`s (edit via `.setLayerAudio`), so
    // these commands address the scene-independent surface: non-capture
    // channel faders/mutes, monitor-only solos, aux sends, and bus masters.
    // Everything here persists via SettingsSession (the mixer document) and
    // applies live, ramped, through the controller.
    /// Sets a non-capture channel's fader (0…2). The mic fader is the live
    /// face of `StreamSettings.micVolume`; other kinds persist in the mixer
    /// document by channel label.
    case setChannelVolume(AudioChannelID, Double)
    /// Mutes/unmutes a non-capture channel in the program mix (ramped).
    case setChannelMuted(AudioChannelID, Bool)
    /// Monitor-only solo: while any channel is soloed the MONITOR bus
    /// carries only the soloed channels; the program bus is never affected.
    case setChannelSolo(AudioChannelID, Bool)
    /// A channel's aux/guest-return send (0…1) — the per-channel routing
    /// surface beyond program/monitor.
    case setChannelAuxSend(AudioChannelID, Double)
    /// Master gain for one bus (0…2).
    case setBusGain(AudioBus, Double)
    /// Master mute for one bus (effective gain 0; the fader value is kept).
    case setBusMuted(AudioBus, Bool)

    // A05 multi-mic inputs (issue #84): enable/disable an audio input device
    // as its own mix channel, pick which hardware channels feed it
    // (mono/stereo-pair mapping), and relink a missing device to a connected
    // one. Live session state persisted in `StreamSettings.audioInputs` via
    // SettingsSession (like the mixer document) — NOT scene content, NOT
    // undoable, and never staged.
    case setAudioInputEnabled(String, Bool)
    case setAudioInputMapping(String, AudioInputMapping)
    /// Replaces a configured input's device UID (keeping enable/mapping)
    /// with a currently-connected device — the explicit C10 relink path for
    /// an unplugged mic.
    case relinkAudioInput(from: String, to: String)

    // A08 per-channel FX (issue #120): one channel's whole effect chain —
    // preset picks, per-section bypass/reset, and parameter scrubs all edit
    // the same `ChannelFXChain` value and dispatch through here. Live
    // session state persisted in `StreamSettings.channelFX` via
    // SettingsSession (like the mixer document) — NOT scene content, NOT
    // undoable, never staged — and applied as parameter updates on the
    // channel's running insert (no capture restart).
    case setChannelFXChain(AudioChannelID, ChannelFXChain)

    // A07 headphone monitoring (issue #119): enable/disable the monitor-bus
    // playback and choose the monitor output device (nil UID = the system
    // default). Live session state persisted in StreamSettings via
    // SettingsSession — NOT scene content, NOT undoable, and never staged.
    // Monitor LEVEL stays on the A04 mixer surface (`.setBusGain(.monitor,…)`
    // / `.setBusMuted(.monitor,…)`); per-channel audition is the existing
    // monitor-only solo (`.setChannelSolo`).
    case setMonitoringEnabled(Bool)
    /// Selects the monitor output by stable CoreAudio device UID (nil =
    /// follow the system default). An unplugged selection falls back to the
    /// default honestly and re-applies when the device returns (C10 rules).
    case setMonitorOutputDevice(uid: String?)

    // A10 A/V delay alignment + speech ducking (issue #122). Live session
    // state persisted in StreamSettings via SettingsSession (the mixer/A07
    // precedent) — NOT scene content, NOT undoable, never staged — and
    // applied in place on the engines (no capture restart, no clock
    // re-anchor): audio delays shift a channel's ring read window, video
    // delays re-target a source's frame-hold line, ducking reconfigures the
    // engine-side gain automation.
    /// A channel's audio delay in milliseconds (0…`AVSyncDelay.maxAudioDelayMs`;
    /// 0 removes it). Any channel kind may carry a delay.
    case setChannelAudioDelay(AudioChannelID, ms: Double)
    /// A registry source's VIDEO delay in milliseconds
    /// (0…`AVSyncDelay.maxVideoDelayMs`; 0 removes it), keyed by the stable
    /// registry ID so a relink never loses the alignment.
    case setSourceVideoDelay(SourceDefinitionID, ms: Double)
    /// The whole speech-ducking configuration (enable, sidechain, threshold,
    /// reduction, attack/hold/release, duck targets) — one value, edited
    /// whole, like `.setChannelFXChain`.
    case setDucking(DuckingSettings)

    // A09 echo handling (issue #121): the echo handling mode for mic capture
    // (off / macOS Voice Isolation preference). Live session state persisted
    // in StreamSettings via SettingsSession — NOT scene content, NOT
    // undoable, and never staged (the A07 monitoring precedent). Feedback
    // detection itself needs no command: it runs from the engine taps and
    // surfaces through StudioState; the REPAIRS ride the existing mixer /
    // monitoring / input commands above.
    case setEchoHandlingMode(EchoHandlingMode)

    // E05 (issue #109): hardware camera controls + macOS reaction triggers.
    // Hardware modes are DEVICE state (one capture feeds the preview and
    // program engines, so a change lands on both) — live session state
    // persisted per-device in `StreamSettings.cameraControls` via
    // SettingsSession (the A07/A09 precedent), NOT scene content, NOT
    // undoable, never staged. Commands address the camera by its stable
    // capture-device uniqueID (the C10 identity rule).
    /// Replaces one camera's hardware control preferences (focus/exposure/
    /// white-balance modes — the whole per-device value, edited whole like
    /// `.setDucking`). Capability-gated in validation against the connected
    /// device's discovered support, then applied to the hardware in place.
    case setCameraControls(String, CameraDeviceControlSettings)
    /// Triggers a macOS reaction effect on a camera's feed (macOS 14+,
    /// per-device support gated — reactions render into the feed before it
    /// reaches Stream, so preview and program both show them).
    case triggerCameraReaction(String, CameraReaction)

    // A03 soundboard + music playlists (issue #98): pads and playlists are a
    // project-level performance surface persisted in the soundboard document
    // (SoundboardStore — the mixer-document precedent), NOT scene content:
    // structural edits are immediate and never undoable scene edits, and
    // transport is session state (the media-transport precedent). Every
    // trigger routes through the studio engine's `.media(id)` channels, so
    // hardware/automation triggers (D-series) are audible in the broadcast.
    case addSoundPad(SoundPad)
    case updateSoundPad(SoundPad)
    case removeSoundPad(SourceDefinitionID)
    /// Fire the pad (its trigger policy decides restart vs overlap).
    case triggerSoundPad(SourceDefinitionID)
    case stopSoundPad(SourceDefinitionID)
    /// The panic button: stop every pad and in-flight scene stinger.
    case stopAllSoundEffects
    case addMusicPlaylist(MusicPlaylist)
    case updateMusicPlaylist(MusicPlaylist)
    case removeMusicPlaylist(SourceDefinitionID)
    case playlistPlay(SourceDefinitionID)
    case playlistPause(SourceDefinitionID)
    /// Rewind to the start of the current track, parked.
    case playlistStop(SourceDefinitionID)
    case playlistNext(SourceDefinitionID)
    case playlistPrevious(SourceDefinitionID)
    /// A03 scene sounds (issue #98): replaces the STAGED scene's sound
    /// bindings (enter/exit stingers, continue beds). Scene content —
    /// staged, Taken, reverted, and UNDOABLE like layer edits; the Take path
    /// fires the rules as scenes enter/leave program.
    case setSceneSoundBindings([SceneSoundBinding], in: SceneID?)

    // S08 scene audio snapshots + media entry/exit behavior (issue #99).
    // Scene content — staged, Taken, reverted, and UNDOABLE like sound
    // bindings; the Take path applies them as the scene enters PROGRAM
    // (previewing a scene never fires them).
    /// Sets/clears the STAGED scene's opt-in audio snapshot (nil = the
    /// inherit-current option: the live mix persists across the Take).
    case setSceneAudioSnapshot(SceneAudioSnapshot?, in: SceneID?)
    /// Captures the CURRENT mixer state (mic fader + every registered
    /// non-capture channel's fader/mute) into the staged scene's snapshot.
    case captureSceneAudioSnapshot(in: SceneID?)
    /// The staged scene's media entry/exit policy — restart/resume/continue
    /// when it enters program; keep-playing/pause/stop when it leaves.
    case setSceneMediaBehavior(SceneMediaBehavior, in: SceneID?)

    // E06 PTZ camera control (issue #165): pan/tilt/zoom, speed, stop, and
    // store/recall preset commands for configured network targets, plus the
    // explicit scene→preset recall links. These are HARDWARE/session
    // commands — they edit no scene content, so locks and staging never
    // apply and they are NOT undoable scene edits (the media-transport
    // precedent). Targets/presets/links persist in the PTZ document
    // (PTZPresetStore — the soundboard-document precedent), keyed by target
    // UUID; a target optionally records a capture device's uniqueID for
    // display, but never touches the capture pool. Movement is
    // fire-and-forget (VISCA over IP is best-effort); stop commands exist
    // for focus loss, release, and disconnect. Scene-linked recall rides
    // the Take seam: only links with `recallOnProgramEntry` fire, and only
    // when a scene becomes PROGRAM — previewing never moves a camera.
    case ptzAddTarget(PTZTarget)
    case ptzUpdateTarget(PTZTarget)
    /// Stops motion and tears the transport down, then removes the target's
    /// presets and recall links with it.
    case ptzRemoveTarget(UUID)
    /// Drive pan/tilt (speeds clamp to the pinned VISCA ranges: pan 1…24,
    /// tilt 1…20). A matching `.ptzStop` ends the drive.
    case ptzMove(UUID, direction: PTZMoveDirection, panSpeed: Int, tiltSpeed: Int)
    case ptzZoom(UUID, direction: PTZZoomDirection, speed: Int)
    /// Stops pan/tilt AND zoom on one target.
    case ptzStop(UUID)
    /// The focus-loss/disappear path: stops every target with outstanding
    /// motion.
    case ptzStopAll
    /// Stores the camera's current position into a VISCA slot and names it.
    case ptzStorePreset(UUID, number: UInt8, name: String?)
    /// Recalls a slot the document knows about (CAM_Memory recall).
    case ptzRecallPreset(UUID, number: UInt8)
    /// Removes the app-side record of a slot (the camera's own memory is
    /// left intact).
    case ptzRemovePreset(UUID, number: UInt8)
    /// Adds/replaces the explicit scene→target recall link (one per
    /// scene/target pair).
    case ptzSetSceneRecall(PTZSceneRecallLink)
    case ptzRemoveSceneRecall(UUID)

    // S11: one persisted rundown and one transport clock.
    case setRundown(ShowRundownDocument)
    case rundownPlay
    case rundownPause
    case rundownStop
    case rundownSkip
    case runRundownCue(UUID)

    // Settings session (W04).
    case openSettings(SettingsSession.Section?)
    case closeSettings
    case applySettings
    case revertSettings

    /// Take (W03): atomically publish the staged composition to program —
    /// the program snapshot becomes an independent copy of the staged scene,
    /// persists as the SceneStore source of truth, and lands on the program
    /// engine via `StreamController.publishSceneToProgram(_:)`.
    case take
    /// Revert (W03): discard unpublished staged edits — the staged scene
    /// becomes a copy of the program snapshot again.
    case revert
    /// Direct-live editing mode (W03, off by default): while on, scene edits
    /// and selections take immediately, applying straight to program.
    case setDirectLiveEditing(Bool)

    // S12 (issue #75): undo/redo of scene edits. These restore SNAPSHOTS of
    // the undoable state (scene document + browser organization + staged
    // scene — see SceneUndoStack.swift) recorded around every executed
    // undoable command below. Program safety: restore writes the STAGED model
    // and the store only, never the program snapshot — undoing an edit that
    // was already Taken re-stages the prior state as pending edits (Take
    // publishes it, Revert discards it) instead of retroactively rewriting
    // live output. In direct-live mode undo/redo takes immediately, keeping
    // the mode's preview == program contract.
    case undo
    case redo

    /// Short human label for rejection notices and future automation logs.
    var label: String {
        switch self {
        case .startStream: return "Go Live"
        case .stopStream: return "End Stream"
        case .startPreview: return "Start Preview"
        case .stopPreview: return "Stop Preview"
        case .startRecording: return "Start Recording"
        case .stopRecording: return "Stop Recording"
        case .selectScene, .selectSceneAt: return "Select Scene"
        case .addScene, .insertScene: return "Add Scene"
        case .renameScene: return "Rename Scene"
        case .deleteScene: return "Delete Scene"
        case .updateScene: return "Edit Scene"
        case .duplicateScene: return "Duplicate Scene"
        case .moveScene: return "Move Scene"
        case .addSceneFolder: return "Add Folder"
        case .renameSceneFolder: return "Rename Folder"
        case .deleteSceneFolder: return "Delete Folder"
        case .setSceneFolderCollapsed(_, let collapsed):
            return "\(collapsed ? "Collapse" : "Expand") Folder"
        case .setSceneLocked(_, let locked):
            return "\(locked ? "Lock" : "Unlock") Scene"
        case .setLayerVisibility(let id, let visible, _):
            return "\(visible ? "Show" : "Hide") Layer \(id)"
        case .setLayerTransform: return "Move Layer"
        case .setLayerEffects: return "Layer Effects"
        case .setLayerAudio: return "Layer Audio"
        case .addLayer(let payload, _): return "Add \(payload.displayName) Layer"
        case .removeLayer: return "Remove Layer"
        case .duplicateLayer: return "Duplicate Layer"
        case .renameLayer: return "Rename Layer"
        case .setLayerLocked(let id, let locked, _):
            return "\(locked ? "Lock" : "Unlock") Layer \(id)"
        case .moveLayer: return "Reorder Layer"
        case .groupLayers: return "Group Layers"
        case .ungroupLayers: return "Ungroup Layers"
        case .renameGroup: return "Rename Group"
        case .setGroupVisibility(_, let visible, _):
            return "\(visible ? "Show" : "Hide") Group"
        case .setGroupLocked(_, let locked, _):
            return "\(locked ? "Lock" : "Unlock") Group"
        case .alignLayers(let alignment, _): return "Align \(alignment.displayName)"
        case .distributeLayers(let distribution, _):
            return "Distribute \(distribution.displayName)"
        case .addAnnotationStroke(let stroke, _):
            return "\(stroke.tool.displayName) Stroke"
        case .undoAnnotationStroke: return "Undo Annotation"
        case .redoAnnotationStroke: return "Redo Annotation"
        case .clearAnnotations: return "Clear Annotations"
        case .setAnnotationVisibility(let visible, _):
            return "\(visible ? "Show" : "Hide") Annotations"
        case .setAnnotationsInProgram(let include, _):
            return "\(include ? "Broadcast" : "Unbroadcast") Annotations"
        case .setAnnotationTool(let tool):
            return tool.map { "Select \($0.displayName) Tool" } ?? "Select the Selection Tool"
        case .addOverlay(let payload): return "Add \(payload.displayName) Overlay"
        case .addMediaOverlay(let name, _): return "Add \(name) Overlay"
        case .removeOverlay: return "Remove Overlay"
        case .renameOverlay: return "Rename Overlay"
        case .setOverlayVisibility(_, let visible):
            return "\(visible ? "Show" : "Hide") Overlay"
        case .setOverlayLocked(_, let locked):
            return "\(locked ? "Lock" : "Unlock") Overlay"
        case .setOverlayTransform: return "Move Overlay"
        case .setOverlayEffects: return "Overlay Effects"
        case .moveOverlay: return "Reorder Overlay"
        case .setOverlayHiddenInScene(_, let hidden, _):
            return "\(hidden ? "Hide" : "Show") Overlay in Scene"
        case .setSceneBackground: return "Set Scene Background"
        case .setDefaultBackground: return "Set Project Background"
        case .setSceneTransition: return "Set Scene Transition"
        case .setDefaultTransition: return "Set Default Transition"
        case .setLayerSourceEffects(let id, let effects, _):
            return effects == nil ? "Reset Layer Source Effects" : "Layer \(id) Source Effects"
        case .setSourceEffectDefaults(_, let effects):
            return effects == nil ? "Reset Source Effect Defaults" : "Source Effect Defaults"
        case .addEffectPreset: return "Save Effect Preset"
        case .updateEffectPreset: return "Update Effect Preset"
        case .removeEffectPreset: return "Remove Effect Preset"
        case .setLayerStyle(let id, let style, _):
            return style.isRenderNoOp ? "Reset Layer Style" : "Layer \(id) Style"
        case .setOverlayStyle: return "Overlay Style"
        case .addStylePreset: return "Save Style Preset"
        case .updateStylePreset: return "Update Style Preset"
        case .removeStylePreset: return "Remove Style Preset"
        case .setLayerText(let id, _, _): return "Layer \(id) Text"
        case .setLayerMotionIdentity: return "Layer Motion Identity"
        case .setDynamicOverlayTransport(_, let action, _): return "Overlay \(action.rawValue)"
        case .setOverlayText: return "Overlay Text"
        case .setLayerImage(let id, _, _): return "Layer \(id) Image"
        case .setOverlayImage: return "Overlay Image"
        case .setLayerWeb(let id, _, _): return "Layer \(id) Browser Source"
        case .setOverlayWeb: return "Overlay Browser Source"
        case .addTextStylePreset: return "Save Title Style Preset"
        case .updateTextStylePreset: return "Update Title Style Preset"
        case .removeTextStylePreset: return "Remove Title Style Preset"
        case .mediaPlay: return "Play Media"
        case .mediaPause: return "Pause Media"
        case .mediaStop: return "Stop Media"
        case .mediaRestart: return "Restart Media"
        case .mediaSeek: return "Seek Media"
        case .pdfNextPage: return "Next Page"
        case .pdfPreviousPage: return "Previous Page"
        case .pdfGoToPage: return "Go to Page"
        case .pdfSetFraming: return "Set Page Framing"
        case .setOutputProfile: return "Set Output Profile"
        case .setChannelVolume(let id, _): return "Set \(id.label) Volume"
        case .setChannelMuted(let id, let muted):
            return "\(muted ? "Mute" : "Unmute") \(id.label)"
        case .setChannelSolo(let id, let soloed):
            return "\(soloed ? "Solo" : "Unsolo") \(id.label)"
        case .setChannelAuxSend(let id, _): return "Set \(id.label) Aux Send"
        case .setBusGain(let bus, _): return "Set \(bus.rawValue.capitalized) Gain"
        case .setBusMuted(let bus, let muted):
            return "\(muted ? "Mute" : "Unmute") \(bus.rawValue.capitalized)"
        case .setAudioInputEnabled(_, let enabled):
            return "\(enabled ? "Enable" : "Disable") Audio Input"
        case .setAudioInputMapping: return "Set Audio Input Channels"
        case .relinkAudioInput: return "Relink Audio Input"
        case .setChannelFXChain(let id, _): return "Set \(id.label) FX Chain"
        case .setMonitoringEnabled(let enabled):
            return "\(enabled ? "Enable" : "Disable") Monitoring"
        case .setMonitorOutputDevice: return "Set Monitor Output"
        case .setChannelAudioDelay(let id, _): return "Set \(id.label) Audio Delay"
        case .setSourceVideoDelay: return "Set Source Video Delay"
        case .setDucking(let ducking):
            return "\(ducking.isEnabled ? "Enable" : "Configure") Ducking"
        case .setEchoHandlingMode(let mode):
            return mode == .off ? "Turn Echo Handling Off" : "Enable \(mode.displayName)"
        case .setCameraControls: return "Set Camera Controls"
        case .triggerCameraReaction(_, let reaction):
            return "Trigger \(reaction.displayName) Reaction"
        case .addSoundPad: return "Add Sound Pad"
        case .updateSoundPad: return "Edit Sound Pad"
        case .removeSoundPad: return "Remove Sound Pad"
        case .triggerSoundPad: return "Trigger Sound Pad"
        case .stopSoundPad: return "Stop Sound Pad"
        case .stopAllSoundEffects: return "Stop All Sound Effects"
        case .addMusicPlaylist: return "Add Playlist"
        case .updateMusicPlaylist: return "Edit Playlist"
        case .removeMusicPlaylist: return "Remove Playlist"
        case .playlistPlay: return "Play Playlist"
        case .playlistPause: return "Pause Playlist"
        case .playlistStop: return "Stop Playlist"
        case .playlistNext: return "Next Track"
        case .playlistPrevious: return "Previous Track"
        case .setSceneSoundBindings: return "Scene Sounds"
        case .setSceneAudioSnapshot(let snapshot, _):
            return snapshot == nil ? "Inherit Current Mix" : "Set Scene Audio Snapshot"
        case .captureSceneAudioSnapshot: return "Capture Scene Audio"
        case .setSceneMediaBehavior: return "Scene Media Behavior"
        case .ptzAddTarget: return "Add PTZ Camera"
        case .ptzUpdateTarget: return "Edit PTZ Camera"
        case .ptzRemoveTarget: return "Remove PTZ Camera"
        case .ptzMove(_, let direction, _, _): return "Pan/Tilt \(direction.displayName)"
        case .ptzZoom(_, let direction, _): return direction.displayName
        case .ptzStop: return "Stop PTZ Camera"
        case .ptzStopAll: return "Stop All PTZ Cameras"
        case .ptzStorePreset(_, let number, _): return "Store PTZ Preset \(number)"
        case .ptzRecallPreset(_, let number): return "Recall PTZ Preset \(number)"
        case .ptzRemovePreset(_, let number): return "Remove PTZ Preset \(number)"
        case .ptzSetSceneRecall(let link):
            return link.recallOnProgramEntry ? "Arm Scene PTZ Recall" : "Set Scene PTZ Recall"
        case .ptzRemoveSceneRecall: return "Remove Scene PTZ Recall"
        case .setRundown: return "Edit Rundown"
        case .rundownPlay: return "Play Rundown"
        case .rundownPause: return "Pause Rundown"
        case .rundownStop: return "Stop Rundown"
        case .rundownSkip: return "Skip Cue"
        case .runRundownCue: return "Take Rundown Cue"
        case .openSettings: return "Open Settings"
        case .closeSettings: return "Close Settings"
        case .applySettings: return "Apply Settings"
        case .revertSettings: return "Revert Settings"
        case .take: return "Take"
        case .revert: return "Revert"
        case .setDirectLiveEditing(let on):
            return "\(on ? "Enable" : "Disable") Direct-Live Editing"
        case .undo: return "Undo"
        case .redo: return "Redo"
        }
    }
}

// MARK: - Errors and results

/// Why a command was rejected. Rejection happens BEFORE any execution, so a
/// rejected command is never double-run against stale session state.
enum StudioCommandError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Valid command, wrong moment — e.g. Go Live while connecting/live, or
    /// stopping a session that isn't running.
    case unavailable(String)
    /// The addressed scene/layer ID does not exist (stale automation input).
    case invalidTarget(String)
    /// The payload failed validation (empty scene name, settings the
    /// validator blocks).
    case invalidValue(String)

    var description: String {
        switch self {
        case .unavailable(let reason),
             .invalidTarget(let reason),
             .invalidValue(let reason):
            return reason
        }
    }
}

/// The outcome of one `execute(_:)`: success or the rejection error, plus the
/// resulting state snapshot either way (the unchanged state on rejection).
struct StudioCommandResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case success
        case rejected(StudioCommandError)
    }

    let outcome: Outcome
    let state: StudioState

    var error: StudioCommandError? {
        if case .rejected(let error) = outcome { return error }
        return nil
    }
}

// MARK: - Published state

/// The subscriber-facing snapshot of studio state. Views increasingly read
/// from here (the transport bar does today); automation/hardware subscribers
/// (D-series) will observe the same publisher. Value type, fully `Sendable`.
struct StudioState: Equatable, Sendable {
    /// A scene as the snapshot lists it (id + name only — the graph itself
    /// stays in `SceneStore`).
    struct SceneRef: Equatable, Sendable, Identifiable {
        let id: SceneID
        let name: String
    }

    var stream: StreamSessionState = .idle
    var preview: PreviewSessionState = .idle
    var recording: RecordingSessionState = .idle
    /// The canvas/fps the pipeline renders at right now (W07).
    var activeProfile: OutputProfile = .default
    /// A profile waiting for the active outputs to end, if any (W07).
    var stagedProfile: OutputProfile?
    var scenes: [SceneRef] = []
    var selectedSceneID: SceneID?
    /// The scene staged in PREVIEW (W03): what edits mutate and Take
    /// publishes. Equal to `selectedSceneID` outside transient updates.
    var stagedSceneID: SceneID?
    /// The scene on PROGRAM (W03): the independent snapshot the outputs emit.
    var programSceneID: SceneID?
    /// True while the staged composition differs from program — a different
    /// staged scene or unpublished edits (W03). Drives the Take/Revert
    /// controls and the pending-changes indication.
    var hasPendingStagedEdits = false
    /// Browser scene locks (S02): scenes rejecting edits, removal, and
    /// reordering until unlocked.
    var lockedSceneIDs: Set<SceneID> = []
    /// Direct-live editing mode (W03): edits apply straight to program.
    var directLiveEditing = false
    /// Visibility of the STAGED scene's layers, keyed by stable LayerID.
    var layerVisibility: [LayerID: Bool] = [:]
    /// EFFECTIVE locks of the staged scene's layers (S03): own lock OR the
    /// layer's group's lock. UIs disable/reject edits from this map; the
    /// dispatcher enforces the same rule in validation.
    var layerLocks: [LayerID: Bool] = [:]
    var settingsPresented = false
    var settingsDirty = false
    /// A04 (issue #83): the persisted mixer document — non-capture channel
    /// faders/mutes, the monitor-only solo set, aux sends, and bus masters.
    /// Live session state, not scene content (never undoable, never staged).
    var mixer = MixerSettings()
    /// The live mic fader (mirrors `StreamSettings.micVolume`).
    var micVolume: Double = 1
    /// A08 (issue #120): the persisted per-channel FX chains, keyed by
    /// `AudioChannelID.label` (mirrors `StreamSettings.channelFX`). Live
    /// session state, not scene content (never undoable, never staged).
    var channelFX: [String: ChannelFXChain] = [:]
    /// A08: the legacy global voice-polish toggle (mirrors
    /// `StreamSettings.voicePolishEnabled`) — the fallback chain source for
    /// channels with no persisted chain (see `fxChain(forLabel:)`).
    var voicePolishEnabled: Bool = true

    /// A08: the EFFECTIVE chain a channel runs — its persisted chain when
    /// present, else the legacy voice-polish mapping (same back-compat rule
    /// as `StreamSettings.fxChain(forChannelLabel:)`).
    func fxChain(forLabel label: String) -> ChannelFXChain {
        channelFX[label] ?? (voicePolishEnabled ? .preset(.voice) : .preset(.off))
    }
    /// A07 (issue #119): headphone-monitoring state for the command
    /// interface — on/off, the selected output (nil = system default),
    /// whether the selection is unplugged and the monitor is honestly
    /// falling back to the default, and the feedback-risk input UID (the
    /// monitor device is also an enabled capture input).
    var monitoringEnabled = false
    var monitorOutputDeviceUID: String?
    var monitorOutputFallback = false
    var monitorFeedbackRiskDeviceUID: String?
    /// A10 (issue #122): the persisted A/V delay + ducking configuration
    /// (mirrors `StreamSettings.audioDelaysMs` / `.videoDelaysMs` /
    /// `.ducking`). Live session state, not scene content (never undoable,
    /// never staged) — the A/V-sync controls read and edit through these.
    var audioDelaysMs: [String: Double] = [:]
    var videoDelaysMs: [String: Double] = [:]
    var ducking: DuckingSettings = DuckingSettings()
    /// A09 (issue #121): echo handling + feedback diagnostics for the command
    /// interface — the persisted mode, whether the OS Voice Isolation mic
    /// mode is active on the live mic (nil = unknown/not preferred), and the
    /// latest warnings (duplicate routes with repairs, per-mic howl risk).
    var echoHandlingMode: EchoHandlingMode = .off
    var voiceIsolationActive: Bool? = nil
    var feedbackDiagnostics = FeedbackDiagnostics()
    /// S12 undo/redo availability and the labels of the edits ⌘Z / ⇧⌘Z would
    /// apply (the Edit menu shows "Undo <label>").
    var canUndo = false
    var canRedo = false
    var undoLabel: String? = nil
    var redoLabel: String? = nil
    /// G11 (issue #117): the annotation surface mirror — active tool, drawing
    /// settings, the staged scene's stroke summary, and the live pointer. The
    /// Annotate menu, the toolbar, and the canvas chrome read this (the
    /// dispatcher's own published state) instead of the nested store.
    var annotations: AnnotationUIState = .empty
}

// MARK: - Dispatcher

/// The single ordered entry point for studio actions. Owned by the app shell
/// and injected via the SwiftUI environment; holds the controllers it drives
/// and publishes the merged `StudioState` — refreshed synchronously after
/// every executed command, and on the next run-loop tick when an underlying
/// controller changes on its own (publisher events fold into `streamState`,
/// the writer finishes a recording).
@MainActor
final class StudioCommandDispatcher: ObservableObject {
    @Published private(set) var state: StudioState
    /// The latest rejection, for transient surfacing in the diagnostics
    /// strip. `sequence` makes repeated identical rejections distinct so the
    /// UI re-surfaces each one; auto-clears after a few seconds.
    @Published private(set) var lastRejection: Rejection?

    struct Rejection: Equatable, Sendable {
        let sequence: Int
        let command: String
        let message: String
    }

    private let controller: StreamController
    private let sceneStore: SceneStore
    private let session: SettingsSession
    private let recorder: RecordingController
    /// The W03 preview/program model: staged vs program scene snapshots.
    private let previewProgram: PreviewProgramModel
    /// S12 (issue #75): the scene-edit undo stack. One entry per executed
    /// undoable command, recorded in `execute` around `perform`.
    private let undoStack = UndoStack<SceneUndoSnapshot>()

    private var rejectionSequence = 0
    private var rejectionTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    /// A04: live channel-ID lookup by persisted label, so the engine push can
    /// address channels the mixer document names. Seeded with the mic; media/
    /// app/guest IDs register as their commands arrive (their labels persist
    /// harmlessly until those surfaces land).
    private var channelIDsByLabel: [String: AudioChannelID] = [:]
    /// A04: the mixer state last pushed to the engine — the push re-fires
    /// only on change (self-healing: the controller mirrors mixer gains, so
    /// engine restarts and settings applies re-apply them without help).
    private var lastPushedMixer: (mixer: MixerSettings, micVolume: Double)?
    /// A03 (issue #98): the soundboard document (pads + music playlists,
    /// persisted beside the scene documents) and its playback runtime (pad
    /// triggers, playlist transport, scene-sound rules). Owned here so the
    /// panel, keyboard, and hardware/automation triggers share one instance.
    let soundboardStore: SoundboardStore
    let soundboard: SoundboardController
    /// S09 (issue #100): the Take-time transition side-effects — stinger
    /// playback (video mask + mix audio) and the transition lifecycle
    /// publisher. Owned here so the Take paths, the transition settings UI,
    /// and future automation share one instance.
    let transitions: TransitionController
    /// E05 (issue #109): the per-device hardware camera control center —
    /// capability snapshots for the inspector surface and the live
    /// apply/reaction operations the `.setCameraControls` /
    /// `.triggerCameraReaction` commands ride. Owned here so UI, and later
    /// automation/hardware controllers, share one instance.
    let cameraControls: CameraControlCenter
    /// E03 (issue #164): the person-segmentation capability + live per-source
    /// segmentation status the Background Effects inspector surface reads.
    /// Read-only — effect settings ride E01's existing source-effect
    /// commands, so no new command kinds (and no `isUndoableSceneEdit`
    /// classification) exist for E03.
    let backgroundEffects: BackgroundEffectsCenter
    /// E06 (issue #165): the PTZ document (network targets, presets,
    /// scene recall links — the soundboard-document precedent) and its
    /// runtime (transports, stop-on-focus-loss discipline, Take-seam recall).
    /// Owned here so the inspector section, keyboard, and future
    /// hardware/automation triggers share one instance.
    let ptzStore: PTZPresetStore
    let ptz: PTZController
    /// G11 (issue #117): the annotation document (per-scene strokes +
    /// visibility + program gate) and session state (active tool, drawing
    /// settings, laser pointer). Owned here so the toolbar, the canvas
    /// overlay, the Annotate menu, and future automation share one instance
    /// and every mutation routes through the annotation commands.
    let annotations: AnnotationStore
    /// G06 (issue #113): the presentations document (per-source selected page
    /// + fit/fill framing, persisted beside the PTZ/soundboard documents).
    /// Owned here so the inspector section, the Present menu, and future
    /// automation share one instance and every mutation routes through the
    /// pdf navigation commands. Its off-main mirror (`PDFDeckStateStore`) is
    /// what the page-rendering engines read on the render tick.
    let pdfDecks: PDFDeckStore
    /// P03 (issue #80): the asset library — G06 imports presentation
    /// documents through it (project copies, so project packaging retains the
    /// bytes) and the section view reads availability/usage from it. Parked
    /// here (the AssetLibraryPanelView hook's documented alternative) so
    /// MainWindowView needs no new environment plumbing.
    let assetLibrary: AssetLibraryStore
    let rundown: ShowRundownController
    let lutLibrary = LUTLibraryController()

    /// A11 (issue #123): the hosted Audio Units running in one channel's FX
    /// graph, keyed by chain-slot ID (passthrough to the controller — the
    /// rack polls this while open; a persisted slot with no handle did not
    /// load). The rack's generic parameter editor binds to the returned
    /// handles' thread-safe parameter tree / fullState surface.
    func hostedAudioUnitHandles(forLabel label: String) -> [UUID: HostedAudioUnitHandle] {
        controller.hostedAudioUnitHandles(forChannelLabel: label)
    }

    init(controller: StreamController,
         sceneStore: SceneStore,
         session: SettingsSession,
         recorder: RecordingController,
         previewProgram: PreviewProgramModel) {
        self.controller = controller
        self.sceneStore = sceneStore
        self.session = session
        self.recorder = recorder
        self.previewProgram = previewProgram
        let soundboardStore = SoundboardStore()
        self.soundboardStore = soundboardStore
        self.soundboard = SoundboardController(store: soundboardStore,
                                               controller: controller)
        let transitions = TransitionController(controller: controller)
        self.transitions = transitions
        // E05 (issue #109): the camera control center (capability snapshots +
        // live hardware/reaction operations for the `.setCameraControls` /
        // `.triggerCameraReaction` commands).
        self.cameraControls = CameraControlCenter(deviceMonitor: controller.deviceMonitor,
                                                  pool: controller.capturePool,
                                                  session: session)
        // E03 (issue #164): the background-effects status center (capability
        // matrix + live segmentation state for the inspector; read-only).
        self.backgroundEffects = BackgroundEffectsCenter()
        // E06 (issue #165): the PTZ document + runtime (see the property
        // docs; created like the soundboard pair above).
        let ptzStore = PTZPresetStore()
        self.ptzStore = ptzStore
        self.ptz = PTZController(store: ptzStore)
        // G11 (issue #117): the annotation document + session state (see the
        // property doc; created like the soundboard pair above).
        self.annotations = AnnotationStore()
        // G06 (issue #113): the presentations document + the P03 asset
        // library it resolves documents through (see the property docs).
        self.pdfDecks = PDFDeckStore()
        self.assetLibrary = AssetLibraryStore()
        self.rundown = ShowRundownController()
        // G06: the pool's PDF engines resolve documents through the library.
        controller.capturePool.assetLibrary = assetLibrary
        // G08 (issue #115): web widget hosts reach the asset library through
        // this process-wide seam (local-HTML widgets only; URL widgets and
        // bundled fixtures never touch it).
        BrowserOverlayAssetResolver.access = { [assetLibrary] rawID in
            guard let uuid = UUID(uuidString: rawID) else { return nil }
            return assetLibrary.access(for: AssetID(uuid))
        }
        BrowserOverlayAssetResolver.noteUsage = { [assetLibrary] rawID, site in
            guard let uuid = UUID(uuidString: rawID) else { return }
            assetLibrary.noteUsage(of: AssetID(uuid), from: site)
        }
        self.state = StudioState()
        // G06: PDF engine status re-clamps persisted deck state on document
        // load (self capture must follow full initialization).
        controller.capturePool.onPDFStatus = { [weak self] id, status in
            guard let self, status.pageCount > 0 else { return }
            self.pdfDecks.notePageCount(status.pageCount, for: id)
        }
        rundown.onCue = { [weak self] entry in
            guard let self else { return }
            let result = self.execute(.runRundownCue(entry.id))
            if case .rejected(let error) = result.outcome { self.rundown.fail(error.description) }
        }
        controller.capturePool.onMediaReachedEnd = { [weak self] sourceID, endedAt in
            guard let self, let program = self.previewProgram.programScene,
                  self.rundown.playback.current?.sceneID == program.id.rawValue,
                  self.mediaSourceIDs(in: program, registry: SceneGraph.index(self.sceneStore.scenes))
                    .contains(sourceID) else { return }
            self.rundown.noteMediaEnd(at: endedAt)
        }
        let mic = AudioChannelID.microphone(deviceUID: nil)
        channelIDsByLabel[mic.label] = mic
        refreshState()

        // S09: preload every configured stinger (restored default + per-scene
        // overrides) so a Take starts decoding immediately, and surface
        // stinger failures/fallbacks transiently like command rejections.
        transitions.preloadStinger(for: sceneStore.defaultTransition)
        for scene in sceneStore.scenes {
            transitions.preloadStinger(for: scene.transition)
        }
        transitions.$lastError
            .compactMap { $0 }
            .sink { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.postTransientNotice(command: "Stinger", message: message)
                }
            }
            .store(in: &cancellables)

        // External changes (publisher events, the recording writer finishing,
        // scene edits) never pass through `execute`, so observe the stores
        // directly. `objectWillChange` fires in willSet — the Task hop lands
        // post-set, so the snapshot reads current values. G06: the deck store
        // and asset library join the merge so PDF section views reading
        // `dispatcher.pdfDecks` / `dispatcher.assetLibrary` refresh with the
        // dispatcher's own published state.
        Publishers.Merge(
            Publishers.Merge4(
                controller.objectWillChange,
                sceneStore.objectWillChange,
                session.objectWillChange,
                recorder.objectWillChange),
            Publishers.Merge4(
                previewProgram.objectWillChange,
                annotations.objectWillChange,
                pdfDecks.objectWillChange,
                assetLibrary.objectWillChange))
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshState()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: Execution

    /// Validates, then executes, one command — synchronously on the main
    /// actor, so execution is strictly ordered and no two commands interleave.
    /// A rejected command performs no work; its result carries the unchanged
    /// state plus the reason.
    @discardableResult
    func execute(_ command: StudioCommand) -> StudioCommandResult {
        if let error = validate(command) {
            postRejection(command: command, error: error)
            return StudioCommandResult(outcome: .rejected(error), state: state)
        }
        // S12: snapshot the undoable state around undoable scene edits. The
        // record happens only when the command actually changed something
        // (the stack drops pre == post no-ops).
        let preUndoSnapshot = command.isUndoableSceneEdit ? captureUndoSnapshot() : nil
        perform(command)
        if let preUndoSnapshot {
            undoStack.record(label: command.label,
                             coalescingKey: command.undoCoalescingKey,
                             pre: preUndoSnapshot,
                             post: captureUndoSnapshot())
        }
        refreshState()
        return StudioCommandResult(outcome: .success, state: state)
    }

    /// Nil when the command would execute right now; the rejection reason
    /// otherwise. Same validation `execute` applies — UIs can disable
    /// controls, automation can pre-flight.
    func canExecute(_ command: StudioCommand) -> Bool {
        validate(command) == nil
    }

    // MARK: Validation (against current session state, before any execution)

    private func validate(_ command: StudioCommand) -> StudioCommandError? {
        // S02: a locked scene rejects every edit to its CONTENT (whole-scene
        // replacement plus all layer/group edits addressed to it). Selection,
        // browser organization, and the lock toggle stay available.
        if let error = sceneContentLockError(for: command) { return error }
        switch command {
        case .startStream:
            guard controller.streamState.canStart else {
                return .unavailable("The stream is already \(controller.streamState.busyLabel).")
            }
            guard session.activeSettings.isPublishable else {
                return .invalidValue("Complete the connection settings before going live.")
            }
            return nil
        case .stopStream:
            return controller.streamState.isActive
                ? nil : .unavailable("No stream is running.")
        case .startPreview:
            return controller.previewState == .idle
                ? nil : .unavailable("The preview is already running.")
        case .stopPreview:
            return controller.previewState == .active
                ? nil : .unavailable("The preview is not running.")
        case .startRecording:
            return !recorder.state.isActive
                ? nil : .unavailable("Recording is already \(recorder.state == .stopping ? "stopping" : "in progress").")
        case .stopRecording:
            return recorder.state.isRecording
                ? nil : .unavailable("No recording is in progress.")

        case .selectScene(let id):
            return sceneStore.scenes.contains(where: { $0.id == id })
                ? nil : .invalidTarget("Scene \(id) does not exist.")
        case .selectSceneAt(let position):
            return sceneStore.scenes.indices.contains(position - 1)
                ? nil : .invalidTarget("There is no scene at position \(position).")
        case .addScene, .insertScene:
            return nil
        case .renameScene(let id, let name):
            guard sceneStore.scenes.contains(where: { $0.id == id }) else {
                return .invalidTarget("Scene \(id) does not exist.")
            }
            if let error = sceneLockError(for: id, action: "rename") { return error }
            return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .invalidValue("A scene name can't be empty.") : nil
        case .deleteScene(let id):
            guard sceneStore.scenes.contains(where: { $0.id == id }) else {
                return .invalidTarget("Scene \(id) does not exist.")
            }
            if let error = sceneLockError(for: id, action: "delete") { return error }
            return sceneStore.scenes.count > 1
                ? nil : .unavailable("The last remaining scene can't be deleted.")
        case .updateScene(let scene):
            guard sceneStore.scenes.contains(where: { $0.id == scene.id }) else {
                return .invalidTarget("Scene \(scene.id) does not exist.")
            }
            // S06: a whole-scene replacement must not smuggle in a dangling,
            // circular, or over-deep nested-scene reference — validate each
            // reference exactly as if it were being added now, against the
            // document WITH the replacement substituted in.
            if scene.layers.contains(where: { $0.payload.isScene }) {
                var index = SceneGraph.index(sceneStore.scenes)
                index[scene.id] = scene
                for layer in scene.layers {
                    guard case .scene(let reference) = layer.payload else { continue }
                    if let error = nestedReferenceError(referencing: reference.sceneID,
                                                        into: scene,
                                                        in: index,
                                                        layerName: layer.name) {
                        return error
                    }
                }
            }
            // W03: visual edits only ever touch the staged copy, so a whole-
            // scene edit must address the scene staged in preview.
            return previewProgram.stagedScene?.id == scene.id
                ? nil : .invalidTarget("Scene \"\(scene.name)\" is not staged in preview — select it first.")

        case .duplicateScene(let id):
            // Duplicating never modifies the original, so a locked scene
            // still duplicates (the copy starts unlocked) — same rule as
            // layer duplication.
            return sceneStore.scenes.contains(where: { $0.id == id })
                ? nil : .invalidTarget("Scene \(id) does not exist.")
        case .moveScene(let id, let folderID, let anchorID):
            guard sceneStore.scenes.contains(where: { $0.id == id }) else {
                return .invalidTarget("Scene \(id) does not exist.")
            }
            if let error = sceneLockError(for: id, action: "move") { return error }
            if let folderID, !sceneStore.folders.contains(where: { $0.id == folderID }) {
                return .invalidTarget("Folder \(folderID) does not exist.")
            }
            if let anchorID {
                guard anchorID != id else {
                    return .invalidValue("A scene can't be moved relative to itself.")
                }
                guard sceneStore.scenes.contains(where: { $0.id == anchorID }) else {
                    return .invalidTarget("Scene \(anchorID) does not exist.")
                }
            }
            return nil
        case .addSceneFolder(let name):
            if let name, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .invalidValue("A folder name can't be empty.")
            }
            return nil
        case .renameSceneFolder(let id, let name):
            guard sceneStore.folders.contains(where: { $0.id == id }) else {
                return .invalidTarget("Folder \(id) does not exist.")
            }
            return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .invalidValue("A folder name can't be empty.") : nil
        case .deleteSceneFolder(let id),
             .setSceneFolderCollapsed(let id, _):
            return sceneStore.folders.contains(where: { $0.id == id })
                ? nil : .invalidTarget("Folder \(id) does not exist.")
        case .setSceneLocked(let id, _):
            return sceneStore.scenes.contains(where: { $0.id == id })
                ? nil : .invalidTarget("Scene \(id) does not exist.")

        case .setLayerVisibility(let layerID, _, let sceneID),
             .setLayerTransform(let layerID, _, let sceneID),
             .setLayerEffects(let layerID, _, let sceneID),
             .setLayerAudio(let layerID, _, let sceneID):
            switch resolveLayer(layerID, in: sceneID) {
            case .success(let (scene, index)):
                return lockError(for: scene.layers[index], in: scene)
            case .failure(let error): return error
            }

        case .addLayer(let payload, let sceneID):
            switch resolveStagedScene(sceneID) {
            case .failure(let error): return error
            case .success(let scene):
                // S06: nested-scene references validate against the document
                // graph — existence, circular references, nesting depth.
                if case .scene(let reference) = payload {
                    return nestedReferenceError(referencing: reference.sceneID,
                                                into: scene,
                                                in: SceneGraph.index(sceneStore.scenes))
                }
                return payload.isRenderable
                    ? nil
                    : .invalidValue("\(payload.displayName) layers are model-only — the render path composites camera, screen, text, shape, and nested scene layers today.")
            }
        case .removeLayer(let layerID, let sceneID):
            switch resolveLayer(layerID, in: sceneID) {
            case .success(let (scene, index)):
                return lockError(for: scene.layers[index], in: scene)
            case .failure(let error): return error
            }
        case .renameLayer(let layerID, let name, let sceneID):
            switch resolveLayer(layerID, in: sceneID) {
            case .success(let (scene, index)):
                if let error = lockError(for: scene.layers[index], in: scene) { return error }
                return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? .invalidValue("A layer name can't be empty.") : nil
            case .failure(let error): return error
            }
        case .duplicateLayer(let layerID, let sceneID):
            // Duplicating never modifies the source layer, so a locked
            // original still duplicates (the copy starts unlocked).
            switch resolveLayer(layerID, in: sceneID) {
            case .success: return nil
            case .failure(let error): return error
            }
        case .setLayerLocked(let layerID, _, let sceneID):
            switch resolveLayer(layerID, in: sceneID) {
            case .success(let (scene, index)):
                // Locking/unlocking is the one edit a LOCKED layer accepts —
                // but a group lock still owns its members' lock state.
                let layer = scene.layers[index]
                if let group = scene.group(for: layer), group.isLocked {
                    return .unavailable("Layer \"\(layer.name)\" belongs to locked group \"\(group.name)\" — unlock the group first.")
                }
                return nil
            case .failure(let error): return error
            }
        case .moveLayer(let layerID, let toIndex, _, let sceneID):
            switch resolveLayer(layerID, in: sceneID) {
            case .success(let (scene, index)):
                if let error = lockError(for: scene.layers[index], in: scene) { return error }
                // toIndex counts the post-removal array (count - 1 slots).
                return (0..<scene.layers.count).contains(toIndex)
                    ? nil
                    : .invalidValue("Z-order index \(toIndex) is outside the scene's layer stack.")
            case .failure(let error): return error
            }
        case .groupLayers(let layerIDs, _, let sceneID):
            switch resolveStagedScene(sceneID) {
            case .failure(let error): return error
            case .success(let scene):
                guard layerIDs.count > 1 else {
                    return .invalidValue("Select at least two layers to group.")
                }
                for layerID in layerIDs {
                    guard let index = scene.layers.firstIndex(where: { $0.id == layerID }) else {
                        return .invalidTarget("Layer \(layerID) does not exist in scene \"\(scene.name)\".")
                    }
                    if let error = lockError(for: scene.layers[index], in: scene) { return error }
                }
                return nil
            }
        case .ungroupLayers(let groupID, let sceneID),
             .renameGroup(let groupID, _, let sceneID),
             .setGroupLocked(let groupID, _, let sceneID):
            switch resolveGroup(groupID, in: sceneID) {
            case .failure(let error): return error
            case .success(let (scene, group)):
                if case .renameGroup(_, let name, _) = command,
                   name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return .invalidValue("A group name can't be empty.")
                }
                // A locked group rejects edits to itself; unlocking is the
                // one command it still accepts.
                if group.isLocked, !command.isGroupUnlock {
                    let memberCount = scene.members(of: groupID).count
                    return .unavailable("Group \"\(group.name)\" (\(memberCount) layers) is locked — unlock it first.")
                }
                return nil
            }
        case .setGroupVisibility(let groupID, _, let sceneID):
            switch resolveGroup(groupID, in: sceneID) {
            case .failure(let error): return error
            case .success(let (scene, group)):
                if group.isLocked {
                    return .unavailable("Group \"\(group.name)\" is locked — unlock it first.")
                }
                // The cascade writes every member's isVisible, so a locked
                // member rejects the whole toggle rather than silently
                // keeping its own state out of sync.
                if let locked = scene.members(of: groupID).first(where: \.isLocked) {
                    return .unavailable("Layer \"\(locked.name)\" in group \"\(group.name)\" is locked — unlock it first.")
                }
                return nil
            }

        // S04: alignment/distribution act on the selected, EDITABLE layers of
        // the staged scene (locked ones are skipped, like canvas drags).
        case .alignLayers(_, let sceneID):
            switch resolveStagedScene(sceneID) {
            case .failure(let error): return error
            case .success(let scene):
                return alignmentTargets(in: scene).count >= 2
                    ? nil
                    : .invalidValue("Select at least two unlocked layers to align.")
            }
        case .distributeLayers(_, let sceneID):
            switch resolveStagedScene(sceneID) {
            case .failure(let error): return error
            case .success(let scene):
                return alignmentTargets(in: scene).count >= 3
                    ? nil
                    : .invalidValue("Select at least three unlocked layers to distribute.")
            }

        // G11 (issue #117): annotation commands address the annotation
        // document keyed by scene — NOT staged scene content, so locks and
        // staging never gate them (the project-overlay precedent); the
        // target scene must simply exist (nil = the staged scene, the canvas
        // the presenter draws on).
        case .addAnnotationStroke(let stroke, let sceneID):
            switch resolveAnnotationScene(sceneID) {
            case .failure(let error): return error
            case .success:
                return stroke.validationError.map { .invalidValue($0) }
            }
        case .undoAnnotationStroke(let sceneID):
            switch resolveAnnotationScene(sceneID) {
            case .failure(let error): return error
            case .success(let id):
                return annotations.canUndoStroke(in: id)
                    ? nil : .unavailable("There is no annotation to undo.")
            }
        case .redoAnnotationStroke(let sceneID):
            switch resolveAnnotationScene(sceneID) {
            case .failure(let error): return error
            case .success(let id):
                return annotations.canRedoStroke(in: id)
                    ? nil : .unavailable("There is no annotation to redo.")
            }
        case .clearAnnotations(let sceneID):
            switch resolveAnnotationScene(sceneID) {
            case .failure(let error): return error
            case .success(let id):
                return annotations.annotations(for: id).strokes.isEmpty
                    ? .unavailable("The scene has no annotations to clear.") : nil
            }
        case .setAnnotationVisibility(_, let sceneID),
             .setAnnotationsInProgram(_, let sceneID):
            switch resolveAnnotationScene(sceneID) {
            case .failure(let error): return error
            case .success: return nil
            }
        case .setAnnotationTool:
            return nil

        // S07 project overlays: validated against the SceneStore overlay
        // list (project level — never the staged scene).
        case .addOverlay(let payload):
            // Branding overlays only: text/shape render without a capture,
            // and G01 (issue #81) image overlays composite a decoded asset
            // (the logo case). Camera/screen overlays would need the S05
            // demand reconciliation to watch the overlay list (it watches
            // scenes today); the other kinds have no renderer yet. Media
            // overlays go through `.addMediaOverlay` (G09), which also
            // registers their source.
            return payload.isText || payload.isShape || payload.isImage
                ? nil
                : .invalidValue("\(payload.displayName) overlays aren't supported yet — add a Text, Shape, or Image overlay.")
        case .addMediaOverlay(_, let payload):
            // The panel's file pick already validated the format
            // (`MediaOverlayClassifier`); the command only enforces that a
            // file is actually linked.
            return payload.bookmarkData != nil
                ? nil
                : .invalidValue("A media overlay needs a linked file — pick an animated image or an alpha video.")
        case .removeOverlay(let overlayID),
             .setOverlayVisibility(let overlayID, _),
             .setOverlayTransform(let overlayID, _),
             .setOverlayEffects(let overlayID, _):
            switch resolveOverlay(overlayID) {
            case .success(let overlay): return overlayLockError(for: overlay)
            case .failure(let error): return error
            }
        case .renameOverlay(let overlayID, let name):
            switch resolveOverlay(overlayID) {
            case .success(let overlay):
                if let error = overlayLockError(for: overlay) { return error }
                return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? .invalidValue("An overlay name can't be empty.") : nil
            case .failure(let error): return error
            }
        case .setOverlayLocked(let overlayID, _):
            // Locking/unlocking is the one edit a LOCKED overlay accepts.
            switch resolveOverlay(overlayID) {
            case .success: return nil
            case .failure(let error): return error
            }
        case .moveOverlay(let overlayID, let toIndex):
            switch resolveOverlay(overlayID) {
            case .success(let overlay):
                if let error = overlayLockError(for: overlay) { return error }
                // toIndex counts the post-removal array (count - 1 slots).
                return (0..<sceneStore.overlays.count).contains(toIndex)
                    ? nil
                    : .invalidValue("Z-order index \(toIndex) is outside the overlay stack.")
            case .failure(let error): return error
            }
        case .setOverlayHiddenInScene(let overlayID, _, let sceneID):
            // Scene content: the override lands on the STAGED scene.
            switch resolveStagedScene(sceneID) {
            case .failure(let error): return error
            case .success:
                return sceneStore.overlays.contains(where: { $0.id == overlayID })
                    ? nil : .invalidTarget("Overlay \(overlayID) does not exist.")
            }
        case .setSceneBackground(_, let sceneID):
            switch resolveStagedScene(sceneID) {
            case .failure(let error): return error
            case .success: return nil
            }
        case .setDefaultBackground:
            return nil
        // S09 (issue #100): transition settings — same targeting rules as
        // the scene background (staged-scene content vs project default).
        case .setSceneTransition(let transition, let sceneID):
            switch resolveStagedScene(sceneID) {
            case .failure(let error): return error
            case .success: return transition?.validationError.map { .invalidValue($0) }
            }
        case .setDefaultTransition(let transition):
            return transition.validationError.map { .invalidValue($0) }

        // E01 (issue #101): layer overrides are staged layer edits (same
        // targeting + lock rules as `.setLayerEffects`, plus range
        // validation the value model owns); source defaults address the
        // registry; presets are project-level documents.
        case .setLayerSourceEffects(let layerID, let effects, let sceneID):
            switch resolveLayer(layerID, in: sceneID) {
            case .success(let (scene, index)):
                if let error = lockError(for: scene.layers[index], in: scene) { return error }
                return effects?.validationError.map { .invalidValue($0) }
            case .failure(let error): return error
            }
        case .setSourceEffectDefaults(let id, let effects):
            guard sceneStore.source(withID: id) != nil else {
                return .invalidTarget("Source \(id) does not exist.")
            }
            return effects?.validationError.map { .invalidValue($0) }
        case .addEffectPreset(let preset):
            return preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .invalidValue("A preset name can't be empty.") : nil
        case .updateEffectPreset(let preset):
            guard sceneStore.effectPreset(withID: preset.id) != nil else {
                return .invalidTarget("Effect preset \(preset.id) does not exist.")
            }
            return preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .invalidValue("A preset name can't be empty.") : nil
        case .removeEffectPreset(let id):
            return sceneStore.effectPreset(withID: id) != nil
                ? nil : .invalidTarget("Effect preset \(id) does not exist.")

        // G03 (issue #106): layer styles follow the `.setLayerEffects` /
        // `.setLayerSourceEffects` targeting + lock rules, with range
        // validation the style model owns; overlay styles follow the S07
        // overlay rules; style presets mirror the E01 preset rules.
        case .setLayerStyle(let layerID, let style, let sceneID):
            switch resolveLayer(layerID, in: sceneID) {
            case .success(let (scene, index)):
                if let error = lockError(for: scene.layers[index], in: scene) { return error }
                return style.validationError.map { .invalidValue($0) }
            case .failure(let error): return error
            }
        case .setOverlayStyle(let overlayID, let style):
            switch resolveOverlay(overlayID) {
            case .success(let overlay):
                if let error = overlayLockError(for: overlay) { return error }
                return style.validationError.map { .invalidValue($0) }
            case .failure(let error): return error
            }
        case .addStylePreset(let preset):
            return preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .invalidValue("A preset name can't be empty.") : nil
        case .updateStylePreset(let preset):
            guard sceneStore.stylePreset(withID: preset.id) != nil else {
                return .invalidTarget("Style preset \(preset.id) does not exist.")
            }
            return preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .invalidValue("A preset name can't be empty.") : nil
        case .removeStylePreset(let id):
            return sceneStore.stylePreset(withID: id) != nil
                ? nil : .invalidTarget("Style preset \(id) does not exist.")

        // G02 (issue #110): text payloads follow the `.setLayerStyle` /
        // `.setOverlayStyle` targeting + lock rules (plus the payload must
        // stay a TEXT edit on a text layer — never a kind change), with range
        // validation the style model owns; title-style presets mirror the
        // G03 preset rules.
        case .setLayerMotionIdentity(let layerID, _, let sceneID):
            switch resolveLayer(layerID, in: sceneID) {
            case .success(let (scene, index)): return lockError(for: scene.layers[index], in: scene)
            case .failure(let error): return error
            }
        case .setDynamicOverlayTransport(let layerID, _, let sceneID):
            switch resolveDynamicOverlay(layerID, in: sceneID) {
            case .success: return nil
            case .failure(let error): return error
            }
        case .setLayerText(let layerID, let payload, let sceneID):
            switch resolveLayer(layerID, in: sceneID) {
            case .success(let (scene, index)):
                if let error = lockError(for: scene.layers[index], in: scene) { return error }
                guard scene.layers[index].payload.isText else {
                    return .invalidTarget("Layer \"\(scene.layers[index].name)\" is not a text layer.")
                }
                return payload.validationError.map { .invalidValue($0) }
            case .failure(let error): return error
            }
        case .setOverlayText(let overlayID, let payload):
            switch resolveOverlay(overlayID) {
            case .success(let overlay):
                if let error = overlayLockError(for: overlay) { return error }
                guard overlay.payload.isText else {
                    return .invalidTarget("Overlay \"\(overlay.name)\" is not a text overlay.")
                }
                return payload.validationError.map { .invalidValue($0) }
            case .failure(let error): return error
            }
        // G01 (issue #81): image payloads follow the G02 text targeting +
        // lock rules (a payload edit never changes the layer KIND; format
        // validation happened at the pick/drop — `ImageAssetValidator`).
        case .setLayerImage(let layerID, _, let sceneID):
            switch resolveLayer(layerID, in: sceneID) {
            case .success(let (scene, index)):
                if let error = lockError(for: scene.layers[index], in: scene) { return error }
                return scene.layers[index].payload.isImage
                    ? nil
                    : .invalidTarget("Layer \"\(scene.layers[index].name)\" is not an image layer.")
            case .failure(let error): return error
            }
        case .setOverlayImage(let overlayID, _):
            switch resolveOverlay(overlayID) {
            case .success(let overlay):
                if let error = overlayLockError(for: overlay) { return error }
                return overlay.payload.isImage
                    ? nil
                    : .invalidTarget("Overlay \"\(overlay.name)\" is not an image overlay.")
            case .failure(let error): return error
            }
        case .setLayerWeb(let layerID, _, let sceneID):
            // G08: the payload normalizes fail-closed (unsupported URL
            // schemes clear; fps/viewport clamp), so an "invalid" widget
            // config can never be written — only the target checks apply.
            switch resolveLayer(layerID, in: sceneID) {
            case .success(let (scene, index)):
                if let error = lockError(for: scene.layers[index], in: scene) { return error }
                guard scene.layers[index].payload.isWeb else {
                    return .invalidTarget("Layer \"\(scene.layers[index].name)\" is not a browser source.")
                }
                return nil
            case .failure(let error): return error
            }
        case .setOverlayWeb(let overlayID, _):
            switch resolveOverlay(overlayID) {
            case .success(let overlay):
                if let error = overlayLockError(for: overlay) { return error }
                guard overlay.payload.isWeb else {
                    return .invalidTarget("Overlay \"\(overlay.name)\" is not a browser source.")
                }
                return nil
            case .failure(let error): return error
            }
        case .addTextStylePreset(let preset):
            if preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .invalidValue("A preset name can't be empty.")
            }
            return preset.style.validationError.map { .invalidValue($0) }
        case .updateTextStylePreset(let preset):
            guard sceneStore.textStylePreset(withID: preset.id) != nil else {
                return .invalidTarget("Title style preset \(preset.id) does not exist.")
            }
            if preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .invalidValue("A preset name can't be empty.")
            }
            return preset.style.validationError.map { .invalidValue($0) }
        case .removeTextStylePreset(let id):
            return sceneStore.textStylePreset(withID: id) != nil
                ? nil : .invalidTarget("Title style preset \(id) does not exist.")

        // A02 media transport: session state — the target must be a
        // registered media source; locks and staging don't apply.
        case .mediaPlay(let id), .mediaPause(let id),
             .mediaStop(let id), .mediaRestart(let id):
            return mediaTransportError(for: id)
        case .mediaSeek(let id, let seconds):
            if let error = mediaTransportError(for: id) { return error }
            return seconds.isFinite && seconds >= 0
                ? nil
                : .invalidValue("Seek position must be a non-negative number of seconds.")

        // G06 (issue #113): page navigation is program-aware session state —
        // the target must be a REGISTERED PDF source; locks and staging don't
        // apply (the A02 media-transport precedent).
        case .pdfNextPage(let id), .pdfPreviousPage(let id),
             .pdfSetFraming(let id, _):
            return pdfNavigationError(for: id)
        case .pdfGoToPage(let id, let page):
            if let error = pdfNavigationError(for: id) { return error }
            return page >= 0
                ? nil
                : .invalidValue("A page number must be zero or greater.")

        case .setOutputProfile:
            // Always acceptable: the controller clamps to hardware/destination
            // and stages the edit while outputs own the geometry (W07).
            return nil

        // A04 mixer validation. Capture-channel levels/mutes are scene audio
        // bindings — the mixer UI edits those via `.setLayerAudio`, so a
        // direct mixer gain command on a capture channel is rejected with
        // guidance rather than silently fighting the binding.
        case .setChannelVolume(let id, let volume):
            if case .capture = id {
                return .invalidValue("Capture channel levels are scene audio bindings — edit the layer's audio instead.")
            }
            return volume.isFinite && (0...2).contains(volume)
                ? nil : .invalidValue("Channel volume must be between 0 and 2.")
        case .setChannelMuted(let id, _):
            if case .capture = id {
                return .invalidValue("Capture channel mute is a scene audio binding — edit the layer's audio instead.")
            }
            return nil
        case .setChannelSolo:
            // Solo is mixer (monitor) state: any channel kind may solo.
            return nil
        case .setChannelAuxSend(_, let send):
            return send.isFinite && (0...1).contains(send)
                ? nil : .invalidValue("Aux send must be between 0 and 1.")
        case .setBusGain(_, let gain):
            return gain.isFinite && (0...2).contains(gain)
                ? nil : .invalidValue("Bus gain must be between 0 and 2.")
        case .setBusMuted:
            return nil

        // A05 multi-mic validation: enablement is free-form (a device may be
        // enabled while unplugged — it reports missing and recovers); mapping
        // requires a configured input; relink requires a connected target.
        case .setAudioInputEnabled(let uid, _):
            return uid.isEmpty
                ? .invalidValue("An audio input device must be selected.") : nil
        case .setAudioInputMapping(let uid, let mapping):
            guard session.activeSettings.audioInputs.contains(where: { $0.deviceUID == uid }) else {
                return .invalidTarget("Audio input \(uid) is not configured — enable it first.")
            }
            switch mapping {
            case .all: return nil
            case .mono(let channel): return channel >= 0
                ? nil : .invalidValue("Channel indices must be zero or greater.")
            case .stereo(let left, let right): return left >= 0 && right >= 0
                ? nil : .invalidValue("Channel indices must be zero or greater.")
            }
        case .relinkAudioInput(let from, let to):
            guard from != to else {
                return .invalidValue("The input is already linked to that device.")
            }
            return controller.deviceMonitor.audioDevices.contains(where: { $0.uniqueID == to })
                ? nil : .invalidTarget("The relink target device is not connected.")

        // A08 FX validation: the chain model owns its ranges (the rack's
        // sliders clamp to the same values, so this guards automation input).
        case .setChannelFXChain(_, let chain):
            return chain.validationError.map { .invalidValue($0) }

        // A07 monitoring validation: enabling is always acceptable; an
        // explicit output device must be CONNECTED (nil = system default is
        // always valid). Selecting a device while it is unplugged is
        // rejected rather than silently pinning a fallback.
        case .setMonitoringEnabled:
            return nil
        case .setMonitorOutputDevice(let uid):
            guard let uid else { return nil }
            return controller.monitorOutput.devices.contains(where: { $0.uid == uid })
                ? nil : .invalidTarget("That output device is not connected.")

        // A10 (issue #122): delays clamp to their documented engine bounds;
        // the ducking model owns its parameter ranges (the settings UI
        // clamps to the same values, so this guards automation input).
        case .setChannelAudioDelay(_, let ms):
            return ms.isFinite && (0...AVSyncDelay.maxAudioDelayMs).contains(ms)
                ? nil
                : .invalidValue("Audio delay must be between 0 and \(Int(AVSyncDelay.maxAudioDelayMs)) ms.")
        case .setSourceVideoDelay(let id, let ms):
            guard sceneStore.source(withID: id) != nil else {
                return .invalidTarget("Source \(id) does not exist.")
            }
            return ms.isFinite && (0...AVSyncDelay.maxVideoDelayMs).contains(ms)
                ? nil
                : .invalidValue("Video delay must be between 0 and \(Int(AVSyncDelay.maxVideoDelayMs)) ms.")
        case .setDucking(let ducking):
            return ducking.validationError.map { .invalidValue($0) }

        // A09 echo handling validation: both modes are always acceptable —
        // Voice Isolation is a PREFERENCE the OS honors where supported, so
        // an unsupported device degrades to guidance, never a rejection.
        case .setEchoHandlingMode:
            return nil

        // E05 (issue #109): camera control validation — the target must be a
        // CONNECTED video device, and every requested mode must be one the
        // device's discovered capabilities honor (no inert writes). Reaction
        // triggers gate on the OS/user enablement + per-device/per-format
        // support folded into `canPerformReactionEffects`, and on the
        // device's live `availableReactionTypes` list — a rejected trigger
        // carries the explicit reason.
        case .setCameraControls(let uid, let controls):
            guard let device = controller.deviceMonitor.videoDevices
                    .first(where: { $0.uniqueID == uid }) else {
                return .invalidTarget("That camera is not connected.")
            }
            let capabilities = device.cameraControlCapabilities
            if let mode = controls.focusMode, !capabilities.focusModes.contains(mode) {
                return .unavailable("\(device.localizedName) doesn't support \(mode == .locked ? "locking focus" : "auto focus").")
            }
            if let mode = controls.exposureMode, !capabilities.exposureModes.contains(mode) {
                return .unavailable("\(device.localizedName) doesn't support \(mode == .locked ? "locking exposure" : "auto exposure").")
            }
            if let mode = controls.whiteBalanceMode, !capabilities.whiteBalanceModes.contains(mode) {
                return .unavailable("\(device.localizedName) doesn't support \(mode == .locked ? "locking white balance" : "auto white balance").")
            }
            return nil
        case .triggerCameraReaction(let uid, let reaction):
            guard let device = controller.deviceMonitor.videoDevices
                    .first(where: { $0.uniqueID == uid }) else {
                return .invalidTarget("That camera is not connected.")
            }
            let capabilities = device.cameraControlCapabilities
            guard capabilities.reactionsAvailable else {
                return .unavailable(capabilities.reactionUnavailableReason
                    ?? "Reactions aren't available on this camera right now.")
            }
            return capabilities.supportedReactions.contains(reaction)
                ? nil
                : .unavailable("\(reaction.displayName) isn't available on \(device.localizedName) right now.")

        // A03 soundboard/playlist validation (issue #98): transport and
        // structural commands address the soundboard document's stable IDs
        // (locks and staging never apply — the media-transport precedent).
        case .addSoundPad(let pad):
            return pad.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .invalidValue("A pad name can't be empty.") : nil
        case .updateSoundPad(let pad):
            guard soundboardStore.pad(withID: pad.id) != nil else {
                return .invalidTarget("Sound pad \(pad.id) does not exist.")
            }
            return pad.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .invalidValue("A pad name can't be empty.") : nil
        case .removeSoundPad(let id),
             .triggerSoundPad(let id),
             .stopSoundPad(let id):
            return soundboardStore.pad(withID: id) != nil
                ? nil : .invalidTarget("Sound pad \(id) does not exist.")
        case .stopAllSoundEffects:
            return nil
        case .addMusicPlaylist(let playlist):
            return playlist.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .invalidValue("A playlist name can't be empty.") : nil
        case .updateMusicPlaylist(let playlist):
            guard soundboardStore.playlist(withID: playlist.id) != nil else {
                return .invalidTarget("Playlist \(playlist.id) does not exist.")
            }
            return playlist.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .invalidValue("A playlist name can't be empty.") : nil
        case .removeMusicPlaylist(let id):
            return soundboardStore.playlist(withID: id) != nil
                ? nil : .invalidTarget("Playlist \(id) does not exist.")
        case .playlistPlay(let id):
            guard let playlist = soundboardStore.playlist(withID: id) else {
                return .invalidTarget("Playlist \(id) does not exist.")
            }
            return playlist.tracks.isEmpty
                ? .unavailable("Playlist \"\(playlist.name)\" has no tracks — add audio files first.")
                : nil
        case .playlistPause(let id), .playlistStop(let id):
            return soundboardStore.playlist(withID: id) != nil
                ? nil : .invalidTarget("Playlist \(id) does not exist.")
        case .playlistNext(let id), .playlistPrevious(let id):
            guard let playlist = soundboardStore.playlist(withID: id) else {
                return .invalidTarget("Playlist \(id) does not exist.")
            }
            return playlist.tracks.isEmpty
                ? .unavailable("Playlist \"\(playlist.name)\" has no tracks.")
                : nil
        case .setSceneSoundBindings(let bindings, let sceneID):
            switch resolveStagedScene(sceneID) {
            case .failure(let error): return error
            case .success:
                for binding in bindings {
                    if binding.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return .invalidValue("A scene sound name can't be empty.")
                    }
                    if !(0...2).contains(binding.volume) {
                        return .invalidValue("Scene sound volume must be between 0 and 2.")
                    }
                }
                return nil
            }
        // S08 (issue #99): scene content addressed to the staged scene,
        // exactly like `.setSceneSoundBindings`.
        case .setSceneAudioSnapshot(let snapshot, let sceneID):
            switch resolveStagedScene(sceneID) {
            case .failure(let error): return error
            case .success:
                for (label, state) in snapshot?.channelGains ?? [:] {
                    if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return .invalidValue("A snapshot channel label can't be empty.")
                    }
                    if !state.volume.isFinite || !(0...2).contains(state.volume) {
                        return .invalidValue("Scene audio snapshot volumes must be between 0 and 2.")
                    }
                }
                return nil
            }
        case .captureSceneAudioSnapshot(let sceneID),
             .setSceneMediaBehavior(_, let sceneID):
            switch resolveStagedScene(sceneID) {
            case .failure(let error): return error
            case .success: return nil
            }

        // E06 PTZ validation (issue #165): hardware/session commands —
        // targets must exist, hosts/ports/addresses must be usable, speeds
        // stay inside the pinned VISCA ranges, and a recall names a slot the
        // document knows about (an unstored slot is a silent no-op on most
        // cameras, so it's rejected instead). Locks and staging never apply.
        case .ptzAddTarget(let target):
            return ptzTargetError(for: target, requireNew: true)
        case .ptzUpdateTarget(let target):
            return ptzTargetError(for: target, requireNew: false)
        case .ptzRemoveTarget(let id), .ptzStop(let id):
            return ptzStore.target(withID: id) != nil
                ? nil : .invalidTarget("PTZ camera \(id) is not configured.")
        case .ptzMove(let id, _, let panSpeed, let tiltSpeed):
            guard ptzStore.target(withID: id) != nil else {
                return .invalidTarget("PTZ camera \(id) is not configured.")
            }
            guard (1...VISCAPacket.maxPanSpeed).contains(panSpeed),
                  (1...VISCAPacket.maxTiltSpeed).contains(tiltSpeed) else {
                return .invalidValue("Pan speed must be 1…\(VISCAPacket.maxPanSpeed), tilt speed 1…\(VISCAPacket.maxTiltSpeed).")
            }
            return nil
        case .ptzZoom(let id, _, let speed):
            guard ptzStore.target(withID: id) != nil else {
                return .invalidTarget("PTZ camera \(id) is not configured.")
            }
            return (0...VISCAPacket.maxZoomSpeed).contains(speed)
                ? nil : .invalidValue("Zoom speed must be 0…\(VISCAPacket.maxZoomSpeed).")
        case .ptzStopAll:
            return nil
        case .ptzStorePreset(let id, let number, let name):
            guard ptzStore.target(withID: id) != nil else {
                return .invalidTarget("PTZ camera \(id) is not configured.")
            }
            if let name, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .invalidValue("A preset name can't be empty.")
            }
            return number <= VISCAPacket.maxPresetNumber
                ? nil : .invalidValue("Preset slots run 0…\(VISCAPacket.maxPresetNumber).")
        case .ptzRecallPreset(let id, let number),
             .ptzRemovePreset(let id, let number):
            guard ptzStore.target(withID: id) != nil else {
                return .invalidTarget("PTZ camera \(id) is not configured.")
            }
            return ptzStore.preset(number: number, forTargetID: id) != nil
                ? nil : .invalidTarget("Preset \(number) hasn't been stored for that camera.")
        case .ptzSetSceneRecall(let link):
            guard sceneStore.scenes.contains(where: { $0.id.rawValue == link.sceneID }) else {
                return .invalidTarget("Scene \(link.sceneID) does not exist.")
            }
            guard ptzStore.target(withID: link.targetID) != nil else {
                return .invalidTarget("PTZ camera \(link.targetID) is not configured.")
            }
            return ptzStore.preset(number: link.presetNumber, forTargetID: link.targetID) != nil
                ? nil : .invalidTarget("Preset \(link.presetNumber) hasn't been stored for that camera.")
        case .ptzRemoveSceneRecall(let id):
            return ptzStore.recallLink(withID: id) != nil
                ? nil : .invalidTarget("Scene PTZ recall link \(id) does not exist.")

        case .setRundown(let document):
            return document.validationError.map { .invalidValue($0) }
        case .rundownPlay:
            guard !rundown.document.entries.isEmpty else { return .unavailable("Add scenes to the rundown first.") }
            guard rundown.document.entries.allSatisfy({ entry in
                sceneStore.scenes.contains { $0.id.rawValue == entry.cue.sceneID }
            }) else { return .invalidTarget("A rundown scene is missing. Choose a replacement or remove its cue.") }
            guard !previewProgram.hasPendingEdits else {
                return .unavailable("Take or revert the staged composition before playing the rundown.")
            }
            return nil
        case .runRundownCue(let id):
            guard let entry = rundown.document.entries.first(where: { $0.id == id }),
                  sceneStore.scenes.contains(where: { $0.id.rawValue == entry.cue.sceneID }) else {
                return .invalidTarget("The rundown cue or its scene no longer exists.")
            }
            guard !previewProgram.hasPendingEdits else {
                return .unavailable("The rundown stopped to preserve staged edits. Take or revert them before restarting.")
            }
            return nil
        case .rundownPause, .rundownStop, .rundownSkip:
            return nil
        case .openSettings, .closeSettings:
            return nil
        case .applySettings:
            if !session.blockingErrors.isEmpty {
                return .invalidValue(session.blockingErrors.joined(separator: " "))
            }
            return session.isDirty ? nil : .unavailable("There are no changes to apply.")
        case .revertSettings:
            return session.isDirty ? nil : .unavailable("There are no unapplied changes.")

        case .take:
            return previewProgram.stagedScene != nil
                ? nil : .invalidTarget("No scene is staged to take.")
        case .revert:
            return previewProgram.hasPendingEdits
                ? nil : .unavailable("There are no unpublished changes to revert.")
        case .setDirectLiveEditing(let on):
            return previewProgram.directLiveEditing != on
                ? nil : .unavailable("Direct-live editing is already \(on ? "on" : "off").")
        case .undo:
            return undoStack.canUndo
                ? nil : .unavailable("There is nothing to undo.")
        case .redo:
            return undoStack.canRedo
                ? nil : .unavailable("There is nothing to redo.")
        }
    }

    // MARK: Execution (validation already passed)

    private func perform(_ command: StudioCommand) {
        switch command {
        case .startStream:
            controller.goLive()
            // A03 (issue #98): the pipeline is up — fire the restored program
            // scene's enter rules once (idempotent; a Take already synced
            // the scene is a no-op).
            soundboard.syncProgramScene(previewProgram.programScene)
        case .stopStream: controller.stopStream()
        case .startPreview:
            controller.startPreview()
            // A03: same launch restore as startStream — the program scene's
            // ambient beds and enter stingers start with the pipeline.
            soundboard.syncProgramScene(previewProgram.programScene)
        case .stopPreview: controller.stopPreview()
        case .startRecording: recorder.start(stream: controller)
        case .stopRecording: recorder.stop()

        case .selectScene(let id):
            sceneStore.selectedID = id
            // W03: selection stages in preview; program stays untouched unless
            // direct-live editing is on (standard switcher behavior).
            previewProgram.stage(sceneStore.selected)
            takeStagedIfDirectLive()
        case .selectSceneAt(let position):
            sceneStore.select(number: position)
            previewProgram.stage(sceneStore.selected)
            takeStagedIfDirectLive()
        case .addScene:
            let scene = sceneStore.addScene()
            previewProgram.stage(scene)
            takeStagedIfDirectLive()
        case .insertScene(let scene):
            let inserted = sceneStore.addScene(scene)
            previewProgram.stage(inserted)
            takeStagedIfDirectLive()
        case .renameScene(let id, let name):
            sceneStore.rename(id, to: name)
            previewProgram.noteSceneRenamed(id, to: name)
        case .deleteScene(let id):
            sceneStore.delete(id)
            // The program snapshot survives deletion in memory (the engine
            // holds its own copy) until the next Take; only re-stage when the
            // deletion moved the selection.
            if previewProgram.stagedScene?.id != sceneStore.selectedID {
                previewProgram.stage(sceneStore.selected)
                takeStagedIfDirectLive()
            }
        case .updateScene(let scene):
            previewProgram.applyStagedEdit(scene)
            takeStagedIfDirectLive()

        case .duplicateScene(let id):
            sceneStore.duplicateScene(id)
        case .moveScene(let id, let folderID, let anchorID):
            sceneStore.moveScene(id, toFolder: folderID, before: anchorID)
        case .addSceneFolder(let name):
            sceneStore.addFolder(named: name)
        case .renameSceneFolder(let id, let name):
            sceneStore.renameFolder(id, to: name)
        case .deleteSceneFolder(let id):
            sceneStore.deleteFolder(id)
        case .setSceneFolderCollapsed(let id, let collapsed):
            sceneStore.setFolderCollapsed(id, collapsed: collapsed)
        case .setSceneLocked(let id, let locked):
            sceneStore.setSceneLocked(id, locked: locked)

        case .setLayerVisibility(let layerID, let visible, let sceneID):
            editLayer(layerID, in: sceneID) { $0.isVisible = visible }
        case .setLayerTransform(let layerID, let transform, let sceneID):
            editLayer(layerID, in: sceneID) { $0.transform = transform }
        case .setLayerEffects(let layerID, let effects, let sceneID):
            editLayer(layerID, in: sceneID) { $0.effects = effects }
        case .setLayerAudio(let layerID, let audio, let sceneID):
            editLayer(layerID, in: sceneID) { $0.audio = audio }

        case .addLayer(let payload, let sceneID):
            guard case .success(let scene) = resolveStagedScene(sceneID) else { return }
            var edited = scene
            edited.layers.append(makeLayer(payload: payload, in: scene))
            previewProgram.applyStagedEdit(edited)
            takeStagedIfDirectLive()
        case .removeLayer(let layerID, let sceneID):
            editStagedScene(sceneID) { scene in
                guard let index = scene.layers.firstIndex(where: { $0.id == layerID }) else { return }
                let groupID = scene.layers[index].groupID
                scene.layers.remove(at: index)
                // Never leave an orphaned empty group behind.
                if let groupID, !scene.layers.contains(where: { $0.groupID == groupID }) {
                    scene.groups.removeAll { $0.id == groupID }
                }
            }
        case .duplicateLayer(let layerID, let sceneID):
            editStagedScene(sceneID) { scene in
                guard let index = scene.layers.firstIndex(where: { $0.id == layerID }) else { return }
                var copy = scene.layers[index]
                copy.id = LayerID()
                copy.name += " copy"
                copy.isLocked = false
                scene.layers.insert(copy, at: index + 1)
            }
        case .renameLayer(let layerID, let name, let sceneID):
            editLayer(layerID, in: sceneID) { $0.name = name }
        case .setLayerLocked(let layerID, let locked, let sceneID):
            editLayer(layerID, in: sceneID) { $0.isLocked = locked }
        case .moveLayer(let layerID, let toIndex, let groupID, let sceneID):
            editStagedScene(sceneID) { scene in
                guard let index = scene.layers.firstIndex(where: { $0.id == layerID }) else { return }
                var layer = scene.layers.remove(at: index)
                layer.groupID = groupID
                scene.layers.insert(layer, at: min(toIndex, scene.layers.count))
            }
        case .groupLayers(let layerIDs, let name, let sceneID):
            editStagedScene(sceneID) { scene in
                let memberSet = Set(layerIDs)
                // Ascending indices = back-to-front, so the block keeps the
                // members' relative z-order.
                let memberIndices = scene.layers.indices.filter {
                    memberSet.contains(scene.layers[$0].id)
                }
                guard let frontmost = memberIndices.max() else { return }
                let group = LayerGroup(name: name ?? "Group")
                let block: [LayerNode] = memberIndices.map { index in
                    var layer = scene.layers[index]
                    layer.groupID = group.id
                    return layer
                }
                scene.layers.removeAll { memberSet.contains($0.id) }
                // Land the block where the frontmost member sat, adjusted for
                // the members removed ahead of it.
                let insertion = frontmost - (memberIndices.count - 1)
                scene.layers.insert(contentsOf: block, at: min(insertion, scene.layers.count))
                scene.groups.append(group)
            }
        case .ungroupLayers(let groupID, let sceneID):
            editStagedScene(sceneID) { scene in
                for index in scene.layers.indices where scene.layers[index].groupID == groupID {
                    scene.layers[index].groupID = nil
                }
                scene.groups.removeAll { $0.id == groupID }
            }
        case .renameGroup(let groupID, let name, let sceneID):
            editStagedScene(sceneID) { scene in
                guard let index = scene.groups.firstIndex(where: { $0.id == groupID }) else { return }
                scene.groups[index].name = name
            }
        case .setGroupVisibility(let groupID, let visible, let sceneID):
            editStagedScene(sceneID) { scene in
                for index in scene.layers.indices where scene.layers[index].groupID == groupID {
                    scene.layers[index].isVisible = visible
                }
            }
        case .setGroupLocked(let groupID, let locked, let sceneID):
            editStagedScene(sceneID) { scene in
                guard let index = scene.groups.firstIndex(where: { $0.id == groupID }) else { return }
                scene.groups[index].isLocked = locked
            }

        case .alignLayers(let alignment, let sceneID):
            alignSelectedLayers(alignment, in: sceneID)
        case .distributeLayers(let distribution, let sceneID):
            distributeSelectedLayers(distribution, in: sceneID)

        // G11 (issue #117): annotation execution — write the annotation
        // document through the store (single truth); its publish updates the
        // program bridge, so program-included strokes composite on the
        // program engine's next tick, live-safe like project overlays.
        case .addAnnotationStroke(let stroke, let sceneID):
            if case .success(let id) = resolveAnnotationScene(sceneID) {
                annotations.addStroke(stroke, in: id)
            }
        case .undoAnnotationStroke(let sceneID):
            if case .success(let id) = resolveAnnotationScene(sceneID) {
                annotations.undoStroke(in: id)
            }
        case .redoAnnotationStroke(let sceneID):
            if case .success(let id) = resolveAnnotationScene(sceneID) {
                annotations.redoStroke(in: id)
            }
        case .clearAnnotations(let sceneID):
            if case .success(let id) = resolveAnnotationScene(sceneID) {
                annotations.clearStrokes(in: id)
            }
        case .setAnnotationVisibility(let visible, let sceneID):
            if case .success(let id) = resolveAnnotationScene(sceneID) {
                annotations.setVisible(visible, in: id)
            }
        case .setAnnotationsInProgram(let include, let sceneID):
            if case .success(let id) = resolveAnnotationScene(sceneID) {
                annotations.setIncludeInProgram(include, in: id)
            }
        case .setAnnotationTool(let tool):
            annotations.activeTool = tool
            // Leaving the pointer tool retires the laser dot with it.
            if tool != .pointer {
                annotations.clearPointer()
            }

        // S07 project overlays: project-level edits — SceneStore publishes
        // them to every engine on persist, so staged AND program composite
        // the change on their next tick. No staged edit, no implicit take.
        case .addOverlay(let payload):
            sceneStore.addOverlay(makeOverlay(payload: payload))
        case .addMediaOverlay(let name, let payload):
            // G09 (issue #116): one atomic add — the registry source carries
            // the bookmark + playback policy; the overlay binds to it by ID,
            // so the pool's demand keys its playout by source and a payload
            // edit (loop/end action) never restarts playback. Undo removes
            // the overlay but keeps the registry source (the S12 registry-
            // outside-the-snapshot precedent, like relinked sources).
            let source = sceneStore.addSource(
                SourceDefinition(name: name, payload: .media(payload)))
            sceneStore.addOverlay(makeMediaOverlay(name: name, sourceID: source.id,
                                                   payload: payload))
        case .removeOverlay(let overlayID):
            sceneStore.removeOverlay(overlayID)
        case .renameOverlay(let overlayID, let name):
            editOverlay(overlayID) { $0.name = name }
        case .setOverlayVisibility(let overlayID, let visible):
            editOverlay(overlayID) { $0.isVisible = visible }
        case .setOverlayLocked(let overlayID, let locked):
            editOverlay(overlayID) { $0.isLocked = locked }
        case .setOverlayTransform(let overlayID, let transform):
            editOverlay(overlayID) { $0.transform = transform }
        case .setOverlayEffects(let overlayID, let effects):
            editOverlay(overlayID) { $0.effects = effects }
        case .moveOverlay(let overlayID, let toIndex):
            sceneStore.moveOverlay(overlayID, toIndex: toIndex)
        case .setOverlayHiddenInScene(let overlayID, let hidden, let sceneID):
            // Scene content: stages (and implicitly takes in direct-live)
            // like any other scene edit.
            editStagedScene(sceneID) { scene in
                if hidden {
                    scene.hiddenOverlayIDs.insert(overlayID)
                } else {
                    scene.hiddenOverlayIDs.remove(overlayID)
                }
            }
        case .setSceneBackground(let background, let sceneID):
            editStagedScene(sceneID) { $0.background = background }
        case .setDefaultBackground(let background):
            sceneStore.setDefaultBackground(background)
        // S09 (issue #100): the per-scene override is staged scene content
        // (Takes/reverts/undoes like any edit); the default is project-level
        // and applies immediately. A stinger's media preloads on configure
        // so the next Take starts decoding at once.
        case .setSceneTransition(let transition, let sceneID):
            editStagedScene(sceneID) { $0.transition = transition }
            transitions.preloadStinger(for: transition)
        case .setDefaultTransition(let transition):
            sceneStore.setDefaultTransition(transition)
            transitions.preloadStinger(for: transition)

        // E01 (issue #101): the layer override is staged scene content (and
        // implicitly takes in direct-live) like any layer edit; source
        // defaults and presets write the project registry/documents directly
        // and publish to every engine on the next tick (render-side only —
        // no capture re-key).
        case .setLayerSourceEffects(let layerID, let effects, let sceneID):
            editLayer(layerID, in: sceneID) { $0.effectOverrides = effects }
        case .setSourceEffectDefaults(let id, let effects):
            sceneStore.setSourceEffectDefaults(id, to: effects)
        case .addEffectPreset(let preset):
            sceneStore.addEffectPreset(preset)
        case .updateEffectPreset(let preset):
            sceneStore.updateEffectPreset(preset)
        case .removeEffectPreset(let id):
            sceneStore.removeEffectPreset(id)

        // G03 (issue #106): the layer style is staged scene content (and
        // implicitly takes in direct-live) like any layer edit; overlay
        // styles write the project overlay list (immediate, live-safe);
        // presets write the project document directly.
        case .setLayerStyle(let layerID, let style, let sceneID):
            editLayer(layerID, in: sceneID) { $0.style = style }
        case .setOverlayStyle(let overlayID, let style):
            editOverlay(overlayID) { $0.style = style }
        case .addStylePreset(let preset):
            sceneStore.addStylePreset(preset)
        case .updateStylePreset(let preset):
            sceneStore.updateStylePreset(preset)
        case .removeStylePreset(let id):
            sceneStore.removeStylePreset(id)

        // G02 (issue #110): the text payload is staged scene content (and
        // implicitly takes in direct-live) like any layer edit; overlay
        // payloads write the project overlay list (immediate, live-safe);
        // presets write the project document directly.
        case .setLayerMotionIdentity(let layerID, let id, let sceneID):
            editLayer(layerID, in: sceneID) { $0.motionID = id }
        case .setDynamicOverlayTransport(let layerID, let action, let sceneID):
            if case .success(let id) = resolveDynamicOverlay(layerID, in: sceneID) {
                DynamicOverlayStore.shared.perform(action, id: id)
            }
        case .setLayerText(let layerID, let payload, let sceneID):
            editLayer(layerID, in: sceneID) { $0.payload = .text(payload) }
        case .setOverlayText(let overlayID, let payload):
            editOverlay(overlayID) { $0.payload = .text(payload) }
        // G01 (issue #81): same staging rules as the text payloads above.
        case .setLayerImage(let layerID, let payload, let sceneID):
            editLayer(layerID, in: sceneID) { $0.payload = .image(payload) }
        case .setOverlayImage(let overlayID, let payload):
            editOverlay(overlayID) { $0.payload = .image(payload) }
        case .setLayerWeb(let layerID, let payload, let sceneID):
            // G08: normalization is fail-closed (the payload shim clamps
            // fps/viewport and clears unsupported URL schemes), so the
            // stored value is always within the renderer's contract.
            editLayer(layerID, in: sceneID) { $0.payload = .web(payload.normalizedWebPayload) }
        case .setOverlayWeb(let overlayID, let payload):
            editOverlay(overlayID) { $0.payload = .web(payload.normalizedWebPayload) }
        case .addTextStylePreset(let preset):
            sceneStore.addTextStylePreset(preset)
        case .updateTextStylePreset(let preset):
            sceneStore.updateTextStylePreset(preset)
        case .removeTextStylePreset(let id):
            sceneStore.removeTextStylePreset(id)

        case .mediaPlay(let id): controller.capturePool.playMedia(id)
        case .mediaPause(let id): controller.capturePool.pauseMedia(id)
        case .mediaStop(let id): controller.capturePool.stopMedia(id)
        case .mediaRestart(let id): controller.capturePool.restartMedia(id)
        case .mediaSeek(let id, let seconds):
            controller.capturePool.seekMedia(id, toSeconds: seconds)

        // G06 (issue #113): page navigation writes the ONE shared deck store
        // per source (never a per-canvas fork); the engines pick the change
        // up on their next render tick through the off-main snapshot.
        case .pdfNextPage(let id):
            pdfDecks.advance(by: 1, for: id, fallbackPage: pdfDefaultPage(for: id))
        case .pdfPreviousPage(let id):
            pdfDecks.advance(by: -1, for: id, fallbackPage: pdfDefaultPage(for: id))
        case .pdfGoToPage(let id, let page):
            pdfDecks.setPage(page, for: id)
        case .pdfSetFraming(let id, let framing):
            pdfDecks.setFraming(framing, for: id, fallbackPage: pdfDefaultPage(for: id))

        case .setOutputProfile(let profile, let destination):
            controller.applyOutputProfile(profile, destination: destination)

        // A04 mixer execution: mutate the persisted mixer document through
        // SettingsSession (single truth), register the channel ID so the
        // engine push can address it, and let `refreshState`'s push apply the
        // change live (ramped) through the controller.
        case .setChannelVolume(let id, let volume):
            channelIDsByLabel[id.label] = id
            // Only the DEFAULT mic channel's fader is the live face of
            // `micVolume`; A05 additional mic channels persist in the mixer
            // document by label like every other non-capture channel.
            if id == .microphone(deviceUID: nil) {
                session.persistMicVolume(volume)
            } else {
                var mixer = session.activeSettings.mixer
                mixer.channelVolumes[id.label] = volume
                session.persistMixer(mixer)
            }
        case .setChannelMuted(let id, let muted):
            channelIDsByLabel[id.label] = id
            var mixer = session.activeSettings.mixer
            mixer.channelMutes[id.label] = muted ? true : nil
            session.persistMixer(mixer)
        case .setChannelSolo(let id, let soloed):
            channelIDsByLabel[id.label] = id
            var mixer = session.activeSettings.mixer
            if soloed {
                mixer.soloedChannels.insert(id.label)
            } else {
                mixer.soloedChannels.remove(id.label)
            }
            session.persistMixer(mixer)
        case .setChannelAuxSend(let id, let send):
            channelIDsByLabel[id.label] = id
            var mixer = session.activeSettings.mixer
            mixer.channelAuxSends[id.label] = send > 0 ? send : nil
            session.persistMixer(mixer)
        case .setBusGain(let bus, let gain):
            var mixer = session.activeSettings.mixer
            mixer.busGains[bus.rawValue] = gain
            session.persistMixer(mixer)
        case .setBusMuted(let bus, let muted):
            var mixer = session.activeSettings.mixer
            if muted {
                mixer.mutedBuses.insert(bus.rawValue)
            } else {
                mixer.mutedBuses.remove(bus.rawValue)
            }
            session.persistMixer(mixer)

        // A05 multi-mic execution: mutate the persisted input list through
        // SettingsSession (single truth); its apply starts/stops the affected
        // devices' captures and mix channels live.
        case .setAudioInputEnabled(let uid, let enabled):
            var inputs = session.activeSettings.audioInputs
            if let index = inputs.firstIndex(where: { $0.deviceUID == uid }) {
                inputs[index].isEnabled = enabled
            } else {
                inputs.append(AudioInputSelection(deviceUID: uid, isEnabled: enabled))
            }
            session.persistAudioInputs(inputs)
        case .setAudioInputMapping(let uid, let mapping):
            var inputs = session.activeSettings.audioInputs
            guard let index = inputs.firstIndex(where: { $0.deviceUID == uid }) else { return }
            inputs[index].mapping = mapping
            session.persistAudioInputs(inputs)
        case .relinkAudioInput(let from, let to):
            var inputs = session.activeSettings.audioInputs
            guard let index = inputs.firstIndex(where: { $0.deviceUID == from }) else { return }
            var entry = inputs[index]
            inputs.remove(at: index)
            entry.deviceUID = to
            if let existing = inputs.firstIndex(where: { $0.deviceUID == to }) {
                // The target already has a configured entry: enable wins,
                // the relinked mapping (user's latest intent) replaces it.
                inputs[existing].isEnabled = inputs[existing].isEnabled || entry.isEnabled
                inputs[existing].mapping = entry.mapping
            } else {
                inputs.append(entry)
            }
            session.persistAudioInputs(inputs)

        // A08 FX execution: persist the channel's chain through
        // SettingsSession (single truth, live surface like the mixer); its
        // apply pushes the chain onto the channel's running insert as
        // parameter updates — no capture restart, no audio gap.
        case .setChannelFXChain(let id, let chain):
            channelIDsByLabel[id.label] = id
            session.persistChannelFX(chain, forChannelLabel: id.label)

        // A07 monitoring execution: persist through SettingsSession (single
        // truth); its apply retargets the live monitor player in place.
        case .setMonitoringEnabled(let enabled):
            session.persistMonitoring(enabled: enabled,
                                      deviceUID: session.activeSettings.monitorOutputDeviceUID)
        case .setMonitorOutputDevice(let uid):
            session.persistMonitoring(enabled: session.activeSettings.monitoringEnabled,
                                      deviceUID: uid)

        // A10 (issue #122): delay/ducking execution — persist through
        // SettingsSession (single truth, live surfaces like the mixer); its
        // apply shifts engine read windows / frame-hold lines / duck
        // automation in place. Register the channel ID so the mixer push
        // keeps addressing it too.
        case .setChannelAudioDelay(let id, let ms):
            channelIDsByLabel[id.label] = id
            session.persistAudioDelay(ms, forChannelLabel: id.label)
        case .setSourceVideoDelay(let id, let ms):
            session.persistVideoDelay(ms,
                                      forSourceKey: StreamController.videoDelaySettingsKey(for: id))
        case .setDucking(let ducking):
            session.persistDucking(ducking)

        // A09 echo handling execution: persist through SettingsSession
        // (single truth); its apply refreshes the controller's
        // voice-isolation state reporting in place.
        case .setEchoHandlingMode(let mode):
            session.persistEchoHandlingMode(mode)

        // E05 (issue #109): camera control execution — persist the per-device
        // preference through SettingsSession (single truth), then apply it to
        // the connected hardware in place (device state, shared by preview
        // and program; no capture restart). A mid-flight hardware failure
        // surfaces as a transient notice, never silently.
        case .setCameraControls(let uid, let controls):
            session.persistCameraControls(controls.isEmpty ? nil : controls,
                                          forDeviceUID: uid)
            if let message = cameraControls.apply(controls, toDeviceUID: uid) {
                postTransientNotice(command: command.label, message: message)
            }
        case .triggerCameraReaction(let uid, let reaction):
            if let message = cameraControls.performReaction(reaction, onDeviceUID: uid) {
                postTransientNotice(command: command.label, message: message)
            }

        // A03 soundboard/playlist execution (issue #98): structural edits
        // write the soundboard document (the controller's store observation
        // hot-applies payload relinks and gains); transport acts on the ONE
        // shared playback instance per pad/playlist, so a UI button and a
        // hardware trigger can never fork playback.
        case .addSoundPad(let pad):
            soundboardStore.addPad(pad)
        case .updateSoundPad(let pad):
            soundboardStore.updatePad(pad)
        case .removeSoundPad(let id):
            soundboardStore.removePad(id)
        case .triggerSoundPad(let id):
            if let pad = soundboardStore.pad(withID: id) {
                soundboard.triggerPad(pad)
            }
        case .stopSoundPad(let id):
            if let pad = soundboardStore.pad(withID: id) {
                soundboard.stopPad(pad)
            }
        case .stopAllSoundEffects:
            soundboard.stopAllSoundEffects()
        case .addMusicPlaylist(let playlist):
            soundboardStore.addPlaylist(playlist)
        case .updateMusicPlaylist(let playlist):
            soundboardStore.updatePlaylist(playlist)
        case .removeMusicPlaylist(let id):
            soundboardStore.removePlaylist(id)
        case .playlistPlay(let id):
            if let playlist = soundboardStore.playlist(withID: id) {
                soundboard.playPlaylist(playlist)
            }
        case .playlistPause(let id):
            if let playlist = soundboardStore.playlist(withID: id) {
                soundboard.pausePlaylist(playlist)
            }
        case .playlistStop(let id):
            if let playlist = soundboardStore.playlist(withID: id) {
                soundboard.stopPlaylist(playlist)
            }
        case .playlistNext(let id):
            if let playlist = soundboardStore.playlist(withID: id) {
                soundboard.nextTrack(playlist)
            }
        case .playlistPrevious(let id):
            if let playlist = soundboardStore.playlist(withID: id) {
                soundboard.previousTrack(playlist)
            }
        case .setSceneSoundBindings(let bindings, let sceneID):
            // Scene content: stages (and implicitly takes in direct-live)
            // like any other scene edit; the Take path fires the rules.
            editStagedScene(sceneID) { $0.soundBindings = bindings }
        // S08 (issue #99): scene content — staged (and implicitly taken in
        // direct-live) like any other scene edit; the Take path applies
        // the snapshot/behavior as the scene enters program.
        case .setSceneAudioSnapshot(let snapshot, let sceneID):
            editStagedScene(sceneID) { $0.audioSnapshot = snapshot }
        case .captureSceneAudioSnapshot(let sceneID):
            let snapshot = currentAudioSnapshot()
            editStagedScene(sceneID) { $0.audioSnapshot = snapshot }
        case .setSceneMediaBehavior(let behavior, let sceneID):
            editStagedScene(sceneID) { $0.mediaBehavior = behavior }

        // E06 PTZ execution (issue #165): the controller turns commands into
        // VISCA frames (fire-and-forget); configuration writes go through
        // the PTZ document (single truth). A removed target is stopped and
        // disconnected before its record disappears.
        case .ptzAddTarget(let target):
            ptzStore.addTarget(target)
        case .ptzUpdateTarget(let target):
            ptzStore.updateTarget(target)
        case .ptzRemoveTarget(let id):
            ptz.disconnectTarget(id)
            ptzStore.removeTarget(id)
        case .ptzMove(let id, let direction, let panSpeed, let tiltSpeed):
            ptz.move(id, direction: direction, panSpeed: panSpeed, tiltSpeed: tiltSpeed)
        case .ptzZoom(let id, let direction, let speed):
            ptz.zoom(id, direction: direction, speed: speed)
        case .ptzStop(let id):
            ptz.stop(id)
        case .ptzStopAll:
            ptz.endInteractiveControl()
        case .ptzStorePreset(let id, let number, let name):
            ptz.storePreset(id, number: number,
                            name: name ?? "Preset \(number)")
        case .ptzRecallPreset(let id, let number):
            ptz.recallPreset(id, number: number)
        case .ptzRemovePreset(let id, let number):
            ptz.removePreset(id, number: number)
        case .ptzSetSceneRecall(let link):
            ptzStore.setRecallLink(link)
        case .ptzRemoveSceneRecall(let id):
            ptzStore.removeRecallLink(id)

        case .setRundown(let document): rundown.update(document)
        case .rundownPlay: rundown.play()
        case .rundownPause: rundown.pause()
        case .rundownStop: rundown.stop()
        case .rundownSkip: rundown.skip()
        case .runRundownCue(let id):
            guard let entry = rundown.document.entries.first(where: { $0.id == id }),
                  let scene = sceneStore.scenes.first(where: { $0.id.rawValue == entry.cue.sceneID }) else { return }
            sceneStore.selectedID = scene.id
            previewProgram.stage(scene)
            publishStaged(transitionOverride: entry.transition, automated: true)
        case .openSettings(let section): session.showSettings(section: section)
        case .closeSettings: session.isPresented = false
        case .applySettings: session.apply()
        case .revertSettings: session.revert()

        case .take:
            publishStaged()
        case .revert:
            previewProgram.revert()
        case .setDirectLiveEditing(let on):
            previewProgram.setDirectLiveEditing(on)
        case .undo:
            if let snapshot = undoStack.undo() {
                applyUndoSnapshot(snapshot)
            }
        case .redo:
            if let snapshot = undoStack.redo() {
                applyUndoSnapshot(snapshot)
            }
        }
    }

    // MARK: Undo/redo (S12, issue #75)

    /// The undoable state right now: the store's document + browser state and
    /// the staged scene. The program snapshot is deliberately EXCLUDED —
    /// undo must never rewrite what the outputs are emitting.
    private func captureUndoSnapshot() -> SceneUndoSnapshot {
        sceneStore.captureUndoSnapshot(stagedScene: previewProgram.stagedScene)
    }

    /// Restores a snapshot popped from the undo/redo stack. Program-safety
    /// semantics: the restored state lands on the STAGED model and the store;
    /// the program snapshot is untouched, so if it differs from the restored
    /// staged scene (e.g. undoing an edit that was already Taken) the
    /// difference simply reads as pending staged edits — Take publishes the
    /// restored state, Revert discards it. In direct-live mode the restore
    /// takes immediately (the mode's contract is preview == program).
    private func applyUndoSnapshot(_ snapshot: SceneUndoSnapshot) {
        sceneStore.restoreUndoSnapshot(snapshot)
        if let staged = snapshot.stagedScene,
           sceneStore.scenes.contains(where: { $0.id == staged.id }) {
            previewProgram.stage(staged)
        } else {
            previewProgram.stage(sceneStore.selected)
        }
        // A restored NAME-only difference (rename persists immediately and
        // syncs both snapshots) must not read as a pending visual edit —
        // same rule as `noteSceneRenamed` on the rename command itself.
        if let programID = previewProgram.programScene?.id,
           let restored = sceneStore.scene(withID: programID) {
            previewProgram.noteSceneRenamed(programID, to: restored.name)
        }
        // Prune the ephemeral layer selection to layers that exist again.
        sceneStore.selectedLayerIDs = sceneStore.selectedLayerIDs.intersection(
            Set(previewProgram.stagedScene?.layers.map(\.id) ?? []))
        takeStagedIfDirectLive()
    }

    /// Direct-live mode (W03): every edit/selection is an implicit take, so
    /// preview and program move together and each change persists (the
    /// explicit mode's save point is the edit itself).
    private func takeStagedIfDirectLive() {
        guard previewProgram.directLiveEditing else { return }
        publishStaged()
    }

    /// Every manual/automated Take shares the same sound, audio, media and
    /// PTZ hooks. A cue override never changes the persisted scene setting.
    private func publishStaged(transitionOverride: SceneTransition? = nil, automated: Bool = false) {
        if !automated { rundown.manualOverride() }
        let outgoingProgram = previewProgram.programScene
        guard let published = previewProgram.take() else { return }
        sceneStore.update(published)
        soundboard.syncProgramScene(published)
        restoreSceneAudioSnapshot(entering: published, previousProgramID: outgoingProgram?.id)
        applyProgramMediaBehavior(entering: published, leaving: outgoingProgram)
        if published.id != outgoingProgram?.id {
            transitions.handleTake(targetSceneID: published.id,
                transition: transitionOverride ?? published.transition ?? sceneStore.defaultTransition)
            ptz.recallLinkedPresets(forSceneID: published.id.rawValue)
        }
    }

    // MARK: Scene audio snapshots & media behavior (S08, issue #99)

    /// The mixer state `.captureSceneAudioSnapshot` records: the default
    /// mic's fader/mute plus every registered NON-capture channel's
    /// fader/mute, keyed by the A04 mixer-document label. Capture channels
    /// are excluded by design — their program levels are the scene's
    /// per-layer S05 `AudioBinding`s, already scene content.
    private func currentAudioSnapshot() -> SceneAudioSnapshot {
        let mixer = session.activeSettings.mixer
        let micID = AudioChannelID.microphone(deviceUID: nil)
        var gains: [String: SceneAudioChannelState] = [
            micID.label: SceneAudioChannelState(
                volume: max(0, min(session.activeSettings.micVolume, 2)),
                isMuted: mixer.channelMutes[micID.label] ?? false)
        ]
        for (label, id) in channelIDsByLabel where id != micID {
            if case .capture = id { continue }
            gains[label] = SceneAudioChannelState(
                volume: max(0, min(mixer.channelVolumes[label] ?? 1, 2)),
                isMuted: mixer.channelMutes[label] ?? false)
        }
        return SceneAudioSnapshot(channelGains: gains)
    }

    /// S08 (issue #99): the taken scene's opt-in audio snapshot becomes the
    /// live mix. The restore is written back through the mixer document
    /// (single truth), so the mixer UI reflects it and the A04 push applies
    /// it as ONE ramped `setChannelGain` pass — the A01 engine's gain ramps
    /// keep the transition click-free. Only channels the snapshot names are
    /// touched: the mixer state of every other channel survives the scene
    /// change (restoring never touches channels the scene doesn't own).
    /// Fires only when a DIFFERENT scene becomes program — re-taking the
    /// same scene (a direct-live edit) leaves the mix alone.
    private func restoreSceneAudioSnapshot(entering: Scene, previousProgramID: SceneID?) {
        guard entering.id != previousProgramID,
              let snapshot = entering.audioSnapshot else { return }
        var mixer = session.activeSettings.mixer
        var micVolume = session.activeSettings.micVolume
        let micLabel = AudioChannelID.microphone(deviceUID: nil).label
        for (label, state) in snapshot.channelGains {
            let volume = max(0, min(state.volume, 2))
            if label == micLabel {
                micVolume = volume
            } else {
                mixer.channelVolumes[label] = volume
            }
            // A04 stores a mute as presence in the dict; unmuted removes it.
            mixer.channelMutes[label] = state.isMuted ? true : nil
        }
        // One write of each surface → one state refresh → one ramped engine
        // pass (the A01 snapshot-apply rule).
        session.persistMixer(mixer)
        session.persistMicVolume(micVolume)
    }

    /// S08 (issue #99): applies the media entry/exit policies of a program
    /// change. The OUTGOING scene's exit policy governs only the sources
    /// the entering scene does not share — a Take between scenes sharing a
    /// source never pauses/stops/restarts it; the entering scene's entry
    /// policy then governs every source it owns, and `restartFromStart`
    /// deliberately restarts even a shared source (the documented
    /// play-from-start exception). Previewing never reaches here: this
    /// hook rides the Take paths only, and a same-scene re-take returns
    /// before touching anything.
    private func applyProgramMediaBehavior(entering: Scene, leaving: Scene?) {
        guard entering.id != leaving?.id else { return }
        let registry = SceneGraph.index(sceneStore.scenes)
        let enteringIDs = mediaSourceIDs(in: entering, registry: registry)
        let leavingIDs = leaving.map { mediaSourceIDs(in: $0, registry: registry) } ?? []
        if let leaving {
            for id in leavingIDs where !enteringIDs.contains(id) {
                switch leaving.mediaBehavior.exit {
                case .keepPlaying:
                    // No scene-level intervention — the A02 demand model
                    // still parks a source nothing references anymore.
                    break
                case .pause:
                    controller.capturePool.pauseMedia(id)
                case .stop:
                    controller.capturePool.stopMedia(id)
                }
            }
        }
        switch entering.mediaBehavior.entry {
        case .continue:
            break
        case .resume:
            for id in enteringIDs {
                let phase = controller.capturePool.mediaStatus(for: id).phase
                guard phase != .playing, phase != .loading else { continue }
                controller.capturePool.playMedia(id)
            }
        case .restartFromStart:
            for id in enteringIDs {
                controller.capturePool.restartMedia(id)
            }
        }
    }

    /// The registry media sources a scene's visible layers reference
    /// (S06-flattened, so media inside nested scenes counts too).
    private func mediaSourceIDs(in scene: Scene, registry: [SceneID: Scene]) -> Set<SourceDefinitionID> {
        Set(SceneGraph.flattenedVisibleLayers(of: scene, in: registry).compactMap { layer in
            guard let id = layer.sourceID,
                  sceneStore.source(withID: id)?.payload.isMedia == true else { return nil }
            return id
        })
    }

    // MARK: Layer helpers

    /// G11 (issue #117): the scene an annotation command targets — `nil`
    /// means the STAGED scene (the canvas being drawn on); an explicit ID
    /// must name an existing scene. Unlike `resolveStagedScene`, an explicit
    /// ID need not be staged: annotations are document content keyed by
    /// scene, not staged scene state.
    private func resolveAnnotationScene(_ sceneID: SceneID?) -> Result<SceneID, StudioCommandError> {
        guard let sceneID else {
            guard let staged = previewProgram.stagedScene else {
                return .failure(.invalidTarget("No scene is staged in preview."))
            }
            return .success(staged.id)
        }
        guard let scene = sceneStore.scenes.first(where: { $0.id == sceneID }) else {
            return .failure(.invalidTarget("Scene \(sceneID) does not exist."))
        }
        return .success(scene.id)
    }

    /// W03: layer edits only ever mutate the STAGED scene. `in: nil` targets
    /// it directly; an explicit scene ID must name the staged scene — editing
    /// a background scene is rejected rather than silently bypassing the
    /// preview/program split.
    private func resolveStagedScene(_ sceneID: SceneID?) -> Result<Scene, StudioCommandError> {
        guard let scene = previewProgram.stagedScene else {
            return .failure(.invalidTarget("No scene is staged in preview."))
        }
        if let sceneID, scene.id != sceneID {
            let name = sceneStore.scenes.first(where: { $0.id == sceneID })?.name
            return .failure(.invalidTarget(name.map { "Scene \"\($0)\" is not staged in preview — select it first." }
                                           ?? "Scene \(sceneID) does not exist."))
        }
        return .success(scene)
    }

    private func resolveLayer(_ layerID: LayerID,
                              in sceneID: SceneID?) -> Result<(Scene, Int), StudioCommandError> {
        switch resolveStagedScene(sceneID) {
        case .failure(let error): return .failure(error)
        case .success(let scene):
            guard let index = scene.layers.firstIndex(where: { $0.id == layerID }) else {
                return .failure(.invalidTarget("Layer \(layerID) does not exist in scene \"\(scene.name)\"."))
            }
            return .success((scene, index))
        }
    }

    private func resolveDynamicOverlay(_ id: LayerID, in sceneID: SceneID?)
        -> Result<UUID, StudioCommandError> {
        let scene: Scene?
        if sceneID == nil || sceneID == previewProgram.stagedScene?.id {
            scene = previewProgram.stagedScene
        } else if sceneID == previewProgram.programScene?.id {
            scene = previewProgram.programScene
        } else {
            scene = sceneStore.scenes.first { $0.id == sceneID }
        }
        guard let layer = scene?.layers.first(where: { $0.id == id }),
              case .text(let text) = layer.payload else {
            return .failure(.invalidTarget("Select a timer or ticker text layer."))
        }
        if let timer = text.timer, timer.kind.usesTransport { return .success(timer.runtimeID) }
        if let ticker = text.ticker { return .success(ticker.runtimeID) }
        return .failure(.invalidTarget("This text layer has no elapsed timer or ticker transport."))
    }

    private func resolveGroup(_ groupID: GroupID,
                              in sceneID: SceneID?) -> Result<(Scene, LayerGroup), StudioCommandError> {
        switch resolveStagedScene(sceneID) {
        case .failure(let error): return .failure(error)
        case .success(let scene):
            guard let group = scene.group(withID: groupID) else {
                return .failure(.invalidTarget("Group \(groupID) does not exist in scene \"\(scene.name)\"."))
            }
            return .success((scene, group))
        }
    }

    /// S06 (issue #96): the rejection for a nested-scene reference from
    /// `container` to `target` — the target must exist, the edge must not
    /// close a reference loop, and the resulting chain must stay within the
    /// nesting-depth cap. The errors read as plain-language reasons in the
    /// diagnostics strip. `index` is the document graph to validate against
    /// (callers pass a substituted index for whole-scene replacements).
    private func nestedReferenceError(referencing target: SceneID,
                                      into container: Scene,
                                      in index: [SceneID: Scene],
                                      layerName: String? = nil) -> StudioCommandError? {
        let subject = layerName.map { "Layer \"\($0)\" references a scene that" }
            ?? "The referenced scene"
        guard let targetScene = index[target] else {
            return .invalidTarget("\(subject) does not exist.")
        }
        if SceneGraph.wouldCreateCycle(container: container.id, referencing: target, in: index) {
            return .invalidValue("Nesting \"\(targetScene.name)\" inside \"\(container.name)\" would create a circular scene reference.")
        }
        let depth = SceneGraph.ancestorDepth(of: container.id, in: index)
            + SceneGraph.subtreeDepth(of: target, in: index)
        guard depth <= SceneGraph.maxNestingDepth else {
            return .invalidValue("Nesting \"\(targetScene.name)\" inside \"\(container.name)\" would exceed the nesting depth limit of \(SceneGraph.maxNestingDepth) scenes.")
        }
        return nil
    }

    /// S03: the rejection for editing an effectively-locked layer (its own
    /// lock, or its group's). Nil when the layer is editable.
    private func lockError(for layer: LayerNode, in scene: Scene) -> StudioCommandError? {
        if layer.isLocked {
            return .unavailable("Layer \"\(layer.name)\" is locked — unlock it to edit.")
        }
        if let group = scene.group(for: layer), group.isLocked {
            return .unavailable("Layer \"\(layer.name)\" belongs to locked group \"\(group.name)\" — unlock the group first.")
        }
        return nil
    }

    /// A02 (issue #97): the rejection for a media transport command — the
    /// target must be a REGISTERED media source (transport is keyed by
    /// registry source ID, the same identity playout and the mix engine use).
    private func mediaTransportError(for id: SourceDefinitionID) -> StudioCommandError? {
        guard let source = sceneStore.source(withID: id) else {
            return .invalidTarget("Media source \(id) does not exist.")
        }
        guard source.payload.isMedia else {
            return .invalidTarget("Source \"\(source.name)\" is not a media source.")
        }
        return nil
    }

    /// G06 (issue #113): the rejection for a page-navigation command — the
    /// target must be a REGISTERED PDF source (navigation is keyed by registry
    /// source ID, the same identity page rendering uses).
    private func pdfNavigationError(for id: SourceDefinitionID) -> StudioCommandError? {
        guard let source = sceneStore.source(withID: id) else {
            return .invalidTarget("Presentation source \(id) does not exist.")
        }
        guard case .pdf = source.payload else {
            return .invalidTarget("Source \"\(source.name)\" is not a presentation source.")
        }
        return nil
    }

    /// The payload's persisted default page — the seed for deck state before
    /// the source has ever been navigated.
    private func pdfDefaultPage(for id: SourceDefinitionID) -> Int {
        guard case .pdf(let payload) = sceneStore.source(withID: id)?.payload else { return 0 }
        return payload.page
    }

    /// G06 (issue #113): the PDF source the keyboard / Present-menu navigation
    /// targets — the SELECTED layer's bound PDF source first, else the first
    /// visible PDF source in the staged scene (S06-flattened, so a deck nested
    /// in a referenced scene counts), so hotkeys act on what the presenter is
    /// looking at. Nil when no PDF source is in play (controls disable).
    func presentationNavigationTarget() -> SourceDefinitionID? {
        guard let staged = previewProgram.stagedScene else { return nil }
        let registry = SceneGraph.index(sceneStore.scenes)
        let layers = SceneGraph.flattenedVisibleLayers(of: staged, in: registry)
        func pdfSourceID(of layer: LayerNode) -> SourceDefinitionID? {
            guard let id = layer.sourceID,
                  let source = sceneStore.source(withID: id),
                  case .pdf = source.payload else { return nil }
            return id
        }
        for layer in layers where sceneStore.selectedLayerIDs.contains(layer.id) {
            if let id = pdfSourceID(of: layer) { return id }
        }
        return layers.lazy.compactMap(pdfSourceID(of:)).first
    }

    /// E06 (issue #165): the rejection for a PTZ target configuration —
    /// the identity rules (add = new ID, update = existing ID) plus usable
    /// name/host/port/address values.
    private func ptzTargetError(for target: PTZTarget, requireNew: Bool) -> StudioCommandError? {
        let exists = ptzStore.target(withID: target.id) != nil
        if requireNew, exists {
            return .invalidValue("PTZ camera \(target.id) is already configured.")
        }
        if !requireNew, !exists {
            return .invalidTarget("PTZ camera \(target.id) is not configured.")
        }
        if target.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .invalidValue("A PTZ camera name can't be empty.")
        }
        if target.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .invalidValue("A PTZ camera needs a host (IP or hostname).")
        }
        if target.port == 0 {
            return .invalidValue("A PTZ camera needs a port (VISCA default \(target.kind.defaultPort)).")
        }
        return (1...7).contains(target.cameraAddress)
            ? nil : .invalidValue("The VISCA address must be 1…7.")
    }

    // MARK: Canvas alignment helpers (S04)

    /// The layers align/distribute act on: the selection (shared with the S03
    /// panel and S04 canvas) intersected with the staged scene, minus
    /// effectively-locked layers — the same editable set canvas drags move.
    private func alignmentTargets(in scene: Scene) -> [LayerNode] {
        scene.layers.filter {
            sceneStore.selectedLayerIDs.contains($0.id) && !scene.isEffectivelyLocked($0)
        }
    }

    /// The transform's UNROTATED frame on the unit canvas (normalized 0…1,
    /// top-left origin) — the geometry alignment works in, independent of the
    /// output resolution.
    private func unitRect(_ transform: LayerTransform) -> CGRect {
        let anchor = anchorFraction(transform.anchor)
        return CGRect(x: transform.position.x - anchor.x * transform.size.width,
                      y: transform.position.y - anchor.y * transform.size.height,
                      width: transform.size.width,
                      height: transform.size.height)
    }

    private func anchorFraction(_ anchor: LayerAnchor) -> CGPoint {
        switch anchor {
        case .topLeft: return CGPoint(x: 0, y: 0)
        case .topRight: return CGPoint(x: 1, y: 0)
        case .bottomLeft: return CGPoint(x: 0, y: 1)
        case .bottomRight: return CGPoint(x: 1, y: 1)
        case .center: return CGPoint(x: 0.5, y: 0.5)
        }
    }

    /// S04: aligns the selected, editable layers' unrotated frames to the
    /// selection's union bounds along one edge/center. Positions shift so the
    /// layer's ANCHOR point lands where the aligned frame edge requires.
    private func alignSelectedLayers(_ alignment: LayerAlignment, in sceneID: SceneID?) {
        editStagedScene(sceneID) { scene in
            let targets = scene.layers.indices.filter {
                sceneStore.selectedLayerIDs.contains(scene.layers[$0].id)
                    && !scene.isEffectivelyLocked(scene.layers[$0])
            }
            guard targets.count >= 2 else { return }
            let rects = targets.map { unitRect(scene.layers[$0].transform) }
            let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
            for (offset, index) in targets.enumerated() {
                var transform = scene.layers[index].transform
                let anchor = anchorFraction(transform.anchor)
                let rect = rects[offset]
                switch alignment {
                case .left:
                    transform.position.x = union.minX + anchor.x * rect.width
                case .horizontalCenter:
                    transform.position.x = union.midX + (anchor.x - 0.5) * rect.width
                case .right:
                    transform.position.x = union.maxX + (anchor.x - 1) * rect.width
                case .top:
                    transform.position.y = union.minY + anchor.y * rect.height
                case .verticalCenter:
                    transform.position.y = union.midY + (anchor.y - 0.5) * rect.height
                case .bottom:
                    transform.position.y = union.maxY + (anchor.y - 1) * rect.height
                }
                scene.layers[index].transform = transform
            }
        }
    }

    /// S04: evenly spaces the selected, editable layers' centers between the
    /// outermost two along one axis (the outer layers stay put).
    private func distributeSelectedLayers(_ distribution: LayerDistribution, in sceneID: SceneID?) {
        editStagedScene(sceneID) { scene in
            var pairs = scene.layers.indices.compactMap { index -> (index: Int, rect: CGRect)? in
                let layer = scene.layers[index]
                guard sceneStore.selectedLayerIDs.contains(layer.id),
                      !scene.isEffectivelyLocked(layer) else { return nil }
                return (index, unitRect(layer.transform))
            }
            guard pairs.count >= 3 else { return }
            switch distribution {
            case .horizontal:
                pairs.sort { $0.rect.midX < $1.rect.midX }
                guard let outermost = pairs.first, let lastOutermost = pairs.last else { return }
                let start = outermost.rect.midX
                let end = lastOutermost.rect.midX
                let step = (end - start) / Double(pairs.count - 1)
                for (position, pair) in pairs.enumerated() {
                    var transform = scene.layers[pair.index].transform
                    let anchor = anchorFraction(transform.anchor)
                    transform.position.x = start + step * Double(position)
                        + (anchor.x - 0.5) * pair.rect.width
                    scene.layers[pair.index].transform = transform
                }
            case .vertical:
                pairs.sort { $0.rect.midY < $1.rect.midY }
                guard let outermost = pairs.first, let lastOutermost = pairs.last else { return }
                let start = outermost.rect.midY
                let end = lastOutermost.rect.midY
                let step = (end - start) / Double(pairs.count - 1)
                for (position, pair) in pairs.enumerated() {
                    var transform = scene.layers[pair.index].transform
                    let anchor = anchorFraction(transform.anchor)
                    transform.position.y = start + step * Double(position)
                        + (anchor.y - 0.5) * pair.rect.height
                    scene.layers[pair.index].transform = transform
                }
            }
        }
    }

    /// S02: the rejection for touching a locked scene (rename/delete/move).
    /// Nil when the scene is unlocked.
    private func sceneLockError(for id: SceneID, action: String) -> StudioCommandError? {        guard sceneStore.isLocked(id) else { return nil }
        let name = sceneStore.scenes.first(where: { $0.id == id })?.name ?? "\(id)"
        return .unavailable("Scene \"\(name)\" is locked — unlock it to \(action) it.")
    }

    /// S02: the rejection for a command that would edit a locked scene's
    /// CONTENT — a whole-scene replacement or any layer/group edit addressed
    /// to it (explicitly, or implicitly via the staged scene). Nil for
    /// non-content commands and unlocked scenes.
    private func sceneContentLockError(for command: StudioCommand) -> StudioCommandError? {
        let sceneID: SceneID?
        switch command {
        case .updateScene(let scene):
            sceneID = scene.id
        case .setLayerVisibility(_, _, let id),
             .setLayerTransform(_, _, let id),
             .setLayerEffects(_, _, let id),
             .setLayerAudio(_, _, let id),
             .addLayer(_, let id),
             .removeLayer(_, let id),
             .duplicateLayer(_, let id),
             .renameLayer(_, _, let id),
             .setLayerLocked(_, _, let id),
             .moveLayer(_, _, _, let id),
             .groupLayers(_, _, let id),
             .ungroupLayers(_, let id),
             .renameGroup(_, _, let id),
             .setGroupVisibility(_, _, let id),
             .setGroupLocked(_, _, let id),
             .alignLayers(_, let id),
             .distributeLayers(_, let id),
             .setOverlayHiddenInScene(_, _, let id),
             .setSceneBackground(_, let id),
             .setSceneTransition(_, let id),
             .setSceneSoundBindings(_, let id),
             .setSceneAudioSnapshot(_, let id),
             .captureSceneAudioSnapshot(let id),
             .setSceneMediaBehavior(_, let id),
             .setLayerSourceEffects(_, _, let id),
             .setLayerStyle(_, _, let id),
             .setLayerText(_, _, let id),
             .setLayerMotionIdentity(_, _, let id),
             .setLayerImage(_, _, let id):
            sceneID = id ?? previewProgram.stagedScene?.id
        default:
            return nil
        }
        guard let sceneID else { return nil }
        return sceneLockError(for: sceneID, action: "edit")
    }

    /// Builds a new front-of-stack layer for `.addLayer`, binding the
    /// matching project-level source when one is registered. A second camera
    /// lands as a PIP instead of covering the existing fullscreen camera.
    private func makeLayer(payload: LayerPayload, in scene: Scene) -> LayerNode {
        let cameraSourceID = sceneStore.sources.first(where: { $0.payload.isCamera })?.id
        let screenSourceID = sceneStore.sources.first(where: { $0.payload.isScreen })?.id
        switch payload {
        case .camera:
            if scene.layers.contains(where: { $0.payload.isCamera }) {
                return .cameraPIP(corner: .bottomRight, scale: 0.28, sourceID: cameraSourceID)
            }
            return .fullscreenCamera(sourceID: cameraSourceID)
        case .screen:
            return .fullscreenScreen(sourceID: screenSourceID)
        case .text:
            // S07: a lower-third text bug, centered near the bottom edge.
            return LayerNode(name: payload.displayName, payload: payload,
                             transform: LayerTransform(
                                position: GraphPoint(x: 0.5, y: 0.88),
                                size: GraphSize(width: 0.6, height: 0.09),
                                anchor: .center))
        case .shape:
            // S07: a small solid block in the top-right corner (a fullscreen
            // shape would obscure the whole scene).
            return LayerNode(name: payload.displayName, payload: payload,
                             transform: LayerTransform(
                                position: GraphPoint(x: 0.98, y: 0.02),
                                size: GraphSize(width: 0.12, height: 0.07),
                                anchor: .topRight))
        case .image(let image):
            // G01 (issue #81): a logo-style bug anchored bottom-right. The
            // renderer aspect-fits, so the height is nominal until the image
            // decodes; the user repositions/resizes on canvas like any layer.
            return LayerNode(name: image.fileName.map {
                                 ($0 as NSString).deletingPathExtension
                             } ?? payload.displayName,
                             payload: payload,
                             transform: LayerTransform(
                                position: GraphPoint(x: 0.98, y: 0.98),
                                size: GraphSize(width: 0.2, height: 0.2),
                                anchor: .bottomRight))
        case .scene(let reference):
            // S06: nest the referenced scene at full canvas (the classic
            // "branded base layout" reuse); the user repositions/resizes it
            // on canvas like any other layer.
            let name = sceneStore.scene(withID: reference.sceneID)?.name ?? payload.displayName
            return LayerNode(name: name, payload: payload, transform: .fullscreen)
        default:
            // Validation rejects non-renderable kinds before execution.
            return LayerNode(name: payload.displayName, payload: payload, transform: .fullscreen)
        }
    }

    // MARK: Overlay helpers (S07)

    /// Resolves an overlay ID against the SceneStore's PROJECT overlay list
    /// (overlay commands are never staged-scene-bound).
    private func resolveOverlay(_ overlayID: LayerID) -> Result<LayerNode, StudioCommandError> {
        guard let overlay = sceneStore.overlays.first(where: { $0.id == overlayID }) else {
            return .failure(.invalidTarget("Overlay \(overlayID) does not exist."))
        }
        return .success(overlay)
    }

    /// S07: the rejection for editing a locked overlay. Overlays have no
    /// groups, so the own-lock is the whole story. Nil when editable.
    private func overlayLockError(for overlay: LayerNode) -> StudioCommandError? {
        overlay.isLocked
            ? .unavailable("Overlay \"\(overlay.name)\" is locked — unlock it to edit.")
            : nil
    }

    /// Applies one edit to an overlay in place; the SceneStore write persists
    /// and republishes the project overlay context to every engine.
    private func editOverlay(_ overlayID: LayerID, _ edit: (inout LayerNode) -> Void) {
        guard case .success(var overlay) = resolveOverlay(overlayID) else { return }
        edit(&overlay)
        sceneStore.updateOverlay(overlay)
    }

    /// Builds a new front-of-stack project overlay for `.addOverlay`
    /// (validation restricts payloads to text/shape): branding-style
    /// placements that never obscure the whole canvas.
    private func makeOverlay(payload: LayerPayload) -> LayerNode {
        switch payload {
        case .text:
            // Lower-third bug: centered near the bottom edge.
            return LayerNode(name: "Text Overlay", payload: payload,
                             transform: LayerTransform(
                                position: GraphPoint(x: 0.5, y: 0.94),
                                size: GraphSize(width: 0.5, height: 0.07),
                                anchor: .center))
        case .image(let image):
            // G01 (issue #81): a corner branding bug — small, top-right,
            // aspect-fit (the height is nominal until the image decodes).
            return LayerNode(name: image.fileName.map {
                                 ($0 as NSString).deletingPathExtension
                             } ?? "Image Overlay",
                             payload: payload,
                             transform: LayerTransform(
                                position: GraphPoint(x: 0.98, y: 0.02),
                                size: GraphSize(width: 0.12, height: 0.08),
                                anchor: .topRight))
        default:
            // Shape: a small solid block in the top-right corner.
            return LayerNode(name: "\(payload.displayName) Overlay", payload: payload,
                             transform: LayerTransform(
                                position: GraphPoint(x: 0.98, y: 0.02),
                                size: GraphSize(width: 0.10, height: 0.06),
                                anchor: .topRight))
        }
    }

    /// G09 (issue #116): a media overlay (animated image / alpha video)
    /// starts centered at 40% of the canvas — sticker/lower-third assets
    /// drag to size on the canvas like any overlay. The inline payload
    /// mirrors the registry source's (self-contained document rule), and
    /// `sourceID` is what keys playout demand and frame pulls.
    private func makeMediaOverlay(name: String, sourceID: SourceDefinitionID,
                                  payload: MediaSourcePayload) -> LayerNode {
        LayerNode(name: name, sourceID: sourceID, payload: .media(payload),
                  transform: LayerTransform(
                    position: GraphPoint(x: 0.5, y: 0.5),
                    size: GraphSize(width: 0.4, height: 0.4),
                    anchor: .center))
    }

    private func editLayer(_ layerID: LayerID,
                           in sceneID: SceneID?,
                           _ edit: (inout LayerNode) -> Void) {
        guard case .success(let (resolved, index)) = resolveLayer(layerID, in: sceneID) else { return }
        var scene = resolved
        edit(&scene.layers[index])
        previewProgram.applyStagedEdit(scene)
        takeStagedIfDirectLive()
    }

    /// Applies one structural edit (reorder/group/lock/add/remove) to the
    /// staged scene, with the same implicit-take behavior as value edits.
    private func editStagedScene(_ sceneID: SceneID?,
                                 _ edit: (inout Scene) -> Void) {
        guard case .success(var scene) = resolveStagedScene(sceneID) else { return }
        edit(&scene)
        previewProgram.applyStagedEdit(scene)
        takeStagedIfDirectLive()
    }

    // MARK: State snapshot

    private func refreshState() {
        let staged = previewProgram.stagedScene
        let effects = sceneStore.sources.compactMap(\.effectDefaults)
            + sceneStore.effectPresets.map(\.effects)
            + (sceneStore.scenes.flatMap(\.layers) + sceneStore.overlays
               + (staged?.layers ?? []) + (previewProgram.programScene?.layers ?? [])).compactMap(\.effectOverrides)
        let lutIDs = Set(effects.compactMap { $0.lut.assetID })
        let usedSites = Set(lutIDs.map { "lut/\($0)" })
        for site in assetLibrary.usage.keys where site.hasPrefix("lut/") && !usedSites.contains(site) {
            assetLibrary.clearUsage(site: site)
        }
        for id in lutIDs {
            let site = "lut/\(id)"
            if assetLibrary.usage[site]?.contains(id) != true { assetLibrary.noteUsage(of: id, from: site) }
        }
        lutLibrary.sync(ids: lutIDs, library: assetLibrary)
        state = StudioState(
            stream: controller.streamState,
            preview: controller.previewState,
            recording: recorder.state,
            activeProfile: controller.activeProfile,
            stagedProfile: controller.stagedProfile,
            scenes: sceneStore.scenes.map { StudioState.SceneRef(id: $0.id, name: $0.name) },
            selectedSceneID: sceneStore.selectedID,
            stagedSceneID: staged?.id,
            programSceneID: previewProgram.programScene?.id,
            hasPendingStagedEdits: previewProgram.hasPendingEdits,
            lockedSceneIDs: sceneStore.lockedSceneIDs,
            directLiveEditing: previewProgram.directLiveEditing,
            layerVisibility: Dictionary(
                uniqueKeysWithValues: (staged?.layers ?? []).map { ($0.id, $0.isVisible) }),
            layerLocks: Dictionary(
                uniqueKeysWithValues: (staged?.layers ?? []).map {
                    ($0.id, staged?.isEffectivelyLocked($0) ?? false)
                }),
            settingsPresented: session.isPresented,
            settingsDirty: session.isDirty,
            mixer: session.activeSettings.mixer,
            micVolume: session.activeSettings.micVolume,
            channelFX: session.activeSettings.channelFX,
            voicePolishEnabled: session.activeSettings.voicePolishEnabled,
            monitoringEnabled: session.activeSettings.monitoringEnabled,
            monitorOutputDeviceUID: session.activeSettings.monitorOutputDeviceUID,
            monitorOutputFallback: controller.monitorOutput.isFallbackActive,
            monitorFeedbackRiskDeviceUID: controller.monitorFeedbackRiskDeviceUID,
            audioDelaysMs: session.activeSettings.audioDelaysMs,
            videoDelaysMs: session.activeSettings.videoDelaysMs,
            ducking: session.activeSettings.ducking,
            echoHandlingMode: session.activeSettings.echoHandlingMode,
            voiceIsolationActive: controller.voiceIsolationActive,
            feedbackDiagnostics: controller.feedbackDiagnostics,
            canUndo: undoStack.canUndo,
            canRedo: undoStack.canRedo,
            undoLabel: undoStack.undoLabel,
            redoLabel: undoStack.redoLabel,
            annotations: annotations.uiState(stagedSceneID: staged?.id))
        registerAppAudioMixerChannels()
        pushMixerStateToEngine()
    }

    /// A06 (issue #118): app-audio sources are mixer-owned, never scene-bound
    /// — no S05 `AudioBinding` addresses an `.application` channel, so the
    /// mixer document (fader/mute, default unity) is their ONLY program-gain
    /// surface. Their channel IDs register here, from the registry on every
    /// store change, so `pushMixerStateToEngine` applies the persisted gain
    /// even before the first audio buffer lands (the engine's pending gains
    /// hold it until the channel auto-registers on enqueue).
    private func registerAppAudioMixerChannels() {
        for source in sceneStore.sources {
            guard case .appAudio(let payload) = source.payload, payload.isEnabled
            else { continue }
            let id = AudioChannelID.application(bundleID: payload.channelBundleID)
            channelIDsByLabel[id.label] = id
        }
    }

    // MARK: Mixer engine push (A04, issue #83)

    /// Applies the persisted mixer state to the audio engine through the
    /// controller — idempotently, only when it changed. Runs from
    /// `refreshState` so it fires after every mixer command AND after any
    /// external settings write (Apply/revert); the controller mirrors the
    /// pushed gains, so pipeline restarts re-apply the full mixer state.
    private func pushMixerStateToEngine() {
        let desired = (mixer: session.activeSettings.mixer,
                       micVolume: session.activeSettings.micVolume)
        if let last = lastPushedMixer, last == desired { return }
        lastPushedMixer = desired
        let mixer = desired.mixer
        // A05 (issue #84): enabled additional mic channels register under
        // their stable labels so their faders/mutes/solos persist in the
        // mixer document and push to the engine like any non-capture
        // channel — even before the device's first buffer lands.
        for selection in session.activeSettings.audioInputs where selection.isEnabled {
            let id = AudioChannelID.microphone(deviceUID: selection.deviceUID)
            channelIDsByLabel[id.label] = id
        }
        // Channels: fader/mute per registered non-capture ID (capture levels
        // are scene bindings). The DEFAULT mic's fader is the settings
        // micVolume; A05 additional mics and other kinds read the mixer
        // document.
        for (label, id) in channelIDsByLabel {
            if case .capture = id { continue }
            let volume: Float
            if id == .microphone(deviceUID: nil) {
                volume = Float(max(0, min(desired.micVolume, 2)))
            } else {
                volume = Float(max(0, min(mixer.channelVolumes[label] ?? 1, 2)))
            }
            controller.applyMixerChannelGain(id, volume: volume,
                                             isMuted: mixer.channelMutes[label] ?? false)
        }
        // Solo (monitor state) and aux sends (routing) apply to EVERY
        // registered channel, capture channels included.
        for (label, id) in channelIDsByLabel {
            controller.applyMixerSolo(id, soloed: mixer.soloedChannels.contains(label))
            controller.applyMixerAuxSend(id, gain: Float(mixer.channelAuxSends[label] ?? 0))
        }
        // Bus masters: a muted bus rides gain 0 while its fader value is
        // preserved in the document.
        for bus in AudioBus.allCases {
            let gain = mixer.mutedBuses.contains(bus.rawValue)
                ? 0 : (mixer.busGains[bus.rawValue] ?? 1)
            controller.applyMixerBusGain(bus, gain: Float(gain))
        }
    }

    // MARK: Rejection surfacing

    private func postRejection(command: StudioCommand, error: StudioCommandError) {
        rejectionSequence += 1
        let sequence = rejectionSequence
        lastRejection = Rejection(sequence: sequence,
                                  command: command.label,
                                  message: error.description)
        rejectionTask?.cancel()
        rejectionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, self.rejectionSequence == sequence else { return }
            self.lastRejection = nil
        }
    }

    /// S09 (issue #100): a transient diagnostics-strip notice that isn't a
    /// command rejection — an asynchronous stinger failure or honest
    /// fallback surfaces here (same auto-clearing presentation).
    private func postTransientNotice(command: String, message: String) {
        rejectionSequence += 1
        let sequence = rejectionSequence
        lastRejection = Rejection(sequence: sequence,
                                  command: command,
                                  message: message)
        rejectionTask?.cancel()
        rejectionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, self.rejectionSequence == sequence else { return }
            self.lastRejection = nil
        }
    }
}

private extension StudioCommand {
    /// True for the one group-state edit a locked group still accepts.
    var isGroupUnlock: Bool {
        if case .setGroupLocked(_, let locked, _) = self { return !locked }
        return false
    }

    /// S12 (issue #75): the commands the undo stack covers — every scene,
    /// layer, group, browser-organization, and overlay/background mutation.
    /// Excluded: output sessions and settings (not scene state), selection
    /// and folder collapse (transient view state), Take/Revert/direct-live
    /// (publish control, not an edit — undoing an already-Taken edit undoes
    /// the ORIGINAL edit and re-stages it), and undo/redo themselves.
    /// E01's source effect defaults and effect presets are excluded too:
    /// the registry and the preset list live outside the undo snapshot (the
    /// mixer-document precedent), unlike layer effect OVERRIDES, which are
    /// staged scene content and undo with it. G03's style presets and G02's
    /// title-style presets follow the same rule; layer/overlay STYLES and
    /// text payloads are content and undo.
    /// G11 (issue #117): annotation commands are excluded — strokes,
    /// visibility, and the program gate live in the annotation document
    /// outside the S12 snapshot (the mixer/soundboard-document precedent).
    /// Strokes are ephemeral live-presentation marks with their own
    /// stroke-level history (`.undoAnnotationStroke`); the per-scene
    /// visibility and program-inclusion choices are annotation-document
    /// state applied immediately to both monitors (the S07 project-overlay
    /// precedent), not staged scene content — including them in ⌘Z scene
    /// undo would silently entangle live telestrator marks with document
    /// edits.
    /// G06 (issue #113): pdf page navigation and framing are excluded — page
    /// state is the A02 playback-position precedent (session/document state,
    /// never scene content), persisted in the presentations document outside
    /// the S12 snapshot.
    var isUndoableSceneEdit: Bool {
        switch self {
        case .addScene, .insertScene, .renameScene, .deleteScene, .updateScene,
             .duplicateScene, .moveScene,
             .addSceneFolder, .renameSceneFolder, .deleteSceneFolder,
             .setSceneLocked,
             .setLayerVisibility, .setLayerTransform, .setLayerEffects, .setLayerAudio,
             .addLayer, .removeLayer, .duplicateLayer, .renameLayer, .setLayerLocked,
             .moveLayer, .groupLayers, .ungroupLayers, .renameGroup,
             .setGroupVisibility, .setGroupLocked,
             .alignLayers, .distributeLayers,
             .addOverlay, .removeOverlay, .renameOverlay, .setOverlayVisibility,
             .setOverlayLocked, .setOverlayTransform, .setOverlayEffects, .moveOverlay,
             .addMediaOverlay,
             .setOverlayHiddenInScene, .setSceneBackground, .setDefaultBackground,
             .setSceneTransition, .setDefaultTransition,
             .setSceneSoundBindings,
             .setSceneAudioSnapshot, .captureSceneAudioSnapshot, .setSceneMediaBehavior,
             .setLayerSourceEffects,
             .setLayerStyle, .setOverlayStyle,
             .setLayerText, .setOverlayText,
             .setLayerMotionIdentity,
             .setLayerWeb, .setOverlayWeb,
             .setLayerImage, .setOverlayImage:
            return true
        case .startStream, .stopStream, .startPreview, .stopPreview,
             .startRecording, .stopRecording,
             .selectScene, .selectSceneAt, .setSceneFolderCollapsed,
             .setOutputProfile,
             .setChannelVolume, .setChannelMuted, .setChannelSolo,
             .setChannelAuxSend, .setBusGain, .setBusMuted,
             .setAudioInputEnabled, .setAudioInputMapping, .relinkAudioInput,
             .setChannelFXChain,
             .setMonitoringEnabled, .setMonitorOutputDevice, .setEchoHandlingMode,
             .setCameraControls, .triggerCameraReaction,
             .setChannelAudioDelay, .setSourceVideoDelay, .setDucking,
             .mediaPlay, .mediaPause, .mediaStop, .mediaRestart, .mediaSeek,
             .setDynamicOverlayTransport,
             .pdfNextPage, .pdfPreviousPage, .pdfGoToPage, .pdfSetFraming,
             .addSoundPad, .updateSoundPad, .removeSoundPad,
             .triggerSoundPad, .stopSoundPad, .stopAllSoundEffects,
             .addMusicPlaylist, .updateMusicPlaylist, .removeMusicPlaylist,
             .playlistPlay, .playlistPause, .playlistStop,
             .playlistNext, .playlistPrevious,
             .ptzAddTarget, .ptzUpdateTarget, .ptzRemoveTarget,
             .ptzMove, .ptzZoom, .ptzStop, .ptzStopAll,
             .ptzStorePreset, .ptzRecallPreset, .ptzRemovePreset,
             .ptzSetSceneRecall, .ptzRemoveSceneRecall,
             .addAnnotationStroke, .undoAnnotationStroke, .redoAnnotationStroke,
             .clearAnnotations, .setAnnotationVisibility,
             .setAnnotationsInProgram, .setAnnotationTool,
             .setSourceEffectDefaults,
             .addEffectPreset, .updateEffectPreset, .removeEffectPreset,
             .addStylePreset, .updateStylePreset, .removeStylePreset,
             .addTextStylePreset, .updateTextStylePreset, .removeTextStylePreset,
             .setRundown, .rundownPlay, .rundownPause, .rundownStop, .rundownSkip, .runRundownCue,
             .openSettings, .closeSettings, .applySettings, .revertSettings,
             .take, .revert, .setDirectLiveEditing,
             .undo, .redo:
            return false
        }
    }

    /// S12: the coalescing key folding rapid repeats of the SAME logical
    /// gesture (a canvas transform drag, a slider scrub, keystroke-by-
    /// keystroke renames) into one undo action. Nil = never coalesce.
    var undoCoalescingKey: String? {
        switch self {
        case .updateScene(let scene):
            return "update-scene.\(scene.id)"
        case .renameScene(let id, _):
            return "rename-scene.\(id)"
        case .renameSceneFolder(let id, _):
            return "rename-folder.\(id)"
        case .setLayerTransform(let id, _, _):
            return "layer-transform.\(id)"
        case .setLayerEffects(let id, _, _):
            return "layer-effects.\(id)"
        case .setLayerSourceEffects(let id, _, _):
            return "layer-source-effects.\(id)"
        case .setLayerStyle(let id, _, _):
            return "layer-style.\(id)"
        case .setLayerText(let id, _, _):
            return "layer-text.\(id)"
        case .setOverlayText(let id, _):
            return "overlay-text.\(id)"
        case .setLayerWeb(let id, _, _):
            return "layer-web.\(id)"
        case .setOverlayWeb(let id, _):
            return "overlay-web.\(id)"
        case .setLayerImage(let id, _, _):
            return "layer-image.\(id)"
        case .setOverlayImage(let id, _):
            return "overlay-image.\(id)"
        case .setOverlayStyle(let id, _):
            return "overlay-style.\(id)"
        case .setLayerAudio(let id, _, _):
            return "layer-audio.\(id)"
        case .renameLayer(let id, _, _):
            return "rename-layer.\(id)"
        case .renameGroup(let id, _, _):
            return "rename-group.\(id)"
        case .renameOverlay(let id, _):
            return "rename-overlay.\(id)"
        case .setOverlayTransform(let id, _):
            return "overlay-transform.\(id)"
        case .setOverlayEffects(let id, _):
            return "overlay-effects.\(id)"
        case .setSceneBackground(_, let sceneID):
            return "scene-background.\(sceneID?.description ?? "staged")"
        case .setSceneTransition(_, let sceneID):
            return "scene-transition.\(sceneID?.description ?? "staged")"
        case .setSceneSoundBindings(_, let sceneID):
            return "scene-sound-bindings.\(sceneID?.description ?? "staged")"
        case .setDefaultBackground:
            return "default-background"
        case .setDefaultTransition:
            return "default-transition"
        default:
            return nil
        }
    }
}

private extension StreamSessionState {
    /// Short phrase for rejection messages ("The stream is already connecting").
    var busyLabel: String {
        switch self {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .live: return "live"
        case .reconnecting: return "reconnecting"
        case .stopping: return "stopping"
        case .failed: return "failed"
        }
    }
}
