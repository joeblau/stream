import AppKit
import Carbon
import Combine

@MainActor
final class StudioShortcutController: ObservableObject {
    @Published private(set) var document: StudioShortcutDocument
    @Published var palettePresented = false
    @Published var editorPresented = false
    var openEditorAfterPalette = false
    @Published private(set) var recordingCommandID: String?
    @Published var message: String?
    @Published private(set) var globalErrors: [String: String] = [:]
    var actions: () -> [StudioPaletteAction] = { [] }
    var onExecute: (StudioPaletteAction) -> Void = { _ in }
    private let url: URL
    private let defaults: UserDefaults
    private var persistenceBlocked = false
    private var monitor: Any?
    private var handler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private var pressedHotKeys: Set<UInt32> = []
    private var hotKeyBindings: [UInt32: StudioShortcutBinding] = [:]
    private weak var studioWindow: NSWindow?
    private weak var responderBeforeCommands: NSResponder?

    init(url: URL? = nil, defaults: UserDefaults = .standard) {
        let url = url ?? DesktopStorage.projectDirectory.appendingPathComponent("stream.shortcuts.v1.json")
        self.url = url
        self.defaults = defaults
        document = StudioShortcutDocument()
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let restored = try JSONDecoder().decode(StudioShortcutDocument.self, from: Data(contentsOf: url))
                guard restored.version == 1 else {
                    persistenceBlocked = true
                    message = "This shortcut file was written by a newer version of Stream. It has been left unchanged."
                    return
                }
                document = restored
            } catch {
                persistenceBlocked = true
                message = "Could not read the shortcut file. It has been left unchanged: \(error.localizedDescription)"
            }
        }
        document.globalEnabled = defaults.bool(forKey: "studio.shortcuts.globalEnabled")
    }

    func install(window: NSWindow?) {
        if let window { studioWindow = window }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated { self.handle(event) == nil }
            return consumed ? nil : event
        }
        registerGlobals()
    }
    func rememberCommandFocus() {
        if responderBeforeCommands == nil { responderBeforeCommands = studioWindow?.firstResponder }
    }
    func restoreCommandFocus() {
        guard let window = studioWindow, let responder = responderBeforeCommands else { return }
        responderBeforeCommands = nil
        if let view = responder as? NSView, view.window === window {
            DispatchQueue.main.async { window.makeFirstResponder(view) }
        }
    }
    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        unregisterGlobals()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
    func seedScenes(_ ids: [String]) {
        guard !document.seededDefaults, !persistenceBlocked else { return }
        let codes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (index, id) in ids.prefix(9).enumerated() {
            _ = document.assign(commandID: id,
                                chord: StudioKeyChord(keyCode: codes[index], modifiers: 1, keyLabel: String(index + 1)), global: false)
        }
        _ = document.assign(commandID: "output.stream.toggle", chord: StudioKeyChord(keyCode: 37, modifiers: 1, keyLabel: "L"), global: false)
        _ = document.assign(commandID: "studio.take", chord: StudioKeyChord(keyCode: 36, modifiers: 0, keyLabel: "Return"), global: false)
        document.seededDefaults = true
        persist()
    }
    func setGlobalEnabled(_ enabled: Bool) {
        document.globalEnabled = enabled
        defaults.set(enabled, forKey: "studio.shortcuts.globalEnabled")
        persist()
    }
    func remove(_ binding: StudioShortcutBinding) {
        document.bindings.removeAll { $0.id == binding.id }; persist()
    }
    func setGlobal(_ binding: StudioShortcutBinding, enabled: Bool) {
        guard !enabled || binding.chord.supportsGlobal else {
            message = "Record a shortcut with Command and Option or Control before enabling it globally."; return
        }
        if let index = document.bindings.firstIndex(where: { $0.id == binding.id }) {
            document.bindings[index].global = enabled; persist()
        }
    }
    func record(_ commandID: String) { recordingCommandID = commandID; message = nil }
    func cancelRecording() { recordingCommandID = nil }
    func execute(id: String) {
        guard let action = actions().first(where: { $0.id == id }) else {
            message = "The shortcut target is missing. Its binding was kept so it cannot silently control another resource."; return
        }
        guard action.unavailableReason == nil else { message = action.unavailableReason; return }
        onExecute(action)
    }
    private func persist() {
        guard !persistenceBlocked else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(document).write(to: url, options: .atomic)
        } catch { message = "Could not save shortcuts: \(error.localizedDescription)" }
        registerGlobals()
    }
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window, window === studioWindow || window.sheetParent === studioWindow else { return event }
        let chord = Self.chord(event)
        if let target = recordingCommandID {
            if event.keyCode == 53 { cancelRecording(); return nil }
            guard !event.isARepeat else { return nil }
            message = document.assign(commandID: target, chord: chord, global: false)
            if message == nil { cancelRecording(); persist() }
            return nil
        }
        // Palette stays discoverable while a text field has focus, just like
        // a native menu action. It never triggers a production command.
        if chord.keyCode == 35 && chord.modifiers == 9 && window.attachedSheet == nil {
            palettePresented.toggle(); return nil
        }
        let responder = window.firstResponder
        let editing = (responder as? NSTextView)?.isEditable == true || responder is NSTextField
            || (chord.keyCode == 36 && responder is NSControl)
        guard let binding = document.binding(for: chord, textEntry: editing,
                                              modalPresented: window.attachedSheet != nil || palettePresented || editorPresented,
                                              repeated: event.isARepeat, global: false) else { return event }
        execute(id: binding.commandID)
        return nil
    }
    static func chord(_ event: NSEvent) -> StudioKeyChord {
        var modifiers = 0
        if event.modifierFlags.contains(.command) { modifiers |= 1 }
        if event.modifierFlags.contains(.option) { modifiers |= 2 }
        if event.modifierFlags.contains(.control) { modifiers |= 4 }
        if event.modifierFlags.contains(.shift) { modifiers |= 8 }
        let labels: [UInt16: String] = [36: "Return", 49: "Space", 51: "Delete", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        return StudioKeyChord(keyCode: UInt32(event.keyCode), modifiers: modifiers,
                              keyLabel: labels[event.keyCode] ?? event.charactersIgnoringModifiers ?? "Key \(event.keyCode)")
    }
    private func unregisterGlobals() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll(); hotKeyBindings.removeAll(); pressedHotKeys.removeAll(); globalErrors.removeAll()
    }
    private func registerGlobals() {
        unregisterGlobals()
        guard document.globalEnabled else { return }
        if handler == nil {
            var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                         EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            let context = Unmanaged.passUnretained(self).toOpaque()
            let installResult = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var keyID = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                               MemoryLayout<EventHotKeyID>.size, nil, &keyID)
                guard status == noErr else { return status }
                MainActor.assumeIsolated {
                    let owner = Unmanaged<StudioShortcutController>.fromOpaque(context).takeUnretainedValue()
                    if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                        owner.pressedHotKeys.remove(keyID.id)
                    } else if owner.pressedHotKeys.insert(keyID.id).inserted {
                        owner.handleGlobal(keyID.id)
                    }
                }
                return noErr
            }, 2, &types, context, &handler)
            guard installResult == noErr else {
                message = "macOS could not install global shortcut handling (error \(installResult))."
                return
            }
        }
        for (index, binding) in document.bindings.filter({ $0.global && $0.chord.supportsGlobal }).enumerated() {
            let id = UInt32(index + 1)
            var flags: UInt32 = 0
            if binding.chord.modifiers & 1 != 0 { flags |= UInt32(cmdKey) }
            if binding.chord.modifiers & 2 != 0 { flags |= UInt32(optionKey) }
            if binding.chord.modifiers & 4 != 0 { flags |= UInt32(controlKey) }
            if binding.chord.modifiers & 8 != 0 { flags |= UInt32(shiftKey) }
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(binding.chord.keyCode, flags, EventHotKeyID(signature: 0x5354524D, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref { hotKeys.append(ref); hotKeyBindings[id] = binding }
            else { globalErrors[binding.commandID] = "macOS could not register \(binding.chord.displayName) (error \(result)); another app may own it." }
        }
    }
    private func handleGlobal(_ id: UInt32) {
        guard let binding = hotKeyBindings[id], let window = studioWindow,
              window.attachedSheet == nil, !palettePresented, !editorPresented else { return }
        // Carbon owns this chord while registered, so the local monitor does
        // not also dispatch it. Never run production actions in a text field.
        if NSApp.isActive && ((window.firstResponder as? NSTextView)?.isEditable == true || window.firstResponder is NSTextField) { return }
        execute(id: binding.commandID)
    }
}
