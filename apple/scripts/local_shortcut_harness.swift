import AppKit
import Combine
import Foundation
import StreamCore
import SwiftUI

@MainActor enum ShortcutFixtureDefaults {
    static let name = "stream.local-shortcut-validation.\(UUID())"
    static let value = UserDefaults(suiteName: name)!
}

@MainActor private final class NativeShortcutCanvas: NSView {
    var received = 0
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { received += 1 }
}
@MainActor private final class NativeControlActions: NSObject {
    var submits = 0, presses = 0
    @objc func submit(_ sender: Any?) { submits += 1 }
    @objc func press(_ sender: Any?) { presses += 1 }
}
@MainActor private final class NativeKeyboardButton: NSButton {
    override var acceptsFirstResponder: Bool { true }
}

/// A small host uses the shipping palette sheet and focus hooks. The studio
/// window/catalog/dispatcher are real; no palette selection model is bridged.
private struct NativePaletteSheet: View {
    @ObservedObject var shortcuts: StudioShortcutController
    let actions: @MainActor () -> [StudioPaletteAction]
    var body: some View {
        Text("Shortcut fixture").frame(width: 180, height: 30)
            .sheet(isPresented: $shortcuts.palettePresented, onDismiss: { shortcuts.restoreCommandFocus() }) {
                StudioCommandPalette(shortcuts: shortcuts, actions: actions())
            }
            .onChange(of: shortcuts.palettePresented) { _, shown in
                if shown { shortcuts.rememberCommandFocus() }
            }
    }
}

@main @MainActor struct LocalShortcutHarness {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw NSError(domain: "LocalShortcutHarness", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func wait(_ message: String, until ready: () -> Bool) async throws {
        for _ in 0..<400 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(false, message)
    }
    static func send(_ code: UInt16, _ text: String, flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false, to window: NSWindow) throws {
        let event = try NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: repeatKey, keyCode: code).unwrap("AppKit did not construct a local key event")
        try check(event.window === window, "App-local event did not retain its owned window")
        NSApp.sendEvent(event)
    }
    static func textField(in view: NSView?, placeholder: String) -> NSTextField? {
        guard let view else { return nil }
        if let text = view as? NSTextField, text.placeholderString == placeholder { return text }
        for child in view.subviews { if let field = textField(in: child, placeholder: placeholder) { return field } }
        return nil
    }
    static func run() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stream-local-shortcut-\(UUID())")
        try DesktopStorage.prepare(folder)
        defer { try? FileManager.default.removeItem(at: folder); ShortcutFixtureDefaults.value.removePersistentDomain(forName: ShortcutFixtureDefaults.name) }
        let layer = LayerNode(name: "Fixture shape", payload: .shape(.init(fillColorHex: "#174A69")), transform: .fullscreen)
        let alpha = Scene(name: "Fixture Alpha", layers: [layer]), beta = Scene(name: "Fixture Beta", layers: []), gamma = Scene(name: "Fixture Gamma", layers: [])
        let document = SceneDocument(sources: [], scenes: [alpha, beta, gamma], selectedID: alpha.id)
        try JSONEncoder().encode(document).write(to: folder.appendingPathComponent("stream.scenes.v2.json"))
        try JSONEncoder().encode([StreamDestination]()).write(to: folder.appendingPathComponent("destinations.json"))
        let scenes = SceneStore(), preview = PreviewProgramModel(selected: scenes.selected)
        let controller = StreamController(sceneStore: scenes, previewProgram: preview, permissions: PermissionsManager())
        let recorder = RecordingController(defaults: ShortcutFixtureDefaults.value, defaultDirectory: folder.appendingPathComponent("Recordings"))
        let dispatcher = StudioCommandDispatcher(controller: controller, sceneStore: scenes,
            session: SettingsSession(controller: controller), recorder: recorder, previewProgram: preview)
        try check(!preview.directLiveEditing, "Fixture preview/program setup failed")
        let shortcuts = StudioShortcutController(url: folder.appendingPathComponent("shortcuts.json"), defaults: ShortcutFixtureDefaults.value)
        let catalog: @MainActor @Sendable () -> [StudioPaletteAction] = {
            dispatcher.paletteActions(scenes: scenes.scenes, sources: scenes.sources, stagedScene: preview.stagedScene)
        }
        shortcuts.actions = catalog
        var receipts: [(String, StudioCommandResult)] = []
        shortcuts.onExecute = { action in
            if let command = action.command { receipts.append((action.id, dispatcher.execute(command))) }
        }
        shortcuts.seedScenes([alpha, beta, gamma].map { "scene.\($0.id.rawValue.uuidString).select" })
        try check(!shortcuts.document.globalEnabled && shortcuts.document.bindings.allSatisfy { !$0.global }, "Fixture attempted global hotkey registration")
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 480), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Stream local shortcut qualification"
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        window.contentView = root
        let canvas = NativeShortcutCanvas(frame: NSRect(x: 20, y: 220, width: 560, height: 160))
        let field = NSTextField(frame: NSRect(x: 20, y: 170, width: 560, height: 28))
        field.placeholderString = "Fixture producer text"
        let text = NSTextView(frame: NSRect(x: 20, y: 65, width: 400, height: 90))
        text.isEditable = true; text.isRichText = false
        let actions = NativeControlActions()
        field.target = actions; field.action = #selector(NativeControlActions.submit(_:))
        let button = NativeKeyboardButton(frame: NSRect(x: 450, y: 90, width: 130, height: 28))
        button.title = "Native control"; button.keyEquivalent = "\r"
        button.target = actions; button.action = #selector(NativeControlActions.press(_:))
        for child in [canvas, field, text, button] { root.addSubview(child) }
        let host = NSHostingView(rootView: NativePaletteSheet(shortcuts: shortcuts, actions: catalog))
        host.frame = NSRect(x: 20, y: 15, width: 180, height: 30); root.addSubview(host)
        window.makeKeyAndOrderFront(nil)
        shortcuts.install(window: window)
        defer {
            shortcuts.uninstall()
            if let sheet = window.attachedSheet { window.endSheet(sheet); sheet.orderOut(nil) }
            window.close(); scenes.flushPendingWrites()
        }
        try check(window.windowNumber > 0 && window.makeFirstResponder(canvas), "Owned AppKit window/first responder is unavailable")

        try send(19, "2", flags: .command, to: window)
        try check(receipts.last?.1.error == nil && dispatcher.state.stagedSceneID == beta.id && preview.programScene?.id == alpha.id,
            "Actual local monitor did not dispatch stable scene command/authoritative staged feedback")
        try send(36, "\r", to: window)
        try check(preview.programScene?.id == beta.id, "Canvas Return did not route actual Take")
        try check(dispatcher.execute(.renameScene(beta.id, to: "Renamed Beta")).error == nil, "Actual rename failed")
        try check(dispatcher.execute(.moveScene(beta.id, toFolder: nil, before: alpha.id)).error == nil, "Actual reorder failed")
        try check(dispatcher.execute(.selectScene(gamma.id)).error == nil, "Actual scene selection failed")
        try send(19, "2", flags: .command, to: window)
        try check(dispatcher.state.stagedSceneID == beta.id && catalog().first(where: { $0.id == "scene.\(beta.id.rawValue.uuidString).select" })?.title == "Select Renamed Beta",
            "Rename/reorder silently retargeted an installed shortcut")
        try check(dispatcher.execute(.selectScene(gamma.id)).error == nil && dispatcher.execute(.deleteScene(beta.id)).error == nil, "Actual delete failed")
        let beforeDelete = receipts.count
        try send(19, "2", flags: .command, to: window)
        try check(receipts.count == beforeDelete && dispatcher.state.stagedSceneID == gamma.id && shortcuts.message?.contains("missing") == true,
            "Deleted real scene mapping executed or retargeted")
        print("PASS: actual owned NSApplication key dispatch → shipping local monitor/catalog/dispatcher; staged feedback/Take and stable scene rename/reorder/delete")

        let alphaID = "scene.\(alpha.id.rawValue.uuidString).select"
        shortcuts.record(alphaID)
        try send(18, "1", flags: [.command, .control], to: window)
        try check(shortcuts.document.bindings.filter { $0.commandID == alphaID }.count == 2, "Native recorder did not create multiple bindings")
        shortcuts.record("scene.\(gamma.id.rawValue.uuidString).select")
        try send(18, "1", flags: [.command, .control], to: window)
        try check(shortcuts.message?.contains("already assigned") == true && shortcuts.recordingCommandID != nil, "Native capture failed to report a real binding conflict")
        try send(53, "\u{1B}", to: window)
        shortcuts.record(alphaID); try send(8, "c", flags: .command, to: window)
        try check(shortcuts.message?.contains("reserved") == true, "Native capture stole a reserved edit key")
        try send(53, "\u{1B}", to: window)
        shortcuts.record(alphaID); try send(2, "d", to: window)
        let beforeRepeat = receipts.count
        try send(18, "1", flags: .command, repeatKey: true, to: window)
        try check(receipts.count == beforeRepeat, "Native key repeat executed a production command")
        try send(18, "1", flags: [.command, .control], to: window)
        try check(dispatcher.state.stagedSceneID == alpha.id, "Second native binding failed through real dispatcher")
        let visibility = "scene.\(alpha.id.rawValue.uuidString).layer.\(layer.id.rawValue.uuidString).visibility"
        shortcuts.record(visibility); try send(11, "b", flags: .control, to: window)
        try check(dispatcher.execute(.setSceneLocked(alpha.id, locked: true)).error == nil, "Fixture lock failed")
        let beforeUnavailable = receipts.count
        try send(11, "b", flags: .control, to: window)
        try check(receipts.count == beforeUnavailable && shortcuts.message?.contains("locked") == true, "Current authoritative availability failed to guard shortcut")
        try check(dispatcher.execute(.setSceneLocked(alpha.id, locked: false)).error == nil, "Fixture unlock failed")
        try send(11, "b", flags: .control, to: window)
        try check(receipts.count == beforeUnavailable + 1 && preview.stagedScene?.layers[0].isVisible == false,
            "Recovered availability did not execute exactly one new action")
        print("PASS: real key capture/persistence bindings, conflict/reserved feedback, repeat guard and actual scene-lock availability/recovery with staged layer change")

        try check(window.makeFirstResponder(field), "Native text field did not accept first responder")
        try check(window.firstResponder is NSTextView && field.currentEditor() === window.firstResponder, "Native field editor was not the real responder")
        let beforeTyping = receipts.count
        try send(2, "d", to: window)
        try send(18, "1", flags: .command, to: window)
        try check(field.stringValue == "d" && receipts.count == beforeTyping, "Text-entry key was stolen by a production binding")
        try send(36, "\r", to: window)
        try check(receipts.count == beforeTyping && actions.submits == 1, "Native text Return was stolen from its control")
        try check(window.makeFirstResponder(text), "Native multiline editor did not accept first responder")
        try send(2, "d", to: window); try send(36, "\r", to: window)
        try check(text.string == "d\n" && receipts.count == beforeTyping, "Multiline text or Return invoked Take")
        try check(window.makeFirstResponder(button), "Native control did not accept first responder")
        try send(36, "\r", to: window)
        try check(receipts.count == beforeTyping && actions.presses == 1, "Return did not preserve native control activation")
        print("PASS: actual NSTextField field editor, multiline NSTextView and NSButton first responders preserve typing/Return without Take")

        let modal = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        modal.isReleasedWhenClosed = false
        let modalCanvas = NativeShortcutCanvas(frame: NSRect(x: 0, y: 0, width: 320, height: 120)); modal.contentView = modalCanvas
        window.beginSheet(modal, completionHandler: nil)
        try await wait("Actual modal sheet did not attach", until: { modal.sheetParent === window })
        try check(modal.makeFirstResponder(modalCanvas), "Sheet did not accept first responder")
        let beforeModal = receipts.count
        try send(18, "1", flags: .command, to: modal)
        try check(receipts.count == beforeModal && modalCanvas.received == 1, "A real modal-sheet event executed an underlying studio shortcut")
        try send(35, "p", flags: [.command, .shift], to: modal)
        try check(!shortcuts.palettePresented, "A real modal-sheet event opened an underlying command palette")
        shortcuts.record(alphaID)
        try send(20, "3", flags: [.command, .control], to: modal)
        try check(shortcuts.recordingCommandID == nil && shortcuts.document.bindings.contains {
            $0.commandID == alphaID && $0.chord == StudioKeyChord(keyCode: 20, modifiers: 5, keyLabel: "3")
        } && receipts.count == beforeModal, "Explicit shortcut capture in an owned sheet did not remain available")
        window.endSheet(modal); modal.orderOut(nil); modal.close()
        try await wait("Native modal sheet did not dismiss", until: { window.attachedSheet == nil })
        print("PASS: actual attached sheet forwards native keys, suppresses parent production/palette actions and preserves explicit binding capture")

        try check(window.makeFirstResponder(field), "Palette origin field did not accept first responder")
        try send(35, "p", flags: [.command, .shift], to: window)
        try check(shortcuts.palettePresented, "Actual local palette key did not open shipping palette")
        try send(35, "p", flags: [.command, .shift], repeatKey: true, to: window)
        try check(shortcuts.palettePresented, "Repeated palette key collapsed its own focus flow")
        try await wait("Shipping SwiftUI palette sheet/search control was unavailable", until: {
            textField(in: window.attachedSheet?.contentView, placeholder: "Search studio actions") != nil
        })
        let palette = window.attachedSheet!
        let search = textField(in: palette.contentView, placeholder: "Search studio actions")!
        try await wait("Shipping palette did not focus its actual search editor", until: { search.currentEditor() === palette.firstResponder })
        let beforePalette = receipts.count
        try send(0, "Select Fixture", to: palette)
        try await wait("Native palette typing did not update its real TextField", until: { search.stringValue == "Select Fixture" })
        try await Task.sleep(for: .milliseconds(100))
        try send(125, "\u{F701}", to: palette)
        try send(36, "\r", to: palette)
        try await wait("Native palette Return did not execute/dismiss", until: { !shortcuts.palettePresented && window.attachedSheet == nil })
        try check(receipts.count == beforePalette + 1 && dispatcher.state.stagedSceneID == gamma.id,
            "Actual palette search/down/Return did not select through authoritative dispatcher")
        try await wait("Palette dismissal did not restore its original text-field focus", until: { field.currentEditor() === window.firstResponder && field.currentEditor() != nil })
        try send(2, "d", to: window)
        try check(receipts.count == beforePalette + 1 && field.stringValue.contains("d"), "Restored focus allowed production typing to escape")
        print("PASS: actual shipping SwiftUI palette search typing/down/Return routes dispatcher command and restores native field focus; repeat does not collapse presentation")

        let unrelated = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 320, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        unrelated.isReleasedWhenClosed = false
        let otherCanvas = NativeShortcutCanvas(frame: NSRect(x: 0, y: 0, width: 320, height: 120)); unrelated.contentView = otherCanvas
        unrelated.makeKeyAndOrderFront(nil); _ = unrelated.makeFirstResponder(otherCanvas)
        let beforeOther = receipts.count
        try send(18, "1", flags: .command, to: unrelated)
        try check(receipts.count == beforeOther && otherCanvas.received == 1, "Owned unrelated window leaked into studio monitor")
        unrelated.close(); window.makeKeyAndOrderFront(nil); _ = window.makeFirstResponder(canvas)
        shortcuts.uninstall()
        let beforeUninstall = receipts.count
        try send(18, "1", flags: .command, to: window)
        try check(receipts.count == beforeUninstall, "Uninstalled monitor still executed a studio command")
        let restored = StudioShortcutController(url: folder.appendingPathComponent("shortcuts.json"), defaults: ShortcutFixtureDefaults.value)
        try check(restored.document == shortcuts.document && !restored.document.globalEnabled, "Native captured bindings failed persistence or enabled globals")
        try check(controller.destinationOutputs.states.isEmpty && !recorder.state.isActive && !controller.isPreviewing,
            "Local key qualification allocated capture or publication")
        try check(catalog().first(where: { $0.id == "unavailable.guests" })?.command == nil,
            "Guest controls were falsely presented as implemented")
        print("PASS: unrelated owned window isolation, actual monitor uninstall, captured binding reload and guest/global gates")
        print("Configuration: \(ProcessInfo.processInfo.operatingSystemVersionString); \(ProcessInfo.processInfo.processorCount) CPUs; actual AppKit window/events/first responders and shipping dispatcher, no CGEvent or other-app input")
        print("Qualification: global shortcuts/foreground apps, physical devices/guests and full accessibility/keyboard traversal remain open; fixture temp credentials/preferences and disabled capture consent")
    }
    static func main() {
        setbuf(stdout, nil)
        guard CGSessionCopyCurrentDictionary() != nil else {
            print("UNQUALIFIED: a logged-in WindowServer session is required for native window/first-responder dispatch")
            exit(77)
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
        }
        application.run()
    }
}

private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let value = self else { throw NSError(domain: "LocalShortcutHarness", code: 2, userInfo: [NSLocalizedDescriptionKey: message]) }
        return value
    }
}
