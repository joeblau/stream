import Foundation

// The actual keyboard store/router compiles independently of capture/output
// hardware. Only the command descriptor and default project path are bridged.
struct StudioPaletteAction {
    let id: String
    var unavailableReason: String?
}
@MainActor enum DesktopStorage {
    static var projectDirectory: URL { FileManager.default.temporaryDirectory }
}

@main struct StudioShortcutsHarness {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stream-shortcut-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let preferencesName = "stream.shortcut-tests.\(UUID())"
        let preferences = UserDefaults(suiteName: preferencesName)!
        defer { preferences.removePersistentDomain(forName: preferencesName) }
        let url = directory.appendingPathComponent("shortcuts.json")
        let a = "scene.\(UUID()).select"
        let b = "scene.\(UUID()).select"
        let runtime = StudioShortcutController(url: url, defaults: preferences)
        runtime.seedScenes([a, b])
        let first = runtime.document.bindings.first { $0.commandID == a }!
        runtime.seedScenes([b, a])
        precondition(runtime.document.bindings.first { $0.commandID == a }?.chord == first.chord,
                     "Rename/reorder must never rewrite stable scene mappings")
        let restored = StudioShortcutController(url: url, defaults: preferences)
        precondition(restored.document == runtime.document, "Every mapping must round-trip")
        var document = restored.document
        let extra = StudioKeyChord(keyCode: 37, modifiers: 5, keyLabel: "L")
        precondition(document.assign(commandID: a, chord: extra, global: true) == nil)
        precondition(document.bindings.filter { $0.commandID == a }.count == 2, "Multiple bindings per command")
        precondition(document.assign(commandID: b, chord: extra, global: true) != nil, "Reject key conflicts")
        precondition(document.assign(commandID: b, chord: StudioKeyChord(keyCode: 6, modifiers: 1, keyLabel: "Z"), global: false) != nil,
                     "Native text/undo shortcuts are reserved")
        precondition(document.assign(commandID: b, chord: StudioKeyChord(keyCode: 30, modifiers: 1, keyLabel: "]"), global: true) != nil,
                     "Global ordinary editor keys require stronger modifiers")
        precondition(document.binding(for: first.chord, textEntry: false, modalPresented: false, repeated: false, global: false)?.commandID == a)
        precondition(document.binding(for: first.chord, textEntry: true, modalPresented: false, repeated: false, global: false) == nil)
        precondition(document.binding(for: first.chord, textEntry: false, modalPresented: true, repeated: false, global: false) == nil)
        precondition(document.binding(for: first.chord, textEntry: false, modalPresented: false, repeated: true, global: false) == nil)
        precondition(document.binding(for: extra, textEntry: false, modalPresented: false, repeated: false, global: true) == nil)
        document.globalEnabled = true
        precondition(document.binding(for: extra, textEntry: false, modalPresented: false, repeated: false, global: true)?.commandID == a)
        precondition(document.binding(for: first.chord, textEntry: false, modalPresented: false, repeated: false, global: true) == nil,
                     "Global operation needs both master and per-binding opt-in")
        var available = [StudioPaletteAction(id: a)]
        var emitted: [String] = []
        runtime.actions = { available }
        runtime.onExecute = { emitted.append($0.id) }
        runtime.execute(id: a)
        available = []
        runtime.execute(id: a)
        precondition(emitted == [a] && runtime.message != nil, "Deleted targets never execute or retarget")
        available = [StudioPaletteAction(id: a, unavailableReason: "Disconnected")]
        runtime.execute(id: a)
        precondition(emitted == [a] && runtime.message == "Disconnected", "Current availability gates every invocation")
        available = [StudioPaletteAction(id: a)]
        runtime.execute(id: a)
        precondition(emitted == [a,a], "Reconnect does not replay stale steps")
        let otherProject = StudioShortcutController(url: directory.appendingPathComponent("other-project.json"), defaults: preferences)
        otherProject.seedScenes([b])
        precondition(!otherProject.document.bindings.contains { $0.commandID == a }, "Project bindings are isolated")
        let newer = directory.appendingPathComponent("newer.json")
        let bytes = Data("{\"version\":99,\"seededDefaults\":false,\"globalEnabled\":false,\"bindings\":[]}".utf8)
        try bytes.write(to: newer)
        let exported = try JSONEncoder().encode(document)
        precondition(!String(data: exported, encoding: .utf8)!.contains("globalEnabled"),
                     "Global master consent never travels in a project")
        let future = StudioShortcutController(url: newer, defaults: preferences)
        future.seedScenes([a]); future.setGlobalEnabled(true)
        let unchanged = try Data(contentsOf: newer)
        precondition(unchanged == bytes, "Future-version files are never overwritten")
        print("PASS: stable IDs, persistence, multiple bindings, conflicts, reserved keys, text/modal/repeat guards, double opt-in, deletion, availability, reconnect, project isolation, future versions")
    }
}
