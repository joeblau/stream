import AppKit
import CryptoKit
import Foundation
import StreamCore

private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw NSError(domain: "PortableNativeDriver", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@main @MainActor struct PortableShowNativeDriver {
    static var ownedApplication: NSRunningApplication?
    static var receiptDirectory: URL!
    static func main() {
        setbuf(stdout, nil)
        guard CGSessionCopyCurrentDictionary() != nil else { print("UNQUALIFIED: native package entry needs a logged-in WindowServer"); exit(77) }
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("FAIL: \(error.localizedDescription)"); ownedApplication?.forceTerminate(); exit(1) }
        }
        app.run()
    }
    static func run() async throws {
        guard CommandLine.arguments.count == 3 else { throw NSError(domain: "PortableNativeDriver", code: 2) }
        let appURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
        let identifier = info["CFBundleIdentifier"] as! String
        try require(identifier.hasPrefix("com.joeblau.Stream.fixture.portable."), "Refusing to launch an app outside our generated fixture identity")
        // LaunchServices open-file delivery targets the canonical instance.
        // An LS-launched forced-new instance can acknowledge launch while file
        // events go to a different instance; that does not qualify this app.
        for previous in NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            where previous.bundleURL?.resolvingSymlinksInPath() == appURL {
            previous.terminate()
            for _ in 0..<500 {
                if previous.isTerminated { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            if !previous.isTerminated { previous.forceTerminate() }
        }
        receiptDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/\(identifier)/Data/Library/Application Support/StreamPortableFixture", isDirectory: true)
        let outside = root.appendingPathComponent("owned-outside-denied.txt")
        try Data("Owned sandbox denial fixture".utf8).write(to: outside)
        let repair = root.appendingPathComponent("owned-repair.png")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1p8AAAAASUVORK5CYII=")!
        try png.write(to: repair)
        let copyID = AssetID(), linkID = AssetID()
        let layer = LayerNode(name: "Transferred text", payload: .text(TextSourcePayload(text: "Owned native package")), transform: .fullscreen)
        var document = SceneDocument.makeDefault()
        let scene = Scene(name: "Native Imported Scene", layers: [layer])
        document.scenes = [scene]; document.selectedID = scene.id
        var effects = SourceEffects(); effects.lut.assetID = copyID
        document.scenes[0].layers[0].effectOverrides = effects
        let cube = Data((["LUT_3D_SIZE 2"] + (0..<8).map { "\($0 % 2) \(($0 / 2) % 2) \($0 / 4)" }).joined(separator: "\n").utf8)
        let cubeURL = root.appendingPathComponent("owned-look.cube"); try cube.write(to: cubeURL)
        let cubePath = "Assets/\(copyID)/owned-look.cube"
        let assets = AssetLibraryDocument(assets: [
            LibraryAsset(id: copyID, name: "Owned LUT", kind: .other, storage: .projectCopy, relativePath: cubePath, fileName: "owned-look.cube", lastKnownPath: ""),
            LibraryAsset(id: linkID, name: "Missing linked PNG", kind: .image, storage: .linked,
                bookmarkData: Data("fixture-bookmark-sentinel".utf8), fileName: "owned-repair.png", lastKnownPath: repair.path)
        ])
        let secret = "fixture-secret-must-not-transfer"
        let documents: [String: Data] = ["stream.scenes.v2.json": try JSONEncoder().encode(document),
            "stream.assets.v1.json": try JSONEncoder().encode(assets),
            "desktop.settings.v1.json": try JSONSerialization.data(withJSONObject: ["streamKey": secret, "rtmpURL": "rtmp://127.0.0.1/private", "token": secret, "bookmarkData": "fixture-bookmark-sentinel"])]
        let package = root.appendingPathComponent("Owned Native.streamshow", isDirectory: true)
        try ShowPackageIO.export(documents: documents,
            media: [.init(access: ResolvedAssetAccess(url: cubeURL, needsSecurityScope: false), relativePath: cubePath)],
            name: "Native Imported Show", includeMedia: true, to: package)
        let initialFiles = try packageBytes(package)
        for (_, bytes) in initialFiles {
            let text = String(decoding: bytes, as: UTF8.self)
            try require(!text.contains(secret) && !text.contains("127.0.0.1") && !text.contains("fixture-bookmark-sentinel") && !text.contains(repair.path),
                "Portable package persisted fixture credentials, private endpoint or machine grant")
        }
        let launch = NSWorkspace.OpenConfiguration()
        launch.addsToRecentItems = false
        launch.environment = ["STREAM_PORTABLE_OUTSIDE": outside.path]
        ownedApplication = try await NSWorkspace.shared.openApplication(at: appURL, configuration: launch)
        print("Stage: launched owned shipping sandbox app PID \(ownedApplication!.processIdentifier)")
        try require(ownedApplication?.bundleURL?.resolvingSymlinksInPath() == appURL, "LaunchServices returned another app")
        defer { ownedApplication?.terminate() }
        var ready = try await wait(phase: "ready")
        try require(ready.outsideDenied, "Actual sandbox enforcement was not proved")
        ready = try await command("inspect")
        try require(ready.outputsIdle && ready.rootAppeared, "Shipping App root did not appear without outputs/capture")
        for _ in 0..<300 {
            if ownedApplication?.isFinishedLaunching == true && ready.studioWindowVisible { break }
            ready = try await command("inspect")
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(ownedApplication?.isFinishedLaunching == true && ready.studioWindowVisible && ready.studioWindows == 1,
            "Actual shipping studio window was not visible after native application launch completed")
        print("Stage: actual native launch finished with one visible owned Studio window")
        let initialProject = ready.project
        let open = NSWorkspace.OpenConfiguration(); open.addsToRecentItems = false
        open.environment = launch.environment
        print("Stage: sending actual LaunchServices package delivery")
        let delivered = try await NSWorkspace.shared.open([package], withApplicationAt: appURL, configuration: open)
        print("Stage: LaunchServices delivery returned PID \(delivered.processIdentifier)")
        try require(delivered.processIdentifier == ownedApplication?.processIdentifier,
            "Open-file delivery targeted another instance of the owned fixture")
        var preview: PortableNativeReport?
        for _ in 0..<100 {
            let state = try await command("inspect")
            if portableSameFile(state.previewPath, package.path) && state.previewName == "Native Imported Show" { preview = state; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let preview else { throw NSError(domain: "PortableNativeDriver", code: 3, userInfo: [NSLocalizedDescriptionKey: "Actual LaunchServices open-file did not reach shipping package receiver/preview"]) }
        try require(preview.project == initialProject && preview.pendingProject == nil && preview.previewDeliveries == 1 && preview.studioWindows == 1,
            "Open-file duplicated preview, imported or switched before explicit confirmation")
        // The event has returned before detached preview IO and explicit import.
        // No fixture package access lease extends the native grant lifetime.
        try await Task.sleep(for: .milliseconds(1_250))
        let imported = try await command("import")
        try require(imported.project == initialProject && imported.pendingProject != nil && imported.projectCount == ready.projectCount + 1,
            "Explicit import did not stage a separate conflict-free project")
        let applied = try await command("apply")
        try require(applied.project == imported.pendingProject && applied.outputsIdle && applied.studioWindows == 1 && applied.sceneIDs.count == 1
            && applied.sceneIDs[0] != scene.id.rawValue && applied.assetIDs.count == 2 && !applied.assetIDs.contains(copyID.rawValue)
            && !applied.assetIDs.contains(linkID.rawValue) && applied.includedBytes == cube && !applied.linkedReadable,
            "Actual sandbox Apply lost remapped identities, included bytes or missing-link state")
        print("PASS: actual signed sandbox denies owned outside read; LaunchServices→shipping public event intake→shipping preview→explicit new-project import/Apply; remapped scene/assets/LUT bytes, private configuration redaction and idle outputs")
        _ = try await NSWorkspace.shared.open([package], withApplicationAt: appURL, configuration: open)
        var rebound: PortableNativeReport?
        for _ in 0..<100 {
            let state = try await command("inspect")
            if portableSameFile(state.previewPath, package.path) && state.previewDeliveries == 2 { rebound = state; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try require(rebound?.project == applied.project && rebound?.pendingProject == nil && rebound?.studioWindows == 1,
            "New runtime root lost native file binding or duplicated its preview/window")
        _ = try await command("cancelPreview")
        let dropped = try await command("drop")
        try require(dropped.previewName == "Native Drop Show" && dropped.project == applied.project && dropped.pendingProject == nil,
            "Actual NSItemProvider did not reach shipping drop/preview boundary")
        let duplicate = try await command("import")
        try require(duplicate.pendingProject != applied.project && duplicate.projectCount == applied.projectCount + 1,
            "Repeated import overwrote the current show instead of handling conflict separately")
        // Keep the linked-resource project selected; drop import merely stages
        // another show and never implicitly retires this runtime.
        _ = try await command("cancelPreview")
        let chooser = try await command("chooser", path: package.path)
        let chooserQualified = chooser.phase == "ack" && portableSameFile(chooser.previewPath, package.path)
        print(chooserQualified ? "PASS: real shipping NSOpenPanel selected the owned package via local event dispatch" : "UNQUALIFIED: remote native chooser selection; actual panel cancelled/aborted, no fabricated success")
        _ = try await command("cancelPreview")
        _ = try await NSWorkspace.shared.open([repair], withApplicationAt: appURL, configuration: open)
        let linked = try await command("relinkOpened", path: repair.path)
        try require(linked.scopeGranted && linked.linkedReadable && linked.project == applied.project,
            "Shipping relink could not persist/read a real LaunchServices user-selected grant")
        print("PASS: actual native file grant→shipping missing-linked-asset repair→app-scope bookmark; chooser UI qualification remains separate")
        for _ in 0..<2 { _ = try await NSWorkspace.shared.open([repair], withApplicationAt: appURL, configuration: open) }
        var ignored = linked
        for _ in 0..<100 {
            ignored = try await command("inspect")
            if ignored.repairDeliveries == 3 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try require(ignored.repairDeliveries == 3 && ignored.previewPath == nil && ignored.studioWindows == 1
            && ignored.project == applied.project && ignored.outputsIdle,
            "Repeated actual non-package events closed the studio or staged a package")
        _ = try await command("quit")
        for _ in 0..<500 {
            if ownedApplication?.isTerminated == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(ownedApplication?.isTerminated == true, "Owned fixture app did not quit within five seconds")
        ownedApplication = try await NSWorkspace.shared.openApplication(at: appURL, configuration: launch)
        let restart = try await wait(phase: "ready")
        try require(restart.outsideDenied, "Cold sandbox restart unexpectedly read an unrelated ungranted sibling")
        let restored = try await command("inspect")
        try require(restored.project == applied.project && restored.sceneIDs == applied.sceneIDs && restored.assetIDs == applied.assetIDs
            && restored.linkedReadable && restored.includedBytes == cube && restored.outputsIdle,
            "Cold restart lost imported selection, remapped IDs, included asset or actual scoped bookmark")
        try require(try packageBytes(package) == initialFiles, "Native import/relink modified the transferred source package")
        _ = try await command("quit")
        print("PASS: real sandbox cold restart reopens persisted show/profile/assets and readable app-scope linked bookmark; source package byte-identical")
        for _ in 0..<500 {
            if ownedApplication?.isTerminated == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(ownedApplication?.isTerminated == true, "Restarted owned app did not finish native Quit")
        ownedApplication = try await NSWorkspace.shared.open([package], withApplicationAt: appURL, configuration: launch)
        _ = try await wait(phase: "ready")
        var coldPreview: PortableNativeReport?
        for _ in 0..<100 {
            let state = try await command("inspect")
            if portableSameFile(state.previewPath, package.path) { coldPreview = state; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try require(coldPreview?.project == applied.project && coldPreview?.pendingProject == nil
            && coldPreview?.previewDeliveries == 1 && coldPreview?.studioWindows == 1 && coldPreview?.outputsIdle == true,
            "Actual cold LaunchServices open-file did not reach one preview/current workspace without implicit import")
        _ = try await command("cancelPreview")
        let secondPackage = root.appendingPathComponent("Second Owned.streamshow", isDirectory: true)
        try FileManager.default.copyItem(at: package, to: secondPackage)
        _ = try await NSWorkspace.shared.open([package, secondPackage], withApplicationAt: appURL, configuration: launch)
        var rejected = try await command("inspect")
        for _ in 0..<100 {
            if rejected.error == "Open one show package at a time." { break }
            try await Task.sleep(for: .milliseconds(20))
            rejected = try await command("inspect")
        }
        try require(rejected.error == "Open one show package at a time." && rejected.previewPath == nil
            && rejected.pendingProject == nil && rejected.project == applied.project && rejected.studioWindows == 1,
            "Actual multi-package delivery was not bounded/rejected without changing selection")
        _ = try await command("quit")
        for _ in 0..<500 {
            if ownedApplication?.isTerminated == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(ownedApplication?.isTerminated == true, "Cold open-file app did not finish native Quit")
        print("PASS: actual NSWorkspace cold open-file launch reaches one preview in the retained selected project and one owned Studio window")
        print("PASS: actual new-runtime binding, repeated non-package delivery and multi-package rejection preserve one studio/current selection")
        print("Owned app container retained: \(receiptDirectory.path)")
        print("Actual physical Finder double-click/pointer drag and remote chooser selection are independent limits; NSItemProvider proof is typed delivery, not a pointer gesture")
    }
    static func command(_ action: String, path: String? = nil) async throws -> PortableNativeReport {
        let request = PortableNativeCommand(id: UUID(), action: action, path: path)
        if action != "inspect" { print("Stage: native command \(action), \(request.id)") }
        try JSONEncoder().encode(request).write(to: receiptDirectory.appendingPathComponent("command.json"), options: .atomic)
        return try await wait(id: request.id)
    }
    static func wait(id: UUID? = nil, phase: String? = nil) async throws -> PortableNativeReport {
        for _ in 0..<1_200 {
            try require(ownedApplication?.isTerminated != true, "Owned app terminated before its native receipt")
            if let data = try? Data(contentsOf: receiptDirectory.appendingPathComponent("report.json")),
               let report = try? JSONDecoder().decode(PortableNativeReport.self, from: data), report.pid == ownedApplication?.processIdentifier {
                try require(report.phase != "failed", report.error ?? "Owned native app failed")
                if (phase == nil || phase == report.phase), (id == nil || report.id == id) { return report }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let latest = (try? Data(contentsOf: receiptDirectory.appendingPathComponent("report.json")))
            .flatMap { try? JSONDecoder().decode(PortableNativeReport.self, from: $0) }
        throw NSError(domain: "PortableNativeDriver", code: 4, userInfo: [NSLocalizedDescriptionKey:
            "Owned app receipt exceeded12-second bound (latest phase=\(latest?.phase ?? "none"), busy=\(latest?.packageBusy ?? false), error=\(latest?.error ?? "none"))"])
    }
    static func packageBytes(_ root: URL) throws -> [String: Data] {
        var values: [String: Data] = [:]
        let urls = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let url as URL in urls where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            values[String(url.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: url)
        }
        return values
    }
}
