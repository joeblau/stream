import Combine
import Foundation
import StreamCore

/// Rebuild with each workspace runtime. Producers supply the actual selected
/// recorder folder inventory; no credential or writer buffer is inspected here.
@MainActor final class SessionRecoveryRuntimeBinding {
    private let coordinator: SessionRecoveryCoordinator
    private let projectID: UUID, profileID: UUID
    private let scenes: SceneStore
    private let preview: PreviewProgramModel
    private let controller: StreamController
    private let pdfDecks: PDFDeckStore
    private let recordings: @MainActor () async throws -> SessionRecoveryRecordingInventory
    private var inventory = SessionRecoveryRecordingInventory()
    private var recordingActive = false
    private var isShutdown = false
    private var observations: Set<AnyCancellable> = []
    private var poll: Task<Void, Never>?
    init(coordinator: SessionRecoveryCoordinator, projectID: UUID, profileID: UUID, sceneStore: SceneStore,
         previewProgram: PreviewProgramModel, controller: StreamController, pdfDecks: PDFDeckStore,
         recordingActivity: AnyPublisher<Bool, Never>? = nil,
         recordings: @escaping @MainActor () async throws -> SessionRecoveryRecordingInventory) {
        self.coordinator = coordinator; self.projectID = projectID; self.profileID = profileID
        self.scenes = sceneStore; self.preview = previewProgram; self.controller = controller
        self.pdfDecks = pdfDecks; self.recordings = recordings
        coordinator.beginContext(projectID: projectID, profileID: profileID)
        recordingActivity?.sink { [weak self] active in
            self?.recordingActive = active
            Task { @MainActor in self?.checkpoint() }
        }.store(in: &observations)
        previewProgram.$stagedScene.combineLatest(previewProgram.$programScene).sink { [weak self] _ in
            Task { @MainActor in self?.checkpoint() }
        }.store(in: &observations)
        controller.destinationOutputs.$states.sink { [weak self] _ in
            Task { @MainActor in self?.checkpoint() }
        }.store(in: &observations)
        poll = Task { [weak self] in
            while !Task.isCancelled && self != nil {
                await self?.refreshRecordings()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        checkpoint()
    }
    deinit { poll?.cancel() }
    func shutdown() { isShutdown = true; poll?.cancel(); poll = nil; observations.removeAll() }
    func refreshRecordings() async {
        guard !isShutdown else { return }
        do {
            let result = try await recordings()
            guard !isShutdown else { return }
            inventory = result
        }
        catch { inventory.isVerified = false }
        checkpoint()
    }
    func checkpoint() {
        guard !isShutdown else { return }
        var value = SessionRecoverySnapshot(projectID: projectID, profileID: profileID)
        value.programSceneID = preview.programScene?.id.rawValue
        value.stagedSceneID = preview.stagedScene?.id.rawValue
        value.hasStagedEdits = preview.hasPendingEdits
        value.stagedLayers = Array((preview.stagedScene?.layers ?? []).prefix(2_000)).map {
            SessionRecoveryLayer(id: $0.id.rawValue, sourceID: $0.sourceID?.rawValue,
                x: $0.transform.position.x, y: $0.transform.position.y, width: $0.transform.size.width,
                height: $0.transform.size.height, rotation: $0.transform.rotationDegrees,
                anchor: $0.transform.anchor.rawValue, isVisible: $0.isVisible)
        }
        value.activeOutputIDs = controller.destinationOutputs.states.filter { $0.value.isActive }.map(\.key).sorted { $0.uuidString < $1.uuidString }
        // Provider event APIs are absent. Local connection state cannot verify
        // whether the remote event ended or is reconnectable.
        value.remoteEvents = value.activeOutputIDs.map { SessionRecoveryRemoteEvent(outputID: $0) }
        value.recordings = inventory.segments; value.recordingInventoryVerified = inventory.isVerified
        value.recordingWasActive = recordingActive
        value.media = Array(scenes.sources.prefix(2_000)).compactMap { source in
            switch source.payload {
            case .media:
                return SessionRecoveryMedia(sourceID: source.id.rawValue, seconds: max(0, controller.capturePool.mediaStatus(for: source.id).positionSeconds))
            case .pdf(let payload):
                return SessionRecoveryMedia(sourceID: source.id.rawValue, page: pdfDecks.state(for: source.id, fallbackPage: payload.page).page)
            default: return nil
            }
        }
        coordinator.checkpoint(value)
    }
    /// Call only after the producer explicitly selected/confirmed the matching
    /// project/profile. It changes local snapshots, never fires Take or cues.
    func restoreLocal(_ snapshot: SessionRecoverySnapshot) throws {
        guard snapshot.validationError == nil, snapshot.projectID == projectID, snapshot.profileID == profileID,
              !controller.outputSessionActive, !recordingActive else { throw SessionRecoveryDiskStore.Failure.invalid }
        var missing = 0
        if let id = snapshot.programSceneID, scenes.scene(withID: SceneID(id)) == nil { missing += 1 }
        if let id = snapshot.stagedSceneID, scenes.scene(withID: SceneID(id)) == nil { missing += 1 }
        if let id = snapshot.programSceneID, let scene = scenes.scene(withID: SceneID(id)) { preview.setResilienceProgram(scene) }
        if let id = snapshot.stagedSceneID, var scene = scenes.scene(withID: SceneID(id)) {
            for edit in snapshot.stagedLayers {
                guard let index = scene.layers.firstIndex(where: { $0.id.rawValue == edit.id }),
                      let anchor = LayerAnchor(rawValue: edit.anchor) else { missing += 1; continue }
                scene.layers[index].transform = LayerTransform(position: GraphPoint(x: edit.x, y: edit.y),
                    size: GraphSize(width: edit.width, height: edit.height), anchor: anchor, rotationDegrees: edit.rotation)
                scene.layers[index].isVisible = edit.isVisible
                if let id = edit.sourceID, scenes.sources.contains(where: { $0.id.rawValue == id }) { scene.layers[index].sourceID = SourceDefinitionID(id) }
            }
            let order = snapshot.stagedLayers.map(\.id)
            if order.count == scene.layers.count && Set(order) == Set(scene.layers.map { $0.id.rawValue }) {
                let ranks = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
                scene.layers.sort { ranks[$0.id.rawValue]! < ranks[$1.id.rawValue]! }
            }
            preview.stage(scene)
        }
        for media in snapshot.media {
            let id = SourceDefinitionID(media.sourceID)
            guard scenes.sources.contains(where: { $0.id == id }) else { missing += 1; continue }
            if let page = media.page { pdfDecks.setPage(page, for: id) }
            if let seconds = media.seconds { controller.capturePool.restorePausedMediaPosition(id, seconds: seconds) }
        }
        if missing > 0 { coordinator.reportError("\(missing) saved scene/layer/media references are missing. Restore a project backup or relink them in the studio; the available local context was restored.") }
        checkpoint()
    }
}
