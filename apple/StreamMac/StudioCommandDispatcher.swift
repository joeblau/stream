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

    // Output profile (W07 staged-vs-active rules live in the controller).
    case setOutputProfile(OutputProfile, destination: StreamProtocol?)

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
        case .setOutputProfile: return "Set Output Profile"
        case .openSettings: return "Open Settings"
        case .closeSettings: return "Close Settings"
        case .applySettings: return "Apply Settings"
        case .revertSettings: return "Revert Settings"
        case .take: return "Take"
        case .revert: return "Revert"
        case .setDirectLiveEditing(let on):
            return "\(on ? "Enable" : "Disable") Direct-Live Editing"
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

    private var rejectionSequence = 0
    private var rejectionTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

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
        perform(command)
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
            return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .invalidValue("A scene name can't be empty.") : nil
        case .deleteScene(let id):
            guard sceneStore.scenes.contains(where: { $0.id == id }) else {
                return .invalidTarget("Scene \(id) does not exist.")
            }
            return sceneStore.scenes.count > 1
                ? nil : .unavailable("The last remaining scene can't be deleted.")
        case .updateScene(let scene):
            guard sceneStore.scenes.contains(where: { $0.id == scene.id }) else {
                return .invalidTarget("Scene \(scene.id) does not exist.")
            }
            // W03: visual edits only ever touch the staged copy, so a whole-
            // scene edit must address the scene staged in preview.
            return previewProgram.stagedScene?.id == scene.id
                ? nil : .invalidTarget("Scene \"\(scene.name)\" is not staged in preview — select it first.")

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
            case .success:
                return payload.isRenderable
                    ? nil
                    : .invalidValue("\(payload.displayName) layers are model-only — the render path composites camera, screen, text, and shape layers today.")
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

        case .setOutputProfile:
            // Always acceptable: the controller clamps to hardware/destination
            // and stages the edit while outputs own the geometry (W07).
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

        case .setOutputProfile(let profile, let destination):
            controller.applyOutputProfile(profile, destination: destination)

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
        }
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
            directLiveEditing: previewProgram.directLiveEditing,
            layerVisibility: Dictionary(
                uniqueKeysWithValues: (staged?.layers ?? []).map { ($0.id, $0.isVisible) }),
            layerLocks: Dictionary(
                uniqueKeysWithValues: (staged?.layers ?? []).map {
                    ($0.id, staged?.isEffectivelyLocked($0) ?? false)
                }),
            settingsPresented: session.isPresented,
            settingsDirty: session.isDirty)
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
