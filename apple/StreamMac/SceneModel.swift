import Foundation
import Combine
import StreamCore

/// Which sources a scene composites into the outgoing frame.
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

/// One switchable scene (Ecamm-style). `pipCorner`/`pipScale` only apply to
/// `.screenPlusCam`; `pipScale` is the fraction of frame width (0.10...0.40).
struct Scene: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var name: String
    var layout: SceneLayout
    var pipCorner: PIPCorner
    var pipScale: Double

    init(id: UUID = UUID(),
         name: String,
         layout: SceneLayout,
         pipCorner: PIPCorner = .bottomRight,
         pipScale: Double = 0.28) {
        self.id = id
        self.name = name
        self.layout = layout
        self.pipCorner = pipCorner
        self.pipScale = pipScale
    }
}

/// The scene list + selection, persisted as JSON in the shared App Group
/// container (same storage pattern as `SettingsStore`: a plain file, never the
/// UserDefaults suite, so `cfprefsd` stays quiet).
@MainActor
final class SceneStore: ObservableObject {
    @Published var scenes: [Scene] {
        didSet { persist() }
    }
    @Published var selectedID: Scene.ID {
        didSet { persist() }
    }

    private static let fileName = "stream.scenes.v1.json"

    init() {
        if let restored = Self.loadFromDisk(), !restored.scenes.isEmpty {
            scenes = restored.scenes
            let restoredSelection = restored.selectedID
            selectedID = restored.scenes.contains(where: { $0.id == restoredSelection })
                ? restoredSelection
                : restored.scenes[0].id
        } else {
            let defaults = [
                Scene(name: "Camera", layout: .cameraSolo),
                Scene(name: "Screen", layout: .screenSolo),
                Scene(name: "Screen + Cam", layout: .screenPlusCam)
            ]
            scenes = defaults
            selectedID = defaults[2].id
            persist()
        }
    }

    var selected: Scene? {
        scenes.first(where: { $0.id == selectedID })
    }

    func addScene() {
        let scene = Scene(name: "Scene \(scenes.count + 1)", layout: .screenPlusCam)
        scenes.append(scene)
        selectedID = scene.id
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

    /// Selects the scene at 1-based position `number` (⌘1…⌘9), if it exists.
    func select(number: Int) {
        let index = number - 1
        guard scenes.indices.contains(index) else { return }
        selectedID = scenes[index].id
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var scenes: [Scene]
        var selectedID: UUID
    }

    private static func fileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
            .appendingPathComponent(fileName)
    }

    private static func loadFromDisk() -> Snapshot? {
        guard let url = fileURL(),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private func persist() {
        guard let url = Self.fileURL(),
              let data = try? JSONEncoder().encode(Snapshot(scenes: scenes, selectedID: selectedID)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
