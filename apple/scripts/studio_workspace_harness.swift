import AppKit
import Foundation
import StreamCore
import SwiftUI

// Generated runner boundaries use this suite and machine folder rather than
// importing or changing an operator's credentials, preferences or recordings.
enum WorkspaceFixtureDefaults {
    static let name = "stream.workspace-validation.\(UUID())"
    static var value: UserDefaults { UserDefaults(suiteName: name)! }
}
enum WorkspaceFixtureStorage {
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("stream-workspace-\(UUID())")
    static let machineDirectory = root.appendingPathComponent("Machine", isDirectory: true)
    static let recordingsDirectory = machineDirectory.appendingPathComponent("Recordings", isDirectory: true)
}
@MainActor enum WorkspaceViewReceipts {
    static var appeared: [ObjectIdentifier: Int] = [:]
    static var disappeared: [ObjectIdentifier: Int] = [:]
    static var previewSuppressed: [ObjectIdentifier: Int] = [:]
}

private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw NSError(domain: "WorkspaceHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@main @MainActor struct WorkspaceHarness {
    static func main() {
        setbuf(stdout, nil)
        guard CGSessionCopyCurrentDictionary() != nil else {
            print("UNQUALIFIED: shipping MainWindow lifecycle needs a logged-in WindowServer session")
            exit(77)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
        }
        app.run()
    }
    static func waitForView(_ workspace: StudioWorkspace, retired: StudioRuntime? = nil, afterDisappearance: Int = 0) async throws {
        let runtime = workspace.runtime, id = ObjectIdentifier(runtime)
        var ready = false
        for _ in 0..<600 {
            if WorkspaceViewReceipts.appeared[id, default: 0] > 0
                && WorkspaceViewReceipts.previewSuppressed[ObjectIdentifier(runtime.controller), default: 0] > 0
                && (retired == nil || WorkspaceViewReceipts.disappeared[ObjectIdentifier(retired!), default: 0] > afterDisappearance) {
                ready = true; break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(ready, "Shipping MainWindow did not appear/retire its actual root within six seconds")
        try await Task.sleep(for: .milliseconds(100))
        try require(runtime.providerAccounts.canRequest(.youtube) && runtime.providerAccounts.canRequest(.twitch),
            "Old MainWindow disappearance permanently closed the current account session")
        try require(runtime.controller.ending.isBound, "MainWindow did not retain/rebind the current ending coordinator (new appear=\(WorkspaceViewReceipts.appeared[id, default: 0]), old disappear=\(retired.map { WorkspaceViewReceipts.disappeared[ObjectIdentifier($0), default: 0] } ?? 0), old ending=\(retired?.controller.ending.isBound ?? false), current accounts=\(runtime.providerAccounts.canRequest(.youtube)))")
        try require(!runtime.controller.isPreviewing && !runtime.controller.outputSessionActive && !runtime.recorder.state.isActive,
            "UI fixture allocated real capture or output")
        let managed = try runtime.controller.managedStart.unwrap("Current runtime has no managed-start binding")
        var unsupported = StreamDestination(name: "Lifecycle-only unsupported provider")
        unsupported.providerBinding = .init(provider: .twitch, channelID: "fixture")
        _ = managed.request(.init(destination: unsupported, settings: .default))
        try require(managed.entries.contains { $0.id == unsupported.id && $0.phase == .blocked }
            && runtime.controller.managedStartHasEntries,
            "MainWindow permanently retired the bound managed-start coordinator/observer")
        managed.cancel(unsupported.id)
        // Local read-only eligibility only: never call Verify or authorize.
        let output = UUID()
        var snapshot = SessionRecoverySnapshot(projectID: workspace.selection.project, profileID: workspace.selection.profile)
        snapshot.remoteEvents = [.init(outputID: output, eventID: "fixture-event", provider: .youtube,
            channelID: "fixture-channel", publisherSessionID: UUID(), capturedAt: Date())]
        workspace.recovery.remoteReview.load(snapshot, context: .init(projectID: workspace.selection.project,
            profileID: workspace.selection.profile, generation: UUID()))
        try require(workspace.recovery.remoteReview.canVerify(output), "UI disappearance retired the current recovery review gate")
        workspace.recovery.remoteReview.load(nil, context: nil)
    }
    static func applyWithView(_ workspace: StudioWorkspace) async throws {
        let retired = workspace.runtime
        let oldDisappearance = WorkspaceViewReceipts.disappeared[ObjectIdentifier(retired), default: 0]
        await workspace.applyPending()
        try await waitForView(workspace, retired: retired, afterDisappearance: oldDisappearance)
    }
    static func run() async throws {
        let root = WorkspaceFixtureStorage.root
        defer {
            try? FileManager.default.removeItem(at: root)
            WorkspaceFixtureDefaults.value.removePersistentDomain(forName: WorkspaceFixtureDefaults.name)
        }
        // Provision only our own catalog/profile before startup so the app's
        // first-launch legacy copy never reads the operator's App Group files.
        let seededCatalog = StudioProjectCatalog()
        let seededDirectory = root.appendingPathComponent(StudioProjectCatalog.relativeDirectory(
            project: seededCatalog.selectedProjectID, profile: seededCatalog.selectedProfileID))
        try FileManager.default.createDirectory(at: seededDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(seededCatalog).write(to: root.appendingPathComponent("projects.v1.json"))
        let workspace = StudioWorkspace(root: root)
        WorkspaceFixtureDefaults.value.set(true, forKey: "onboarding.hasCompletedFirstRun")
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1440, height: 900),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: WorkspaceApplicationRoot(workspace: workspace))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await waitForView(workspace)
        let initialRuntime = workspace.runtime
        let firstAppear = WorkspaceViewReceipts.appeared[ObjectIdentifier(initialRuntime), default: 0]
        let firstDisappear = WorkspaceViewReceipts.disappeared[ObjectIdentifier(initialRuntime), default: 0]
        window.contentView = nil
        for _ in 0..<600 {
            if WorkspaceViewReceipts.disappeared[ObjectIdentifier(initialRuntime), default: 0] > firstDisappear { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(WorkspaceViewReceipts.disappeared[ObjectIdentifier(initialRuntime), default: 0] > firstDisappear,
            "Owned window detachment did not trigger actual MainWindow disappearance")
        try require(initialRuntime.providerAccounts.canRequest(.youtube), "Window detach closed current accounts")
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<600 {
            if WorkspaceViewReceipts.appeared[ObjectIdentifier(initialRuntime), default: 0] > firstAppear { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(workspace.runtime === initialRuntime && WorkspaceViewReceipts.appeared[ObjectIdentifier(initialRuntime), default: 0] > firstAppear,
            "Window reattachment did not reopen the actual same-runtime MainWindow")
        try await waitForView(workspace)
        print("PASS: actual shipping MainWindow owned window detach/reattach retains accounts, rebinds ending and keeps managed-start/recovery gates open; capture explicitly suppressed")
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
        try await applyWithView(workspace)
        try require(workspace.selection != first, "Apply did not select the new show")
        try require(workspace.runtime.sceneStore.scenes[0].name != "First Show Camera", "Scene data leaked between projects")
        firstStore.rename(scene.id, to: "Old Store Late Write")
        firstStore.flushPendingWrites()
        try require(workspace.runtime.sceneStore.scenes[0].name != "Old Store Late Write", "Old object writes crossed project directory")
        workspace.stage(project: first.project, profile: first.profile)
        try await applyWithView(workspace)
        try require(workspace.runtime.sceneStore.scenes[0].name == "Old Store Late Write", "Persisted project did not reload")
        workspace.addProfile(named: "Duplicate Profile", duplicate: true)
        try await applyWithView(workspace)
        try require(workspace.runtime.sceneStore.scenes[0].name == "Old Store Late Write", "Profile duplicate lost scenes")

        // The actual switch retires its runtime before preparing the destination.
        // A regular file at our new profile path must fail that preparation and
        // leave the selected context operational through a fresh runtime.
        let retainedSelection = workspace.selection
        let retainedDirectory = workspace.directory(for: retainedSelection)
        let retired = workspace.runtime
        let retiredAccountsRevision = retired.providerAccounts.managedReadRevision
        let retiredBinding = retired.recoveryBinding
        workspace.addProfile(named: "Blocked Preparation", duplicate: false)
        let blockedSelection = try workspace.pending.unwrap("Failed-switch profile was not staged")
        let blockedDirectory = workspace.directory(for: blockedSelection)
        try require(blockedDirectory != retainedDirectory, "Fixture must not replace the selected directory")
        try FileManager.default.removeItem(at: blockedDirectory)
        let marker = Data("owned-workspace-preparation-blocker".utf8)
        try marker.write(to: blockedDirectory)
        defer { if (try? Data(contentsOf: blockedDirectory)) == marker { try? FileManager.default.removeItem(at: blockedDirectory) } }
        try await applyWithView(workspace)
        try require(retired.providerAccounts.managedReadRevision != retiredAccountsRevision,
            "Failure fixture did not exercise actual retirement of the old account session")
        try require(workspace.selection == retainedSelection && workspace.pending == blockedSelection
            && DesktopStorage.projectDirectory == retainedDirectory, "Failed preparation lost the selected profile/captured storage path")
        try require(workspace.runtime !== retired && workspace.runtime.controller !== retired.controller
            && workspace.runtime.providerAccounts !== retired.providerAccounts, "Failed preparation reused the retired runtime")
        try require(!workspace.isSwitching && workspace.canSwitch && workspace.error?.isEmpty == false,
            "Failed preparation stranded the switching guard or omitted its error")
        try require(try Data(contentsOf: blockedDirectory) == marker, "Failed preparation removed the blocking file")
        let reopened = workspace.runtime
        try require(!reopened.controller.outputSessionActive && !reopened.controller.isPreviewing
            && !reopened.recorder.state.isActive && !reopened.controller.secondaryRecorder.state.isActive
            && reopened.controller.destinationOutputs.states.isEmpty, "Failed preparation started output/capture")
        try require(reopened.recoveryBinding != nil && reopened.recoveryBinding !== retiredBinding
            && StudioAutomationEndpoint.shared.isBound
            && StudioAutomationEndpoint.shared.currentProfile?.id == retainedSelection.profile.uuidString,
            "Failed preparation did not bind the fresh runtime/recovery context")
        let reopenedScene = reopened.sceneStore.scenes[0]
        let rename = reopened.dispatcher.execute(.renameScene(reopenedScene.id, to: "After Failed Switch"))
        try require(rename.error == nil && rename.state.scenes.contains { $0.id == reopenedScene.id && $0.name == "After Failed Switch" },
            "Reopened runtime dispatcher was not usable")
        reopened.flush()
        let reopenedDocument = try JSONDecoder().decode(SceneDocument.self,
            from: Data(contentsOf: retainedDirectory.appendingPathComponent("stream.scenes.v2.json")))
        try require(reopenedDocument.scenes.contains { $0.id == reopenedScene.id && $0.name == "After Failed Switch" },
            "Reopened runtime did not write to its retained selected directory")
        reopened.chat.receive(try JSONSerialization.data(withJSONObject: ["action": "event", "timestamp": 1_800_000_001,
            "payload": ["connectionIdentifier": "fixture/reopened", "eventTypeId": 5,
                "eventPayload": ["liveChatMessageId": "reopened", "text": "Reopened public fixture", "author": ["displayName": "Producer"]]]]))
        try require(reopened.chat.queue.messages.count == 1, "Reopened chat session was not usable")
        reopened.recoveryBinding?.checkpoint()
        await workspace.recovery.flush()
        let retainedSnapshot = try JSONDecoder().decode(SessionRecoverySnapshot.self,
            from: Data(contentsOf: root.appendingPathComponent("SessionRecovery/current.v1.json")))
        try require(retainedSnapshot.projectID == retainedSelection.project && retainedSnapshot.profileID == retainedSelection.profile
            && retainedSnapshot.stagedSceneID == reopened.previewProgram.stagedScene?.id.rawValue,
            "Reopened recovery binding failed to checkpoint the retained context")
        // Remove only our known regular file; real prepare/switch can now retry.
        try FileManager.default.removeItem(at: blockedDirectory)
        try await applyWithView(workspace)
        try require(workspace.selection == blockedSelection && workspace.pending == nil && !workspace.isSwitching
            && workspace.runtime !== reopened && DesktopStorage.projectDirectory == blockedDirectory && workspace.error == nil,
            "Recovered switch did not retry successfully after the owned blocker was removed")
        try require(!workspace.runtime.controller.outputSessionActive && !workspace.runtime.recorder.state.isActive,
            "Retry started an output")
        workspace.stage(project: retainedSelection.project, profile: retainedSelection.profile)
        try await applyWithView(workspace)
        try require(workspace.selection == retainedSelection && workspace.runtime.sceneStore.scenes[0].name == "After Failed Switch",
            "A later successful switch lost the recovered profile's persisted edit")
        print("PASS: actual failed profile-directory preparation retires old account session, retains selection/path, rebuilds usable dispatcher/chat/recovery runtime, clears switch guard and retries after owned file cleanup with no outputs")

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
        let retiredRestart = restarted.runtime
        host.rootView = WorkspaceApplicationRoot(workspace: restarted)
        try await waitForView(restarted)
        let recovery = try restarted.sceneRecovery.unwrap("Corrupt scenes did not offer backup recovery")
        try require(!restarted.runtime.controller.streamState.isActive && !restarted.runtime.recorder.state.isActive, "Recovery started an output")
        let preserved = try FileManager.default.contentsOfDirectory(at: selectedDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("corrupt") }
        try require(preserved.contains { (try? Data(contentsOf: $0)) == Data("truncated-scene-document".utf8) }, "Corrupt original was not preserved")
        restarted.error = "Fixture previous restore error"
        await restarted.restore(recovery)
        try await waitForView(restarted, retired: retiredRestart)
        try require(restarted.sceneRecovery == nil, "Successful restore kept recovery pending")
        try require(restarted.error == nil, "Successful restore kept the previous error banner")
        try require(restarted.runtime.sceneStore.scenes.map(\.name) == recovery.document.scenes.map(\.name), "Accepted backup did not restore scenes")
        print("PASS: actual shipping App root identity/environment chain recreates MainWindow across profile apply, same-profile failed preparation fallback and backup restore; old disappear cannot retire new accounts/managed start")
        await RecordingTerminationDelegate.finishSession?()
        print("PASS: shared chat staging/Take, recovery binding and attached library, project/profile switching, captured store paths, duplication, package preview, consistent ID remapping and packaged LUT bytes")
        print("Qualification: shipping Workspace switching/recovery logic; temporary machine/project/preferences and generated credential/microphone/legacy-migration boundaries; no operator credentials, real capture or provider calls")
    }
}

private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let value = self else { throw NSError(domain: "WorkspaceHarness", code: 2, userInfo: [NSLocalizedDescriptionKey: message]) }
        return value
    }
}
