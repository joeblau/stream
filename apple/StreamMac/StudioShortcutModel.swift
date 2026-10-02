import Foundation

/// Project keyboard preferences. Targets are command IDs containing the
/// resource UUID, never a scene position/name. Deleted targets stay unbound.
struct StudioKeyChord: Codable, Equatable, Hashable {
    static let command = 1
    static let option = 2
    static let control = 4
    static let shift = 8
    var keyCode: UInt32
    var modifiers: Int
    var keyLabel: String

    var displayName: String {
        (modifiers & Self.control != 0 ? "⌃" : "")
        + (modifiers & Self.option != 0 ? "⌥" : "")
        + (modifiers & Self.shift != 0 ? "⇧" : "")
        + (modifiers & Self.command != 0 ? "⌘" : "") + keyLabel.uppercased()
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode); hasher.combine(modifiers)
    }
    /// Global bindings require Command + Option/Control so ordinary text
    /// input in the foreground app remains available.
    var supportsGlobal: Bool {
        modifiers & Self.command != 0 && modifiers & (Self.option | Self.control) != 0
    }
    var isReserved: Bool {
        if modifiers == Self.command || modifiers == (Self.command | Self.shift) {
            // Native editing/file/window shortcuts and the command palette.
            return [0, 6, 7, 8, 9, 12, 13, 14, 15, 31, 35, 38, 40, 45, 46, 1, 43].contains(keyCode)
        }
        if modifiers & (Self.command | Self.option) == (Self.command | Self.option) {
            // Existing Annotate and Present menu shortcuts.
            return [18, 19, 20, 29, 6, 8, 9, 11, 40, 123, 124, 125, 126].contains(keyCode)
        }
        return keyCode == 53 || keyCode == 48 // Escape and Tab preserve navigation.
    }
}

struct StudioShortcutBinding: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var commandID: String
    var chord: StudioKeyChord
    var global = false
}

struct StudioShortcutDocument: Codable, Equatable {
    var version = 1
    var seededDefaults = false
    var globalEnabled = false
    var bindings: [StudioShortcutBinding] = []
    // Master global consent is machine-local and never travels in a project.
    enum CodingKeys: String, CodingKey { case version, seededDefaults, bindings }

    func conflict(for chord: StudioKeyChord, excluding id: UUID? = nil) -> StudioShortcutBinding? {
        bindings.first { $0.id != id && $0.chord == chord }
    }
    func binding(for chord: StudioKeyChord, textEntry: Bool, modalPresented: Bool,
                 repeated: Bool, global: Bool) -> StudioShortcutBinding? {
        guard !textEntry, !modalPresented, !repeated,
              !global || globalEnabled else { return nil }
        return bindings.first { $0.chord == chord && (!global || $0.global) }
    }
    mutating func assign(commandID: String, chord: StudioKeyChord,
                         global: Bool, replacing id: UUID? = nil) -> String? {
        guard !chord.isReserved else { return "This shortcut is reserved for menus, text editing, or keyboard navigation." }
        guard !global || chord.supportsGlobal else { return "Global shortcuts require Command and Option or Control." }
        guard conflict(for: chord, excluding: id) == nil else { return "This shortcut is already assigned. Remove its existing binding first." }
        let binding = StudioShortcutBinding(id: id ?? UUID(), commandID: commandID, chord: chord, global: global)
        if let id, let index = bindings.firstIndex(where: { $0.id == id }) { bindings[index] = binding }
        else { bindings.append(binding) }
        return nil
    }
}
