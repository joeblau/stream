import Combine
import Foundation

/// A numeric draft belongs to one runtime, staged scene and single selection.
/// Losing that authority retires it permanently, including selection A→B→A.
@MainActor
final class LayerGeometryEditor: ObservableObject {
    @Published var draft: LayerGeometryDraft
    @Published private(set) var isRetired = false
    @Published private(set) var error: String?
    let sceneID: SceneID
    let layerID: LayerID
    @Published private(set) var layerName: String
    @Published private(set) var anchor: LayerAnchor
    @Published private(set) var isCamera: Bool
    private var baseline: LayerTransform
    private weak var workspace: StudioWorkspace?
    private weak var runtime: StudioRuntime?
    private var observations: Set<AnyCancellable> = []

    init(workspace: StudioWorkspace, runtime: StudioRuntime, sceneID: SceneID, layer: LayerNode) {
        self.workspace = workspace; self.runtime = runtime
        self.sceneID = sceneID; layerID = layer.id; layerName = layer.name; anchor = layer.transform.anchor
        isCamera = layer.payload.isCamera
        baseline = layer.transform; draft = LayerGeometryDraft(layer.transform)
        workspace.$runtime.dropFirst().sink { [weak self, weak runtime] next in
            if next !== runtime { self?.isRetired = true }
        }.store(in: &observations)
        workspace.$isSwitching.dropFirst().sink { [weak self] switching in
            if switching { self?.isRetired = true }
        }.store(in: &observations)
        runtime.sceneStore.$selectedLayerIDs.dropFirst().sink { [weak self] selected in
            guard let self else { return }
            if selected != [self.layerID] { self.isRetired = true }
        }.store(in: &observations)
        let profile = runtime.dispatcher.state.activeProfile
        runtime.dispatcher.$state.dropFirst().sink { [weak self] state in
            if state.activeProfile != profile { self?.isRetired = true }
            // Lock/availability changes refresh the controls without replacing
            // their StateObject or rewriting an in-progress text draft.
            self?.objectWillChange.send()
        }.store(in: &observations)
        runtime.previewProgram.$stagedScene.dropFirst().sink { [weak self] scene in
            guard let self else { return }
            if scene?.id != self.sceneID || scene?.layers.contains(where: { $0.id == self.layerID }) != true {
                self.isRetired = true
            } else if let layer = scene?.layers.first(where: { $0.id == self.layerID }) {
                if self.layerName != layer.name { self.layerName = layer.name }
                if self.anchor != layer.transform.anchor { self.anchor = layer.transform.anchor }
                if self.isCamera != layer.payload.isCamera { self.isCamera = layer.payload.isCamera }
            }
        }.store(in: &observations)
    }

    private var context: (StudioRuntime, LayerNode)? {
        guard !isRetired, let runtime, workspace?.runtime === runtime, workspace?.isSwitching == false,
              runtime.sceneStore.selectedLayerIDs == [layerID],
              let scene = runtime.previewProgram.stagedScene, scene.id == sceneID,
              let layer = scene.layers.first(where: { $0.id == layerID }) else { return nil }
        return (runtime, layer)
    }

    var unavailableReason: String? {
        guard let (runtime, layer) = context else {
            return "This geometry editor belongs to a previous selection or project. Select the layer again to edit it."
        }
        return runtime.dispatcher.canExecute(.setLayerTransform(layerID, layer.transform, in: sceneID))
            ? nil : "This layer or its scene/group is locked or unavailable."
    }

    var usesCameraPIP: Bool {
        guard isCamera, let (_, layer) = context,
              let width = draft.cameraPIPWidth(current: layer.transform) else { return false }
        return width < 1
    }

    func reload() {
        guard let (_, layer) = context else { return }
        baseline = layer.transform; draft = LayerGeometryDraft(layer.transform); error = nil
    }

    @discardableResult
    func apply() -> Bool {
        guard let (runtime, layer) = context else { error = unavailableReason; return false }
        let proposed: LayerTransform
        switch draft.resolved(baseline: baseline, current: layer.transform,
                              canvas: runtime.dispatcher.state.activeProfile.canvasSize,
                              isCamera: layer.payload.isCamera) {
        case .failure(let reason): error = reason.localizedDescription; return false
        case .success(let transform): proposed = transform
        }
        guard proposed != layer.transform else { reload(); return true }
        // One deliberate Apply is one undo operation, independent of a nearby
        // pointer drag or another Apply; all existing validation still runs.
        let result = runtime.dispatcher.execute(.setLayerTransform(layerID, proposed, in: sceneID), coalescing: false)
        switch result.outcome {
        case .success: reload(); return true
        case .rejected(let reason): error = reason.description; return false
        }
    }
}

/// A visible inspector can outlive its draft's authority (for example after a
/// same-runtime profile change). Recovery replaces the draft, never revives it.
@MainActor
final class LayerGeometryPresentation: ObservableObject {
    @Published private(set) var editor: LayerGeometryEditor
    private weak var workspace: StudioWorkspace?
    private weak var runtime: StudioRuntime?
    private let sceneID: SceneID
    private let layerID: LayerID
    private var editorObservation: AnyCancellable?

    init(workspace: StudioWorkspace, runtime: StudioRuntime, sceneID: SceneID, layer: LayerNode) {
        self.workspace = workspace; self.runtime = runtime
        self.sceneID = sceneID; layerID = layer.id
        editor = LayerGeometryEditor(workspace: workspace, runtime: runtime, sceneID: sceneID, layer: layer)
        observeEditor()
    }

    private var currentTarget: (StudioWorkspace, StudioRuntime, LayerNode)? {
        guard let workspace, let runtime, workspace.runtime === runtime, !workspace.isSwitching,
              runtime.sceneStore.selectedLayerIDs == [layerID],
              let scene = runtime.previewProgram.stagedScene, scene.id == sceneID,
              let layer = scene.layers.first(where: { $0.id == layerID }) else { return nil }
        return (workspace, runtime, layer)
    }

    func canStartNewDraft(replacing previous: LayerGeometryEditor) -> Bool {
        previous === editor && previous.isRetired && currentTarget != nil
    }

    @discardableResult
    func startNewDraft(replacing previous: LayerGeometryEditor) -> Bool {
        guard previous === editor, previous.isRetired,
              let (workspace, runtime, layer) = currentTarget else { return false }
        editor = LayerGeometryEditor(workspace: workspace, runtime: runtime, sceneID: sceneID, layer: layer)
        observeEditor()
        return true
    }

    private func observeEditor() {
        editorObservation = editor.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }
}
