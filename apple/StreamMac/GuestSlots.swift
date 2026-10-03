import Foundation
import os.lock
import StreamCore

/// Project content only. A saved public peer UUID helps reconnect an existing
/// invite to its chosen slot; it grants no service or media authority.
struct GuestSlot: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var name: String
    var displayName = ""
    var title = ""
    var reconnectPeerID: UUID?
    var cameraPlaceholder = GuestOfflinePlaceholder()
    var screenPlaceholder = GuestOfflinePlaceholder(message: "Screen not shared")

    var resolvedName: String { displayName.isEmpty ? name : displayName }
    func normalized() -> GuestSlot {
        var value = self
        value.name = Self.bounded(name, fallback: "Guest slot")
        value.displayName = Self.bounded(displayName)
        value.title = Self.bounded(title)
        value.cameraPlaceholder = cameraPlaceholder.normalized()
        value.screenPlaceholder = screenPlaceholder.normalized()
        return value
    }
    private static func bounded(_ value: String, fallback: String = "") -> String {
        let bounded = String(value.prefix(128))
        return bounded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : bounded
    }
}

struct GuestOfflinePlaceholder: Hashable, Codable, Sendable {
    var visible = true
    var colorHex = "#253858"
    var message = "Guest offline"

    func normalized() -> Self {
        var value = self
        value.message = String(message.prefix(128))
        if colorHex.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) == nil {
            value.colorHex = "#253858"
        }
        return value
    }
}

struct GuestTitleBinding: Hashable, Codable, Sendable {
    enum Field: String, Codable, CaseIterable, Sendable { case name, title }
    var slotID: UUID
    var field: Field
}

/// Render-thread value snapshot, following the source/overlay store boundary.
/// Runtime leases, online state, invitations and credentials never enter it.
final class GuestSlotRenderStore: @unchecked Sendable {
    static let shared = GuestSlotRenderStore()
    private var lock = os_unfair_lock_s()
    private var slots: [UUID: GuestSlot] = [:]
    func publish(_ values: [GuestSlot]) {
        var snapshot: [UUID: GuestSlot] = [:]
        for value in values.prefix(16) where snapshot[value.id] == nil { snapshot[value.id] = value.normalized() }
        os_unfair_lock_lock(&lock); slots = snapshot; os_unfair_lock_unlock(&lock)
    }
    func snapshot() -> [UUID: GuestSlot] {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return slots
    }
}

extension SceneStore {
    @discardableResult func createGuestSlot(name: String = "Guest slot") -> GuestSlot? {
        guard guestSlots.count < 16 else { return nil }
        let slot = GuestSlot(name: name).normalized()
        replaceGuestSlot(slot)
        return slot
    }
    func replaceGuestSlot(_ proposed: GuestSlot) {
        let slot = proposed.normalized()
        var values = guestSlots
        if let index = values.firstIndex(where: { $0.id == slot.id }) { values[index] = slot }
        else {
            guard guestSlots.count < 16 else { return }
            values.append(slot)
        }
        writeGuestSlots(values)
        ensureGuestSources(slotID: slot.id, name: slot.resolvedName)
    }
    /// Used by admission as well as pre-arrival preparation. Existing source
    /// identities survive metadata edits, disconnect and project reload.
    func ensureGuestSources(slotID: UUID, name: String) {
        for role in [GuestSourceRole.camera, .screen] {
            if !sources.contains(where: {
                guard case .guest(let payload) = $0.payload else { return false }
                return payload.slotID == slotID && payload.role == role
            }) {
                addSource(.init(name: "\(name) \(role == .camera ? "Camera" : "Screen")",
                    payload: .guest(.init(slotID: slotID, role: role))))
            }
        }
    }
    func assignGuest(_ peer: UUID, to slotID: UUID, displayName: String) -> Bool {
        guard var slot = guestSlots.first(where: { $0.id == slotID }) else { return false }
        // A public peer has one assignment within this project.
        var values = guestSlots
        for index in values.indices where values[index].id != slotID && values[index].reconnectPeerID == peer {
            values[index].reconnectPeerID = nil
        }
        writeGuestSlots(values)
        slot.reconnectPeerID = peer; slot.displayName = displayName
        replaceGuestSlot(slot)
        return true
    }
}

enum GuestSceneTemplate: String, CaseIterable, Identifiable {
    case solo = "Guest Solo", sideBySide = "Side by Side", grid = "Guest Grid", pip = "Guest PIP", screenAndGuests = "Screen + Guests"
    var id: String { rawValue }

    func scene(slots: [GuestSlot], sources: [SourceDefinition], hostCamera: SourceDefinitionID?) -> Scene? {
        guard let first = slots.first else { return nil }
        let chosen = Array(slots.prefix(self == .grid ? 4 : self == .screenAndGuests ? 3 : 1))
        var layers: [LayerNode] = []
        func guest(_ slot: GuestSlot, role: GuestSourceRole, rect: (Double, Double, Double, Double)) {
            let source = sources.first {
                guard case .guest(let payload) = $0.payload else { return false }
                return payload.slotID == slot.id && payload.role == role
            }
            layers.append(.init(name: "\(slot.name) \(role.rawValue)", sourceID: source?.id,
                payload: .guest(.init(slotID: slot.id, role: role)), transform: transform(rect)))
            if role == .camera {
                for (field, offset) in [(GuestTitleBinding.Field.name, 0.0), (.title, 0.035)] {
                    var text = TextSourcePayload(text: field == .name ? slot.name : "", fontSize: 30,
                        alignment: .center, backgroundColorHex: "#13223C", padding: 3)
                    text.guestBinding = .init(slotID: slot.id, field: field)
                    layers.append(.init(name: "\(slot.name) \(field.rawValue)", payload: .text(text),
                        transform: transform((rect.0, max(rect.1, rect.1 + rect.3 - 0.08) + offset, rect.2, 0.04))))
                }
            }
        }
        switch self {
        case .solo: guest(first, role: .camera, rect: (0, 0, 1, 1))
        case .sideBySide:
            layers.append(.init(name: "Host Camera", sourceID: hostCamera, payload: .camera(.init()), transform: transform((0.025, 0.12, 0.46, 0.76))))
            guest(first, role: .camera, rect: (0.515, 0.12, 0.46, 0.76))
        case .grid:
            for (index, slot) in chosen.enumerated() {
                guest(slot, role: .camera, rect: (0.02 + Double(index % 2) * 0.5, 0.02 + Double(index / 2) * 0.5, 0.46, 0.46))
            }
        case .pip:
            layers.append(.init(name: "Host Camera", sourceID: hostCamera, payload: .camera(.init()), transform: .fullscreen))
            guest(first, role: .camera, rect: (0.69, 0.60, 0.28, 0.36))
        case .screenAndGuests:
            guest(first, role: .screen, rect: (0, 0, 0.75, 1))
            for (index, slot) in chosen.enumerated() { guest(slot, role: .camera, rect: (0.77, 0.02 + Double(index) * 0.32, 0.21, 0.30)) }
        }
        return Scene(name: rawValue, layers: layers, background: .solid(colorHex: "#13223C"))
    }
    private func transform(_ rect: (Double, Double, Double, Double)) -> LayerTransform {
        .init(position: .init(x: rect.0, y: rect.1), size: .init(width: rect.2, height: rect.3), anchor: .topLeft)
    }
}
