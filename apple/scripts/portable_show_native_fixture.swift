import AppKit
import Foundation
import StreamCore
import UniformTypeIdentifiers

// Foundation can spell the same vnode with /tmp or /private/tmp. Compare the
// owned existing file identity; preserve the original scoped URL for access.
func portableSameFile(_ lhs: String?, _ rhs: String?) -> Bool {
    guard let lhs, let rhs,
          let first = try? FileManager.default.attributesOfItem(atPath: lhs),
          let second = try? FileManager.default.attributesOfItem(atPath: rhs),
          let firstDevice = first[.systemNumber] as? NSNumber, let secondDevice = second[.systemNumber] as? NSNumber,
          let firstInode = first[.systemFileNumber] as? NSNumber, let secondInode = second[.systemFileNumber] as? NSNumber else { return false }
    return firstDevice == secondDevice && firstInode == secondInode
}

// Included only by the generated, uniquely signed native fixture app/tool.
enum GuestFixtureDefaults {
    static let name = (Bundle.main.bundleIdentifier ?? "com.joeblau.Stream.fixture.portable.driver") + ".preferences"
    nonisolated(unsafe) static let value: UserDefaults = {
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(true, forKey: "onboarding.hasCompletedFirstRun")
        return defaults
    }()
}
enum GuestFixtureStorage {
    static let fixtureDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("StreamPortableFixture", isDirectory: true)
    static let recordingsDirectory = fixtureDirectory.appendingPathComponent("Recordings", isDirectory: true)
    static let machineDirectory: URL = {
        let root = fixtureDirectory.appendingPathComponent("Studio", isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent("projects.v1.json").path) {
            let catalog = StudioProjectCatalog()
            let selected = root.appendingPathComponent(StudioProjectCatalog.relativeDirectory(
                project: catalog.selectedProjectID, profile: catalog.selectedProfileID), isDirectory: true)
            try! FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
            try! JSONEncoder().encode(catalog).write(to: root.appendingPathComponent("projects.v1.json"), options: .atomic)
        }
        return root
    }()
}

struct PortableNativeCommand: Codable {
    var id: UUID
    var action: String
    var path: String?
}
struct PortableNativeReport: Codable {
    var pid: Int32 = ProcessInfo.processInfo.processIdentifier
    var id: UUID?
    var phase: String
    var error: String?
    var project: UUID?
    var pendingProject: UUID?
    var projectCount = 0
    var sceneIDs: [UUID] = []
    var assetIDs: [UUID] = []
    var includedBytes: Data?
    var previewPath: String?
    var previewName: String?
    var outputsIdle = false
    var rootAppeared = false
    var outsideDenied = false
    var scopeGranted = false
    var linkedReadable = false
    var packageBusy = false
    var previewDeliveries = 0
    var repairDeliveries = 0
    var studioWindows = 0
    var studioWindowVisible = false
}

@MainActor enum PortableNativeAppDriver {
    static var task: Task<Void, Never>?
    static var previewSuppressed = 0
    static var rootAppeared = false
    static var outsideDenied = false
    static var scopeGranted = false
    static var openedRepair: URL?
    static var lifecycleTrace: Timer?
    static var closeTrace: NSObjectProtocol?
    static var deliveries: [String: Int] = [:]
    static let folder = GuestFixtureStorage.fixtureDirectory
    static func terminating() {
        try? JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier,
            "stack": Thread.callStackSymbols]).write(to: folder.appendingPathComponent("termination-trace.json"), options: .atomic)
    }
    static func received(_ url: URL) {
        // Observe actual delivery. Package URLs get no additional fixture scope
        // or lease that could hide a shipping preview/import lifetime defect.
        if url.pathExtension.lowercased() == "png" { openedRepair = url }
        deliveries[url.path, default: 0] += 1
        try? JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier, "path": url.path])
            .write(to: folder.appendingPathComponent("open-receipt.json"), options: .atomic)
    }
    static func attach(_ workspace: StudioWorkspace) {
        rootAppeared = true
        guard task == nil else { return }
        closeTrace = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let window, window.title == "Stream Studio" else { return }
                let list = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: 0x2d2d2d2d)
                let files = (1...max(1, min(8, list?.numberOfItems ?? 0))).compactMap { index -> String? in
                    guard let value = list?.atIndex(index)?.coerce(toDescriptorType: 0x6675726c)?.stringValue else { return nil }
                    return value.contains("stream-portable-") ? value : "non-fixture URL redacted"
                }
                try? JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier,
                    "files": files, "stack": Thread.callStackSymbols]).write(to: folder.appendingPathComponent("window-close-trace.json"), options: .atomic)
            }
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                let trace: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                    "modal": NSApp.modalWindow?.className ?? "none", "key": NSApp.keyWindow?.className ?? "none",
                    "active": NSApp.isActive,
                    "windows": NSApp.windows.map { ["class": $0.className, "title": $0.title,
                        "visible": $0.isVisible, "key": $0.isKeyWindow, "sheet": $0.attachedSheet?.className ?? "none"] }]
                try? JSONSerialization.data(withJSONObject: trace).write(to: folder.appendingPathComponent("lifecycle-trace.json"), options: .atomic)
            }
        }
        lifecycleTrace = timer
        RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        task = Task { await run(workspace) }
    }
    static func run(_ workspace: StudioWorkspace) async {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let outside = ProcessInfo.processInfo.environment["STREAM_PORTABLE_OUTSIDE"] else { throw Failure.message("Missing owned outside-file probe") }
            do { _ = try Data(contentsOf: URL(fileURLWithPath: outside)) }
            catch let error as NSError {
                outsideDenied = error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError
            }
            guard outsideDenied else { throw Failure.message("Sandbox did not deny the owned outside file before a native grant") }
            try write(report(workspace, id: nil, phase: "ready"))
            var last = (try? Data(contentsOf: folder.appendingPathComponent("command.json")))
                .flatMap { try? JSONDecoder().decode(PortableNativeCommand.self, from: $0) }?.id
            let deadline = Date().addingTimeInterval(110)
            while Date() < deadline {
                if let data = try? Data(contentsOf: folder.appendingPathComponent("command.json")), data.count < 65_536,
                   let command = try? JSONDecoder().decode(PortableNativeCommand.self, from: data), command.id != last {
                    last = command.id
                    do {
                        switch command.action {
                        case "inspect": break
                        case "cancelPreview": workspace.importPreview = nil
                        case "import": await workspace.importPreviewedPackage()
                        case "apply": await workspace.applyPending()
                        case "drop":
                            let source = folder.appendingPathComponent("OwnedDrop-\(UUID()).streamshow", isDirectory: true)
                            try ShowPackageIO.export(documents: ["stream.scenes.v2.json": JSONEncoder().encode(workspace.runtime.sceneStore.document)],
                                media: [], name: "Native Drop Show", includeMedia: false, to: source)
                            let provider = NSItemProvider()
                            provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
                                completion(source.dataRepresentation, nil); return nil
                            }
                            guard workspace.acceptPackageDrop([provider]) else { throw Failure.message("Shipping drop rejected a real NSItemProvider file URL") }
                            try await waitPreview(workspace, path: source.path)
                        case "chooser":
                            guard let path = command.path else { throw Failure.message("Missing owned chooser path") }
                            let driver = OwnedPanelDriver(path: path)
                            driver.start()
                            workspace.choosePackage() // Real shipping NSOpenPanel.runModal.
                            driver.stop()
                            if workspace.packageBusy { try await waitPreview(workspace, path: path) }
                            guard portableSameFile(workspace.importPreview?.url.path, path) else {
                                try write(report(workspace, id: command.id, phase: "chooser-unqualified",
                                    error: "Real native chooser did not select the owned file through local public event dispatch"))
                                continue
                            }
                        case "relink":
                            guard let path = command.path,
                                  let asset = workspace.runtime.dispatcher.assetLibrary.assets.first(where: { $0.storage == .linked }) else { throw Failure.message("No imported missing linked asset") }
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = false
                            let driver = OwnedPanelDriver(path: path); driver.start()
                            let response = panel.runModal(); driver.stop()
                            guard response == .OK, let url = panel.url, portableSameFile(url.path, path) else {
                                try write(report(workspace, id: command.id, phase: "relink-unqualified",
                                    error: "Actual native picker supplied no owned relink grant")); continue
                            }
                            scopeGranted = url.startAccessingSecurityScopedResource()
                            defer { if scopeGranted { url.stopAccessingSecurityScopedResource() } }
                            guard await workspace.runtime.dispatcher.assetLibrary.relink(asset.id, to: url) else { throw Failure.message("Shipping sandbox relink failed") }
                            workspace.runtime.flush()
                        case "relinkOpened":
                            // LaunchServices completion identifies the process;
                            // its real Apple event may still be queued there.
                            for _ in 0..<300 {
                                if portableSameFile(openedRepair?.path, command.path) { break }
                                try await Task.sleep(for: .milliseconds(10))
                            }
                            guard let url = openedRepair, portableSameFile(url.path, command.path),
                                  let asset = workspace.runtime.dispatcher.assetLibrary.assets.first(where: { $0.storage == .linked }) else {
                                throw Failure.message("Missing actual LaunchServices-delivered owned repair URL")
                            }
                            scopeGranted = url.startAccessingSecurityScopedResource()
                            defer { if scopeGranted { url.stopAccessingSecurityScopedResource() } }
                            guard scopeGranted, await workspace.runtime.dispatcher.assetLibrary.relink(asset.id, to: url) else {
                                throw Failure.message("Shipping relink rejected the actual native file grant")
                            }
                            workspace.runtime.flush()
                        case "quit":
                            workspace.runtime.flush()
                            try write(report(workspace, id: command.id, phase: "quitting"))
                            // AppKit's termination handshake runs a nested
                            // loop. Enter from its native run loop, as the Quit
                            // menu does, so queued MainActor finalization can
                            // execute after this command task returns.
                            let timer = Timer(timeInterval: 0.01, repeats: false) { _ in
                                MainActor.assumeIsolated { NSApp.terminate(nil) }
                            }
                            RunLoop.main.add(timer, forMode: .common)
                            RunLoop.main.add(timer, forMode: .modalPanel)
                            return
                        default: throw Failure.message("Unknown fixture command")
                        }
                        try write(report(workspace, id: command.id, phase: "ack"))
                    } catch { try write(report(workspace, id: command.id, phase: "failed", error: error.localizedDescription)) }
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw Failure.message("Owned native fixture exceeded its110-second lifetime")
        } catch {
            try? write(report(workspace, id: nil, phase: "failed", error: error.localizedDescription))
            NSApp.terminate(nil)
        }
    }
    static func waitPreview(_ workspace: StudioWorkspace, path: String) async throws {
        for _ in 0..<300 {
            if !workspace.packageBusy && portableSameFile(workspace.importPreview?.url.path, path) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure.message("Actual NSItemProvider preview did not arrive within three seconds")
    }
    static func report(_ workspace: StudioWorkspace, id: UUID?, phase: String, error: String? = nil) -> PortableNativeReport {
        var value = PortableNativeReport(id: id, phase: phase, error: error)
        value.project = workspace.selection.project; value.pendingProject = workspace.pending?.project
        value.projectCount = workspace.catalog.projects.count
        value.sceneIDs = workspace.runtime.sceneStore.scenes.map { $0.id.rawValue }
        value.assetIDs = workspace.runtime.dispatcher.assetLibrary.assets.map { $0.id.rawValue }
        value.previewPath = workspace.importPreview?.url.path; value.previewName = workspace.importPreview?.name
        value.previewDeliveries = value.previewPath.flatMap { deliveries[$0] } ?? 0
        value.repairDeliveries = deliveries.filter { URL(fileURLWithPath: $0.key).pathExtension == "png" }.values.reduce(0, +)
        value.packageBusy = workspace.packageBusy
        value.error = error ?? workspace.error
        value.outputsIdle = !workspace.runtime.controller.isPreviewing && !workspace.runtime.controller.outputSessionActive
            && !workspace.runtime.recorder.state.isActive && !workspace.runtime.controller.secondaryRecorder.state.isActive
        value.rootAppeared = rootAppeared && previewSuppressed > 0; value.outsideDenied = outsideDenied
        let windows = NSApp.windows.filter { $0.title == "Stream Studio" }
        value.studioWindows = windows.count; value.studioWindowVisible = windows.count == 1 && windows[0].isVisible
        value.scopeGranted = scopeGranted
        for asset in workspace.runtime.dispatcher.assetLibrary.assets {
            if let access = workspace.runtime.dispatcher.assetLibrary.access(for: asset.id), access.isAccessible {
                if asset.storage == .projectCopy { value.includedBytes = try? Data(contentsOf: access.url) }
                if asset.storage == .linked { value.linkedReadable = (try? Data(contentsOf: access.url)) != nil }
            }
        }
        return value
    }
    static func write(_ report: PortableNativeReport) throws {
        try JSONEncoder().encode(report).write(to: folder.appendingPathComponent("report.json"), options: .atomic)
    }
    enum Failure: Error, LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
    }
}

/// Public owned-app event dispatch only. No CGEvent, AX, private view-service
/// hooks or manufactured modal response. Cancellation is an explicit failure.
@MainActor private final class OwnedPanelDriver {
    let path: String
    var timers: [Timer] = []
    init(path: String) { self.path = path }
    func later(_ seconds: Double, _ action: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in MainActor.assumeIsolated { action() } }
        timers.append(timer)
        RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
    }
    func start() {
        later(0.5) { Self.key("g", code: 5, flags: [.command, .shift]) }
        later(1) { [path] in
            Self.key("a", flags: [.command])
            for character in path { Self.key(String(character)) }
            Self.key("\r", code: 36)
        }
        later(2) { Self.key("\r", code: 36) }
        later(7) { NSApp.abortModal() }
    }
    func stop() { timers.forEach { $0.invalidate() }; timers.removeAll() }
    static func key(_ text: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) {
        guard let window = NSApp.keyWindow, NSApp.windows.contains(window),
              window === NSApp.modalWindow || window is NSPanel || window.sheetParent != nil,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else { return }
        NSApp.sendEvent(event)
    }
}
