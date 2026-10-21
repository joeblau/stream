import Foundation
import os.lock
import StreamCore

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
        guard var slot = guestSlots.first(where: { $0.id == slotID }) else { return }
        for role in [GuestSourceRole.camera, .screen] {
            let matching = sources.filter {
                guard case .guest(let payload) = $0.payload else { return false }
                return payload.slotID == slotID && payload.role == role
            }.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
            let selected = role == .camera ? slot.cameraSourceID : slot.screenSourceID
            if let existing = matching.first(where: { $0.id == selected }) ?? matching.first {
                if role == .camera { slot.cameraSourceID = existing.id } else { slot.screenSourceID = existing.id }
            } else if var prepared = sources.first(where: { $0.id == selected }), case .guest(let payload) = prepared.payload,
                      payload.slotID == nil {
                // Upgrade main's saved preparation source without changing its ID.
                prepared.payload = .guest(.init(slotID: slotID, role: role)); updateSource(prepared)
            } else if !sources.contains(where: { $0.id == selected }) {
                addSource(.init(id: selected, name: "\(name) \(role == .camera ? "Camera" : "Screen")",
                    payload: .guest(.init(slotID: slotID, role: role))))
            }
        }
        if let index = guestSlots.firstIndex(where: { $0.id == slotID }), guestSlots[index] != slot {
            var values = guestSlots; values[index] = slot; writeGuestSlots(values)
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

enum GuestLayoutTemplate: String, CaseIterable, Identifiable {
    case solo = "Solo"
    case sideBySide = "Side by Side"
    case grid = "Grid"
    case pictureInPicture = "Picture in Picture"
    case screenAndGuests = "Screen + Guests"
    var id: String { rawValue }
    var minimumSlots: Int { self == .sideBySide || self == .pictureInPicture ? 2 : 1 }
    var guidance: String {
        switch self {
        case .solo: return "Uses the first slot."
        case .sideBySide, .pictureInPicture: return "Uses the first two slots."
        case .grid: return "Uses every prepared slot."
        case .screenAndGuests: return "Uses the first slot's screen and every prepared camera."
        }
    }

    func scene(slots: [GuestSlot], profile: OutputProfile) -> Scene? {
        guard slots.count >= minimumSlots, slots.count <= 16 else { return nil }
        var layers: [LayerNode] = []
        func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> LayerTransform {
            LayerTransform(position: GraphPoint(x: x, y: y), size: GraphSize(width: width, height: height), anchor: .topLeft)
        }
        func participant(_ slot: GuestSlot, transform: LayerTransform, screen: Bool = false) {
            let label = screen ? "Shared screen" : slot.offlineMessage
            layers.append(LayerNode(name: "\(slot.name) · Editable Placeholder", payload: .shape(ShapeSourcePayload(fillColorHex: slot.placeholderColorHex)), transform: transform))
            layers.append(LayerNode(name: "\(slot.name) · Offline Message", payload: .text(TextSourcePayload(text: label,
                fontSize: min(24, 1080 * transform.size.height * 0.12), alignment: .center, wraps: false, overflow: .scaleDown)), transform: rect(transform.position.x, transform.position.y + transform.size.height * 0.36, transform.size.width, transform.size.height * 0.22)))
            layers.append(LayerNode(name: "\(slot.name) · \(screen ? "Screen" : "Camera")", sourceID: screen ? slot.screenSourceID : slot.cameraSourceID,
                payload: .guest(GuestSourcePayload()), transform: transform))
            if !screen {
                layers.append(LayerNode(name: "\(slot.name) · Automatic Name", payload: .text(TextSourcePayload(text: slot.nameTemplate,
                    fontSize: min(28, 1080 * transform.size.height * 0.07), alignment: .leading, backgroundColorHex: "#13223C", padding: 0, wraps: false, overflow: .scaleDown)),
                    transform: rect(transform.position.x, transform.position.y + transform.size.height * 0.78, transform.size.width, transform.size.height * 0.12)))
                layers.append(LayerNode(name: "\(slot.name) · Automatic Title", payload: .text(TextSourcePayload(text: slot.titleTemplate,
                    fontSize: min(20, 1080 * transform.size.height * 0.06), alignment: .leading, backgroundColorHex: "#13223C", padding: 0, wraps: false, overflow: .scaleDown)),
                    transform: rect(transform.position.x, transform.position.y + transform.size.height * 0.90, transform.size.width, transform.size.height * 0.10)))
            }
        }
        switch self {
        case .solo:
            participant(slots[0], transform: rect(0.03, 0.03, 0.94, 0.94))
        case .sideBySide:
            participant(slots[0], transform: rect(0.025, 0.10, 0.46, 0.80))
            participant(slots[1], transform: rect(0.515, 0.10, 0.46, 0.80))
        case .pictureInPicture:
            participant(slots[0], transform: rect(0, 0, 1, 1))
            participant(slots[1], transform: rect(0.69, 0.62, 0.28, 0.34))
        case .grid:
            let columns = slots.count <= 4 ? min(2, slots.count) : (slots.count <= 9 ? 3 : 4)
            let rows = Int(ceil(Double(slots.count) / Double(columns)))
            let width = 0.94 / Double(columns), height = 0.94 / Double(rows)
            for (index, slot) in slots.enumerated() {
                participant(slot, transform: rect(0.03 + Double(index % columns) * width, 0.03 + Double(index / columns) * height, width - 0.015, height - 0.02))
            }
        case .screenAndGuests:
            participant(slots[0], transform: rect(0.02, 0.02, 0.72, 0.96), screen: true)
            let columns = slots.count > 5 ? 2 : 1
            let rows = Int(ceil(Double(slots.count) / Double(columns)))
            let height = 0.96 / Double(rows), width = 0.22 / Double(columns)
            for (index, slot) in slots.enumerated() {
                participant(slot, transform: rect(0.76 + Double(index % columns) * width,
                    0.02 + Double(index / columns) * height, width - 0.005, height - 0.01))
            }
        }
        var scene = Scene(name: "Interview · \(rawValue)", layers: layers)
        scene.canvas.referenceSize = GraphSize(width: Double(profile.canvasWidth), height: Double(profile.canvasHeight))
        scene.background = .solid(colorHex: "#13223C")
        return scene
    }
}
