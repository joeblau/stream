import Foundation
import StreamCore

private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw NSError(domain: "WorkspaceHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@main @MainActor struct WorkspaceHarness {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stream-workspace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = StudioWorkspace(root: root)
        let first = workspace.selection
        let firstStore = workspace.runtime.sceneStore
        let scene = firstStore.scenes[0]
        _ = workspace.runtime.dispatcher.execute(.renameScene(scene.id, to: "First Show Camera"))
        workspace.runtime.flush()
        workspace.create(named: "Second Show")
        try require(workspace.selection == first, "Creating a show changed active project before Apply")
        await workspace.applyPending()
        try require(workspace.selection != first, "Apply did not select the new show")
        try require(workspace.runtime.sceneStore.scenes[0].name != "First Show Camera", "Scene data leaked between projects")
        firstStore.rename(scene.id, to: "Old Store Late Write")
        firstStore.flushPendingWrites()
        try require(workspace.runtime.sceneStore.scenes[0].name != "Old Store Late Write", "Old object writes crossed project directory")
        workspace.stage(project: first.project, profile: first.profile)
        await workspace.applyPending()
        try require(workspace.runtime.sceneStore.scenes[0].name == "Old Store Late Write", "Persisted project did not reload")
        workspace.addProfile(named: "Duplicate Profile", duplicate: true)
        await workspace.applyPending()
        try require(workspace.runtime.sceneStore.scenes[0].name == "Old Store Late Write", "Profile duplicate lost scenes")

        let package = root.appendingPathComponent("Test.streamshow")
        let imported = root.appendingPathComponent("imported", isDirectory: true)
        let assetID = AssetID()
        let relativePath = "Assets/\(assetID)/look.cube"
        let fixtureURL = root.appendingPathComponent("look.cube")
        let fixture = Data((["LUT_3D_SIZE 2"] + (0..<8).map { "\($0 % 2) \(($0 / 2) % 2) \($0 / 4)" }).joined(separator: "\n").utf8)
        try fixture.write(to: fixtureURL)
        var document = workspace.runtime.sceneStore.document
        var effects = SourceEffects()
        effects.lut.assetID = assetID
        document.scenes[0].layers[0].effectOverrides = effects
        let asset = LibraryAsset(id: assetID, name: "Test LUT", kind: .other, storage: .projectCopy,
            relativePath: relativePath, fileName: "look.cube", lastKnownPath: "")
        let documents = ["stream.scenes.v2.json": try JSONEncoder().encode(document),
            "stream.assets.v1.json": try JSONEncoder().encode(AssetLibraryDocument(assets: [asset]))]
        try ShowPackageIO.export(documents: documents, media: [.init(access: ResolvedAssetAccess(url: fixtureURL, needsSecurityScope: false), relativePath: relativePath)],
            name: "Transferred Show", includeMedia: true, to: package)
        let preview = try ShowPackageIO.preview(package)
        try require(preview.sceneNames.count == document.scenes.count, "Package preview lost scenes")
        try ShowPackageIO.importFiles(from: package, to: imported)
        let importedDocument = try JSONDecoder().decode(SceneDocument.self, from: Data(contentsOf: imported.appendingPathComponent("stream.scenes.v2.json")))
        let importedAssets = try JSONDecoder().decode(AssetLibraryDocument.self, from: Data(contentsOf: imported.appendingPathComponent("stream.assets.v1.json")))
        let importedID = importedAssets.assets[0].id
        try require(importedID != assetID, "Imported asset ID was not remapped")
        try require(importedDocument.scenes[0].layers[0].effectOverrides?.lut.assetID == importedID, "Imported LUT references are inconsistent")
        let importedLUT = imported.appendingPathComponent(importedAssets.assets[0].relativePath!)
        try require(try Data(contentsOf: importedLUT) == fixture, "Imported LUT bytes are missing")
        _ = try CubeLUT.parse(Data(contentsOf: importedLUT))
        try require(importedDocument.scenes[0].id != document.scenes[0].id, "Imported scene IDs were not remapped")
        print("PASS: project/profile switching, captured store paths, duplication, package preview, consistent ID remapping and packaged LUT bytes")
    }
}
