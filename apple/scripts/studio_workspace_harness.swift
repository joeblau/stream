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
        for starter in StudioStarter.allCases {
            let scene = starter.scene(camera: nil, screen: nil, profile: .default)
            let decoded = try JSONDecoder().decode(Scene.self, from: JSONEncoder().encode(scene))
            try require(decoded == scene && Set(scene.layers.map(\.id)).count == scene.layers.count, "Starter scene did not round trip with unique editable IDs")
        }
        let privacy = ProgramPrivacyGate()
        let hidden = LayerNode(name: "Private overlay", payload: .text(TextSourcePayload(text: "Private content")), transform: .fullscreen)
        let overlayContext = OverlayContext(overlays: [hidden], defaultBackground: nil)
        ProjectOverlayStore.shared.publish(overlayContext)
        privacy.setScene(Scene(name: "Offline", layers: []))
        try require(privacy.overlays().overlays.isEmpty && privacy.sceneSnapshot()?.name == "Offline", "Offline hold leaked a new project overlay")
        privacy.setScene(nil)
        try require(privacy.overlays().overlays.count == 1, "Explicit privacy restore lost overlays")
        ProjectOverlayStore.shared.publish(.empty)
        let first = workspace.selection
        try require(workspace.runtime.recorder.context.projectID == first.project.uuidString, "Recording project context is missing")
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

        let runtime = workspace.runtime
        runtime.previewProgram.setDirectLiveEditing(false)
        let publicEvent = try JSONSerialization.data(withJSONObject: ["action": "event", "timestamp": 1_800_000_000,
            "payload": ["connectionIdentifier": "fixture/channel", "eventTypeId": 5,
                "eventPayload": ["liveChatMessageId": "fixture", "text": "Hello 世界", "author": ["displayName": "Producer"]]]])
        runtime.chat.receive(publicEvent)
        let message = try runtime.chat.queue.messages.first.unwrap("Shared chat did not ingest public message")
        runtime.chat.enqueue(message.id); runtime.chat.createSlot()
        let slot = try runtime.chat.selectedSlot.unwrap("Comment slot was not created in staged scene")
        let programBefore = runtime.previewProgram.programScene
        runtime.chat.show(message.id)
        try require(runtime.previewProgram.programScene == programBefore, "Showing a staged comment changed Program before Take")
        try require(runtime.previewProgram.stagedScene?.layers.first(where: { $0.id == slot })?.isVisible == true, "Queued comment was not shown in staged scene")
        _ = runtime.dispatcher.execute(.take)
        try require(runtime.previewProgram.programScene?.layers.first(where: { $0.id == slot })?.isVisible == true, "Take did not publish the selected comment")
        runtime.chat.hide()
        try require(runtime.previewProgram.stagedScene?.layers.first(where: { $0.id == slot })?.isVisible == false, "Comment Hide missed the staged slot")
        try require(runtime.previewProgram.programScene?.layers.first(where: { $0.id == slot })?.isVisible == true, "Comment Hide changed Program without Take")
        runtime.recoveryBinding?.checkpoint()
        await workspace.recovery.flush()
        let recoveryURL = root.appendingPathComponent("SessionRecovery/current.v1.json")
        let snapshot = try JSONDecoder().decode(SessionRecoverySnapshot.self, from: Data(contentsOf: recoveryURL))
        try require(snapshot.projectID == workspace.selection.project && snapshot.profileID == workspace.selection.profile, "Recovery checkpoint captured wrong context")
        var altered = runtime.previewProgram.stagedScene!
        altered.layers[0].isVisible.toggle(); runtime.previewProgram.stage(altered)
        await workspace.recovery.restoreLocalContext?(snapshot)
        try require(runtime.previewProgram.stagedScene?.layers.first?.isVisible == snapshot.stagedLayers.first?.isVisible, "Explicit recovery failed to restore staged geometry/visibility")
        try require(!runtime.controller.outputSessionActive && !runtime.recorder.state.isActive, "Recovery started an output")
        workspace.recovery.reviewRecordings?()
        try require(workspace.showRecordingLibrary, "Recovery did not open attached recording library")

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
        var documents = ["stream.scenes.v2.json": try JSONEncoder().encode(document),
            "stream.assets.v1.json": try JSONEncoder().encode(AssetLibraryDocument(assets: [asset]))]
        documents["comment-slots.json"] = try Data(contentsOf: workspace.directory(for: workspace.selection).appendingPathComponent("comment-slots.json"))
        try ShowPackageIO.export(documents: documents, media: [.init(access: ResolvedAssetAccess(url: fixtureURL, needsSecurityScope: false), relativePath: relativePath)],
            name: "Transferred Show", includeMedia: true, to: package)
        let preview = try ShowPackageIO.preview(package)
        try require(preview.sceneNames.count == document.scenes.count, "Package preview lost scenes")
        try ShowPackageIO.importFiles(from: package, to: imported)
        let importedDocument = try JSONDecoder().decode(SceneDocument.self, from: Data(contentsOf: imported.appendingPathComponent("stream.scenes.v2.json")))
        let importedAssets = try JSONDecoder().decode(AssetLibraryDocument.self, from: Data(contentsOf: imported.appendingPathComponent("stream.assets.v1.json")))
        let importedSlots = try JSONDecoder().decode(StudioChatCoordinator.SlotPreferences.self, from: Data(contentsOf: imported.appendingPathComponent("comment-slots.json")))
        try require(importedSlots.slots.count == 1 && importedSlots.slots[0] != slot, "Imported comment slot ID was not remapped")
        try require(importedDocument.scenes.flatMap(\.layers).contains(where: { $0.id == importedSlots.slots[0] }), "Imported comment slot no longer references its text layer")
        let importedID = importedAssets.assets[0].id
        try require(importedID != assetID, "Imported asset ID was not remapped")
        try require(importedDocument.scenes[0].layers[0].effectOverrides?.lut.assetID == importedID, "Imported LUT references are inconsistent")
        let importedLUT = imported.appendingPathComponent(importedAssets.assets[0].relativePath!)
        try require(try Data(contentsOf: importedLUT) == fixture, "Imported LUT bytes are missing")
        _ = try CubeLUT.parse(Data(contentsOf: importedLUT))
        try require(importedDocument.scenes[0].id != document.scenes[0].id, "Imported scene IDs were not remapped")
        // A truncated current scene file must offer explicit recovery, retain
        // the unreadable original, and never start an output after relaunch.
        workspace.runtime.flush()
        let selectedDirectory = workspace.directory(for: workspace.selection)
        let currentURL = selectedDirectory.appendingPathComponent("stream.scenes.v2.json")
        _ = workspace.runtime.dispatcher.execute(.renameScene(workspace.runtime.sceneStore.scenes[0].id, to: "Last Saved"))
        workspace.runtime.flush()
        try Data("truncated-scene-document".utf8).write(to: currentURL)
        let restarted = StudioWorkspace(root: root)
        let recovery = try restarted.sceneRecovery.unwrap("Corrupt scenes did not offer backup recovery")
        try require(!restarted.runtime.controller.streamState.isActive && !restarted.runtime.recorder.state.isActive, "Recovery started an output")
        let preserved = try FileManager.default.contentsOfDirectory(at: selectedDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("corrupt") }
        try require(preserved.contains { (try? Data(contentsOf: $0)) == Data("truncated-scene-document".utf8) }, "Corrupt original was not preserved")
        await restarted.restore(recovery)
        try require(restarted.sceneRecovery == nil, "Successful restore kept recovery pending")
        try require(restarted.runtime.sceneStore.scenes.map(\.name) == recovery.document.scenes.map(\.name), "Accepted backup did not restore scenes")
        await RecordingTerminationDelegate.finishSession?()
        print("PASS: shared chat staging/Take, recovery binding and attached library, project/profile switching, captured store paths, duplication, package preview, consistent ID remapping and packaged LUT bytes")
    }
}

private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let value = self else { throw NSError(domain: "WorkspaceHarness", code: 2, userInfo: [NSLocalizedDescriptionKey: message]) }
        return value
    }
}
