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
        case .addOverlay(let payload): return "Add \(payload.displayName) Overlay"
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
        case .mediaPlay: return "Play Media"
        case .mediaPause: return "Pause Media"
        case .mediaStop: return "Stop Media"
        case .mediaRestart: return "Restart Media"
        case .mediaSeek: return "Seek Media"
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
    /// S12 undo/redo availability and the labels of the edits ⌘Z / ⇧⌘Z would
    /// apply (the Edit menu shows "Undo <label>").
    var canUndo = false
    var canRedo = false
    var undoLabel: String? = nil
    var redoLabel: String? = nil
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
        self.state = StudioState()
        let mic = AudioChannelID.microphone(deviceUID: nil)
        channelIDsByLabel[mic.label] = mic
        refreshState()

        // External changes (publisher events, the recording writer finishing,
        // scene edits) never pass through `execute`, so observe the stores
        // directly. `objectWillChange` fires in willSet — the Task hop lands
        // post-set, so the snapshot reads current values.
        Publishers.Merge(
            Publishers.Merge4(
                controller.objectWillChange,
                sceneStore.objectWillChange,
                session.objectWillChange,
                recorder.objectWillChange),
            previewProgram.objectWillChange)
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

        // S07 project overlays: validated against the SceneStore overlay
        // list (project level — never the staged scene).
        case .addOverlay(let payload):
            // Branding overlays only: text/shape render without a capture.
            // Camera/screen overlays would need the S05 demand reconciliation
            // to watch the overlay list (it watches scenes today); the other
            // kinds have no renderer yet.
            return payload.isText || payload.isShape
                ? nil
                : .invalidValue("\(payload.displayName) overlays aren't supported yet — add a Text or Shape overlay.")
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
        case .startStream: controller.goLive()
        case .stopStream: controller.stopStream()
        case .startPreview: controller.startPreview()
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

        // S07 project overlays: project-level edits — SceneStore publishes
        // them to every engine on persist, so staged AND program composite
        // the change on their next tick. No staged edit, no implicit take.
        case .addOverlay(let payload):
            sceneStore.addOverlay(makeOverlay(payload: payload))
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

        case .mediaPlay(let id): controller.capturePool.playMedia(id)
        case .mediaPause(let id): controller.capturePool.pauseMedia(id)
        case .mediaStop(let id): controller.capturePool.stopMedia(id)
        case .mediaRestart(let id): controller.capturePool.restartMedia(id)
        case .mediaSeek(let id, let seconds):
            controller.capturePool.seekMedia(id, toSeconds: seconds)

        case .setOutputProfile(let profile, let destination):
            controller.applyOutputProfile(profile, destination: destination)

        // A04 mixer execution: mutate the persisted mixer document through
        // SettingsSession (single truth), register the channel ID so the
        // engine push can address it, and let `refreshState`'s push apply the
        // change live (ramped) through the controller.
        case .setChannelVolume(let id, let volume):
            channelIDsByLabel[id.label] = id
            if case .microphone = id {
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

        case .openSettings(let section): session.showSettings(section: section)
        case .closeSettings: session.isPresented = false
        case .applySettings: session.apply()
        case .revertSettings: session.revert()

        case .take:
            // W03: staged → program, atomically. The model swap republishes
            // the program engine through the controller's observation (no
            // cadence/media interruption); persisting here keeps SceneStore
            // the source of truth for the PUBLISHED composition only.
            guard let published = previewProgram.take() else { return }
            sceneStore.update(published)
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
        guard previewProgram.directLiveEditing,
              let published = previewProgram.take() else { return }
        sceneStore.update(published)
    }

    // MARK: Layer helpers

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
             .setSceneBackground(_, let id):
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
        default:
            // Shape: a small solid block in the top-right corner.
            return LayerNode(name: "\(payload.displayName) Overlay", payload: payload,
                             transform: LayerTransform(
                                position: GraphPoint(x: 0.98, y: 0.02),
                                size: GraphSize(width: 0.10, height: 0.06),
                                anchor: .topRight))
        }
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
            canUndo: undoStack.canUndo,
            canRedo: undoStack.canRedo,
            undoLabel: undoStack.undoLabel,
            redoLabel: undoStack.redoLabel)
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
        // Channels: fader/mute per registered non-capture ID (capture levels
        // are scene bindings). The mic's fader is the settings micVolume;
        // others read the mixer document.
        for (label, id) in channelIDsByLabel {
            if case .capture = id { continue }
            let volume: Float
            if case .microphone = id {
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
             .setOverlayHiddenInScene, .setSceneBackground, .setDefaultBackground:
            return true
        case .startStream, .stopStream, .startPreview, .stopPreview,
             .startRecording, .stopRecording,
             .selectScene, .selectSceneAt, .setSceneFolderCollapsed,
             .setOutputProfile,
             .setChannelVolume, .setChannelMuted, .setChannelSolo,
             .setChannelAuxSend, .setBusGain, .setBusMuted,
             .mediaPlay, .mediaPause, .mediaStop, .mediaRestart, .mediaSeek,
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
        case .setDefaultBackground:
            return "default-background"
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
