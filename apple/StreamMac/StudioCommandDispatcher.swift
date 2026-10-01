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
            case .success: return nil
            case .failure(let error): return error
            }

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
    private func resolveLayer(_ layerID: LayerID,
                              in sceneID: SceneID?) -> Result<(Scene, Int), StudioCommandError> {
        guard let scene = previewProgram.stagedScene else {
            return .failure(.invalidTarget("No scene is staged in preview."))
        }
        if let sceneID, scene.id != sceneID {
            let name = sceneStore.scenes.first(where: { $0.id == sceneID })?.name
            return .failure(.invalidTarget(name.map { "Scene \"\($0)\" is not staged in preview — select it first." }
                                           ?? "Scene \(sceneID) does not exist."))
        }
        guard let index = scene.layers.firstIndex(where: { $0.id == layerID }) else {
            return .failure(.invalidTarget("Layer \(layerID) does not exist in scene \"\(scene.name)\"."))
        }
        return .success((scene, index))
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
