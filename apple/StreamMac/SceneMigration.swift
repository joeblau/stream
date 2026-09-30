import Foundation
import StreamCore

// MARK: - v1 → v2 migration
//
// The v1 format (stream.scenes.v1.json) stored three fixed layouts with flat
// `pipCorner`/`pipScale` fields. These legacy types mirror that exact wire
// format so existing installs decode once, then upgrade to the v2 layer graph
// preserving scene IDs, names, PIP corner/size, and selection.

/// v1 snapshot as written by the previous `SceneStore`.
struct LegacySceneDocumentV1: Codable {
    var scenes: [LegacySceneV1]
    var selectedID: UUID
}

struct LegacySceneV1: Codable {
    var id: UUID
    var name: String
    var layout: LegacySceneLayoutV1
    var pipCorner: PIPCorner
    var pipScale: Double
}

enum LegacySceneLayoutV1: String, Codable {
    case cameraSolo, screenSolo, screenPlusCam
}

extension SceneDocument {
    /// Builds a v2 document from a decoded v1 snapshot. The fixed layouts map
    /// to equivalent layer graphs (screen+cam becomes a fullscreen screen
    /// layer plus a camera PIP layer keeping its corner and scale); scene and
    /// selection IDs carry over unchanged. One shared camera and one shared
    /// screen `SourceDefinition` are created so the migrated layers have
    /// stable bindings from the start.
    init(migratingV1 legacy: LegacySceneDocumentV1) {
        let cameraSource = SourceDefinition(name: "Camera",
                                            payload: .camera(CameraSourcePayload()))
        let screenSource = SourceDefinition(name: "Screen",
                                            payload: .screen(ScreenSourcePayload()))

        let scenes = legacy.scenes.map { legacyScene -> Scene in
            let id = SceneID(legacyScene.id)
            switch legacyScene.layout {
            case .cameraSolo:
                return .cameraSolo(name: legacyScene.name, id: id,
                                   cameraSourceID: cameraSource.id)
            case .screenSolo:
                return .screenSolo(name: legacyScene.name, id: id,
                                   screenSourceID: screenSource.id)
            case .screenPlusCam:
                return .screenPlusCam(name: legacyScene.name, id: id,
                                      corner: legacyScene.pipCorner,
                                      scale: legacyScene.pipScale,
                                      screenSourceID: screenSource.id,
                                      cameraSourceID: cameraSource.id)
            }
        }

        let legacySelection = SceneID(legacy.selectedID)
        let selection = scenes.contains(where: { $0.id == legacySelection })
            ? legacySelection
            : (scenes.first?.id ?? legacySelection)

        self.init(version: SceneDocument.currentVersion,
                  sources: [cameraSource, screenSource],
                  scenes: scenes,
                  selectedID: selection)
    }

    /// First-launch document: the same three scenes the v1 store shipped,
    /// expressed directly as layer graphs.
    static func makeDefault() -> SceneDocument {
        let legacy = LegacySceneDocumentV1(
            scenes: [
                LegacySceneV1(id: UUID(), name: "Camera", layout: .cameraSolo,
                              pipCorner: .bottomRight, pipScale: 0.28),
                LegacySceneV1(id: UUID(), name: "Screen", layout: .screenSolo,
                              pipCorner: .bottomRight, pipScale: 0.28),
                LegacySceneV1(id: UUID(), name: "Screen + Cam", layout: .screenPlusCam,
                              pipCorner: .bottomRight, pipScale: 0.28)
            ],
            selectedID: UUID())   // replaced below with the third scene's ID
        var document = SceneDocument(migratingV1: legacy)
        if let last = document.scenes.last {
            document.selectedID = last.id
        }
        return document
    }
}
