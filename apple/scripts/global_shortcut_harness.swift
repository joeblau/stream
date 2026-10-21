import AppKit
import Carbon
import Foundation

// Only the catalog descriptor/storage path are bridged. Carbon registration,
// double opt-in, availability and teardown use the shipping controller.
struct StudioPaletteAction { let id: String; var unavailableReason: String? }
@MainActor enum DesktopStorage {
    static var projectDirectory: URL { FileManager.default.temporaryDirectory }
}
private struct Unqualified: Error { let message: String }

@MainActor private final class ForegroundDelegate: NSObject, NSApplicationDelegate {
    let previous: NSRunningApplication?
    init(previousPID: pid_t) { previous = NSRunningApplication(processIdentifier: previousPID) }
    func applicationWillTerminate(_ notification: Notification) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), let previous {
            NSApp.yieldActivation(to: previous)
            previous.activate(options: [])
        }
    }
}

@MainActor private final class ForegroundView: NSView {
    var destination: URL!
    var events = 0
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        events += 1
        try? Data(String(events).utf8).write(to: destination, options: .atomic)
    }
}

@main @MainActor struct GlobalShortcutHarness {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "GlobalShortcutHarness", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func wait(_ message: String, until ready: () -> Bool) async throws {
        for _ in 0..<300 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(false, message)
    }
    static func foreground(_ directory: URL, previousPID: pid_t) {
        let delegate = ForegroundDelegate(previousPID: previousPID)
        NSApp.delegate = delegate
        let window = NSWindow(contentRect: NSRect(x: 140, y: 140, width: 380, height: 140),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Stream owned global shortcut fixture"
        window.isReleasedWhenClosed = false
        let view = ForegroundView(frame: NSRect(x: 0, y: 0, width: 380, height: 140))
        view.destination = directory.appendingPathComponent("events")
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate()
        // The launch-service child has a different process group. Retire it
        // even if its owner crashes or the outer timeout terminates the owner.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { NSApp.terminate(nil) }
        try? Data("ready".utf8).write(to: directory.appendingPathComponent("ready"), options: .atomic)
        // Retain both until the process is terminated by its owner.
        withExtendedLifetime((window, delegate)) { NSApp.run() }
    }
    static func send(to process: NSRunningApplication, repeated: Bool = false,
                     flags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]) async throws {
        guard !process.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier else {
            throw Unqualified(message: "Owned foreground fixture lost focus; no input posted")
        }
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 25, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 25, keyDown: false) else {
            throw Unqualified(message: "WindowServer could not construct owned keyboard events")
        }
        down.flags = flags
        up.flags = down.flags
        down.post(tap: .cghidEventTap)
        if repeated {
            down.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
            down.post(tap: .cghidEventTap)
            down.post(tap: .cghidEventTap)
        }
        // Always release this chord, including if the operator changes focus.
        up.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(180))
    }
    static func run() async throws {
        guard CGPreflightPostEventAccess() else {
            throw Unqualified(message: "Existing event-post access is required; no permission request made")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stream-global-shortcut-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaultsName = "stream.global-shortcut.\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: directory)
        }
        let commandID = "scene.\(UUID()).select"
        var document = StudioShortcutDocument()
        try check(document.assign(commandID: commandID,
            chord: StudioKeyChord(keyCode: 25, modifiers: 7, keyLabel: "9"), global: true) == nil,
            "Fixture chord was rejected")
        let url = directory.appendingPathComponent("shortcuts.json")
        try JSONEncoder().encode(document).write(to: url)
        let controller = StudioShortcutController(url: url, defaults: defaults)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var available = true
        var emitted: [String] = []
        controller.actions = { [StudioPaletteAction(id: commandID, unavailableReason: available ? nil : "Disconnected")] }
        controller.onExecute = { emitted.append($0.id) }
        controller.install(window: window)
        defer { controller.uninstall(); window.close() }
        let previous = NSWorkspace.shared.frontmostApplication
        let bundle = directory.appendingPathComponent("ForegroundFixture.app")
        let executable = bundle.appendingPathComponent("Contents/MacOS/ForegroundFixture")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL, to: executable)
        let info: [String: Any] = ["CFBundleIdentifier": "stream.global-shortcut.foreground.\(UUID().uuidString)",
            "CFBundleName": "Stream Shortcut Fixture", "CFBundleExecutable": "ForegroundFixture", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--foreground-fixture", directory.path, String(previous?.processIdentifier ?? 0)]
        configuration.activates = true
        let helper: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { application, error in
                if let application { continuation.resume(returning: application) }
                else { continuation.resume(throwing: error ?? Unqualified(message: "Owned application launch failed")) }
            }
        }
        defer {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == helper.processIdentifier {
                previous?.activate(options: [])
            }
            helper.terminate()
        }
        try await wait("Owned helper did not become foreground", until: {
            !helper.isTerminated && FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready").path)
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == helper.processIdentifier
        })
        try await send(to: helper)
        try check(emitted.isEmpty, "Per-binding opt-in bypassed disabled global master")
        controller.setGlobalEnabled(true)
        guard controller.globalErrors.isEmpty else {
            throw Unqualified(message: "Fixture chord is owned by another application: \(controller.globalErrors)")
        }
        try await send(to: helper, repeated: true)
        try await wait("Actual background Carbon hotkey did not dispatch", until: { emitted.count == 1 })
        try check(emitted == [commandID] && !NSApp.isActive, "Repeated chord dispatched more than once or activated studio")
        try await send(to: helper)
        try check(emitted.count == 2, "Key release did not permit a fresh press")
        let eventsURL = directory.appendingPathComponent("events")
        let priorEvents = (try? String(contentsOf: eventsURL, encoding: .utf8)).flatMap(Int.init) ?? 0
        try await send(to: helper, flags: [])
        let currentEvents = (try? String(contentsOf: eventsURL, encoding: .utf8)).flatMap(Int.init) ?? 0
        try check(currentEvents == priorEvents + 1 && emitted.count == 2,
                  "Global registration intercepted ordinary input in the owned foreground app")
        available = false
        try await send(to: helper)
        try check(emitted.count == 2 && controller.message == "Disconnected", "Global dispatch ignored current availability")
        available = true
        try await Task.sleep(for: .milliseconds(180))
        try check(emitted.count == 2, "Availability recovery replayed a stale press")
        try await send(to: helper)
        try check(emitted.count == 3, "Fresh press after availability recovery failed")
        controller.palettePresented = true
        try await send(to: helper)
        try check(emitted.count == 3, "Presented palette accepted a background production command")
        controller.palettePresented = false
        controller.setGlobalEnabled(false)
        try await send(to: helper)
        try check(emitted.count == 3, "Disabled master retained an active Carbon registration")
        controller.setGlobalEnabled(true)
        controller.uninstall()
        try await send(to: helper)
        try check(emitted.count == 3, "Uninstalled controller retained a Carbon registration")
        print("PASS: actual background Carbon registration/double opt-in, repeated press/release, ordinary foreground input, live availability/no replay, palette guard, master disable and uninstall using only owned foreground process")
        print("Qualification: synthetic WindowServer events; physical keyboard, arbitrary third-party foreground apps and full studio accessibility remain open")
    }
    static func main() {
        setbuf(stdout, nil)
        let application = NSApplication.shared
        application.setActivationPolicy(CommandLine.arguments.contains("--foreground-fixture") ? .regular : .accessory)
        application.finishLaunching()
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--foreground-fixture" {
            foreground(URL(fileURLWithPath: CommandLine.arguments[2]), previousPID: pid_t(CommandLine.arguments[3]) ?? 0); return
        }
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch let error as Unqualified { print("UNQUALIFIED: \(error.message)"); exit(77) }
            catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
        }
        application.run()
    }
}
