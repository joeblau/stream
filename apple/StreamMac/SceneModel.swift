import Foundation
import Combine
import StreamCore

/// The classic three-layout view of a scene, now derived from (and applied
/// back onto) the layer graph — see the `Scene` extension below. Kept as the
/// compatibility surface for the fixed-layout UI and render path while the
/// graph model underneath is the source of truth.
enum SceneLayout: String, Codable, CaseIterable, Sendable {
    case cameraSolo, screenSolo, screenPlusCam

    var displayName: String {
        switch self {
        case .cameraSolo: return "Camera"
        case .screenSolo: return "Screen"
        case .screenPlusCam: return "Screen + Cam"
        }
    }

    var usesScreen: Bool {
        switch self {
        case .screenSolo, .screenPlusCam: return true
        case .cameraSolo: return false
        }
    }

    var usesCamera: Bool {
        switch self {
        case .cameraSolo, .screenPlusCam: return true
        case .screenSolo: return false
        }
    }
}

extension Scene {
    /// The topmost camera layer that is a PIP box (anything not fullscreen).
    /// Visibility is ignored so PIP geometry survives layout switches.
    private var cameraPIPIndex: Int? {
        layers.lastIndex(where: { $0.payload.isCamera && $0.transform.size.width < 1 })
    }

    /// The fixed-layout equivalent of the graph: which visible sources the
    /// scene composites. Setting it rebuilds the visible layers for that
    /// layout, reusing existing layers (and their source bindings) and
    /// keeping a hidden PIP layer so corner/size survive layout switches —
    /// the v1 model stored those fields unconditionally.
    var layout: SceneLayout {
        get {
            let hasScreen = layers.contains { $0.isVisible && $0.payload.isScreen }
            let hasCamera = layers.contains { $0.isVisible && $0.payload.isCamera }
            switch (hasScreen, hasCamera) {
            case (true, true): return .screenPlusCam
            case (true, false): return .screenSolo
            default: return .cameraSolo
            }
        }
        set {
            let cameraSourceID = layers.first(where: { $0.payload.isCamera })?.sourceID
            let screen = layers.first(where: { $0.payload.isScreen })
                ?? .fullscreenScreen(sourceID: nil)
            var pip = cameraPIPIndex.map { layers[$0] }
                ?? .cameraPIP(corner: .bottomRight, scale: 0.28, sourceID: cameraSourceID)

            switch newValue {
            case .cameraSolo:
                pip.isVisible = false
                layers = [layers.first(where: { $0.payload.isCamera && $0.transform.size.width >= 1 })
                            ?? .fullscreenCamera(sourceID: cameraSourceID), pip]
            case .screenSolo:
                pip.isVisible = false
                layers = [screen, pip]
            case .screenPlusCam:
                pip.isVisible = true
                layers = [screen, pip]
            }
        }
    }

    /// The PIP corner of the camera overlay (`.bottomRight` when the scene
    /// has no camera PIP layer). Only meaningful for `.screenPlusCam`.
    var pipCorner: PIPCorner {
        get {
            cameraPIPIndex.map { PIPCorner(anchor: layers[$0].transform.anchor) } ?? .bottomRight
        }
        set {
            guard let index = cameraPIPIndex else { return }
            layers[index].transform = LayerTransform(pipCorner: newValue,
                                                     scale: layers[index].transform.size.width)
        }
    }

    /// The PIP size as a fraction of frame width (0.10...0.40), or the
    /// classic default when the scene has no camera PIP layer.
    var pipScale: Double {
        get {
            cameraPIPIndex.map { layers[$0].transform.size.width } ?? 0.28
        }
        set {
            guard let index = cameraPIPIndex else { return }
            layers[index].transform = LayerTransform(pipCorner: pipCorner, scale: newValue)
        }
    }
}

/// The scene list + selection, persisted as the versioned `SceneDocument`
/// (v2) in the shared App Group container (same storage pattern as
/// `SettingsStore`: a plain file, never the UserDefaults suite, so
/// `cfprefsd` stays quiet). On first launch after the upgrade, an existing
/// v1 file is migrated once and left on disk untouched.
@MainActor
final class SceneStore: ObservableObject {
    @Published var scenes: [Scene] {
        didSet { persist() }
    }
    @Published var selectedID: Scene.ID {
        didSet { persist() }
    }
    /// Project-level reusable sources that layers bind to via `sourceID`.
    @Published private(set) var sources: [SourceDefinition] {
        didSet { persist() }
    }
    private var projectID: ProjectID
    private var projectName: String

    private static let fileNameV2 = "stream.scenes.v2.json"
    private static let fileNameV1 = "stream.scenes.v1.json"

    init() {
        let loaded = Self.loadV2().flatMap { $0.scenes.isEmpty ? nil : $0 }
        let document = loaded
            ?? Self.loadV1().flatMap { $0.scenes.isEmpty ? nil : SceneDocument(migratingV1: $0) }
            ?? SceneDocument.makeDefault()
        projectID = document.projectID
        projectName = document.projectName
        sources = document.sources
        scenes = document.scenes
        selectedID = document.scenes.contains(where: { $0.id == document.selectedID })
            ? document.selectedID
            : document.scenes[0].id
        persist()
    }

    /// The whole persisted model, for consumers that work at document level.
    var document: SceneDocument {
        SceneDocument(projectID: projectID,
                      projectName: projectName,
                      sources: sources,
                      scenes: scenes,
                      selectedID: selectedID)
    }

    var selected: Scene? {
        scenes.first(where: { $0.id == selectedID })
    }

    private var cameraSourceID: SourceDefinitionID? {
        sources.first(where: { $0.payload.isCamera })?.id
    }

    private var screenSourceID: SourceDefinitionID? {
        sources.first(where: { $0.payload.isScreen })?.id
    }

    func addScene() {
        addScene(Scene.screenPlusCam(name: "Scene \(scenes.count + 1)",
                                     screenSourceID: screenSourceID,
                                     cameraSourceID: cameraSourceID))
    }

    /// Appends a fully-formed scene (built from the `Scene` factories — e.g.
    /// the W06 first-run sample scene) and selects it.
    @discardableResult
    func addScene(_ scene: Scene) -> Scene {
        scenes.append(scene)
        selectedID = scene.id
        return scene
    }

    func rename(_ id: Scene.ID, to name: String) {
        guard let index = scenes.firstIndex(where: { $0.id == id }) else { return }
        scenes[index].name = name
    }

    func delete(_ id: Scene.ID) {
        guard scenes.count > 1 else { return }   // never leave zero scenes
        scenes.removeAll { $0.id == id }
        if !scenes.contains(where: { $0.id == selectedID }) {
            selectedID = scenes[0].id
        }
    }

    func update(_ scene: Scene) {
        guard let index = scenes.firstIndex(where: { $0.id == scene.id }) else { return }
        scenes[index] = scene
    }

    /// Aligns every scene's canvas reference size with the output profile's
    /// canvas (W07): transforms are normalized to the canvas, so this records
    /// the new aspect/resolution intent only — no layer is repositioned.
    func setCanvasSize(_ size: CGSize) {
        let reference = GraphSize(width: Double(size.width), height: Double(size.height))
        guard scenes.contains(where: { $0.canvas.referenceSize != reference }) else { return }
        scenes = scenes.map { scene in
            var scene = scene
            scene.canvas.referenceSize = reference
            return scene
        }
    }

    /// Selects the scene at 1-based position `number` (⌘1…⌘9), if it exists.
    func select(number: Int) {
        let index = number - 1
        guard scenes.indices.contains(index) else { return }
        selectedID = scenes[index].id
    }

    // MARK: - Persistence

    private static func fileURL(_ fileName: String) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
            .appendingPathComponent(fileName)
    }

    private static func loadV2() -> SceneDocument? {
        guard let url = fileURL(fileNameV2),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SceneDocument.self, from: data)
    }

    private static func loadV1() -> LegacySceneDocumentV1? {
        guard let url = fileURL(fileNameV1),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LegacySceneDocumentV1.self, from: data)
    }

    private func persist() {
        guard let url = Self.fileURL(Self.fileNameV2),
              let data = try? JSONEncoder().encode(document) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
