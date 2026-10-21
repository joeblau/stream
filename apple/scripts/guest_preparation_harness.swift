import Foundation
import StreamCore

@main
struct GuestPreparationHarness {
    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stream-guest-preparation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("ProjectA")
        let second = root.appendingPathComponent("ProjectB")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let store = SceneStore(directory: first)
        precondition(store.guestSlots.isEmpty)
        var slot = store.addGuestSlot()!
        precondition(slot.cameraSourceID != slot.screenSourceID)
        precondition(store.source(withID: slot.cameraSourceID) != nil && store.source(withID: slot.screenSourceID) != nil)
        slot.name = "Ada Lovelace"; slot.title = "Guest Presenter"; slot.offlineMessage = "Back shortly"
        let identities = (slot.id, slot.cameraSourceID, slot.screenSourceID)
        store.updateGuestSlot(slot)
        precondition(TitleTemplate.resolve(slot.nameTemplate, with: TitleTokenStore.shared.snapshot()) == "Ada Lovelace")
        precondition(TitleTemplate.resolve(slot.titleTemplate, with: TitleTokenStore.shared.snapshot()) == "Guest Presenter")
        store.flushPendingWrites()
        let restored = SceneStore(directory: first)
        precondition(restored.guestSlots == [slot])
        precondition(restored.guestSlots[0].id == identities.0 && restored.guestSlots[0].cameraSourceID == identities.1 && restored.guestSlots[0].screenSourceID == identities.2)
        // Old v2 documents have no slot field and remain readable.
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(restored.document)) as! [String: Any]
        old.removeValue(forKey: "guestSlots")
        let oldDocument = try JSONDecoder().decode(SceneDocument.self, from: JSONSerialization.data(withJSONObject: old))
        precondition(oldDocument.guestSlots.isEmpty)
        func expectInvalid(_ document: SceneDocument) throws {
            let data = try JSONEncoder().encode(document)
            do {
                _ = try JSONDecoder().decode(SceneDocument.self, from: data)
                preconditionFailure("Malformed guest slots accepted")
            } catch DecodingError.dataCorrupted(_) { /* Existing recovery preserves invalid files. */ }
        }
        var invalid = restored.document
        for index in 2...11 {
            let extra = GuestSlot(name: "Guest \(index)")
            invalid.guestSlots.append(extra); invalid.sources += extra.sources
        }
        try expectInvalid(invalid)
        var extra = GuestSlot(name: "Duplicate ID")
        extra.id = slot.id
        invalid = restored.document; invalid.guestSlots.append(extra); invalid.sources += extra.sources
        try expectInvalid(invalid)
        extra = GuestSlot(name: "Duplicate Camera")
        extra.cameraSourceID = slot.cameraSourceID
        invalid = restored.document; invalid.guestSlots.append(extra)
        invalid.sources.append(extra.sources[1])
        try expectInvalid(invalid)
        invalid = restored.document; invalid.guestSlots[0].screenSourceID = slot.cameraSourceID
        try expectInvalid(invalid)
        invalid = restored.document; invalid.sources.removeAll { $0.id == slot.screenSourceID }
        try expectInvalid(invalid)
        invalid = restored.document
        let cameraIndex = invalid.sources.firstIndex { $0.id == slot.cameraSourceID }!
        invalid.sources[cameraIndex].payload = .camera(CameraSourcePayload())
        try expectInvalid(invalid)
        invalid = restored.document; invalid.sources.append(slot.sources[0])
        try expectInvalid(invalid)
        let other = SceneStore(directory: second)
        precondition(other.guestSlots.isEmpty && !TitleTokenStore.shared.snapshot().keys.contains(where: { $0.hasPrefix("guestslot_") }))
        _ = SceneStore(directory: first)
        precondition(TitleTemplate.resolve(slot.nameTemplate, with: TitleTokenStore.shared.snapshot()) == "Ada Lovelace")

        while restored.guestSlots.count < 10 { precondition(restored.addGuestSlot() != nil) }
        precondition(restored.addGuestSlot() == nil)
        for layout in GuestLayoutTemplate.allCases {
            for count in 1...10 {
                let slots = Array(restored.guestSlots.prefix(count))
                let scene = layout.scene(slots: slots, profile: .default)
                if count < layout.minimumSlots { precondition(scene == nil); continue }
                guard let scene else { preconditionFailure("Missing template") }
                precondition(Set(scene.layers.map(\.id)).count == scene.layers.count)
                for layer in scene.layers {
                    precondition(layer.transform.position.x >= 0 && layer.transform.position.y >= 0)
                    precondition(layer.transform.size.width > 0 && layer.transform.size.height > 0)
                    precondition(layer.transform.position.x + layer.transform.size.width <= 1.0001)
                    precondition(layer.transform.position.y + layer.transform.size.height <= 1.0001)
                    if let sourceID = layer.sourceID {
                        precondition(slots.contains { $0.cameraSourceID == sourceID || $0.screenSourceID == sourceID })
                    }
                    if case .text(let text) = layer.payload {
                        // Caption fonts fit their fixed boxes before additional
                        // overflow scaling, including dense ten-slot layouts.
                        precondition(text.overflow == .scaleDown)
                        precondition(text.fontSize + text.padding * 2 < layer.transform.size.height * 1080)
                    }
                }
                if layout == .screenAndGuests {
                    precondition(scene.layers.contains { $0.sourceID == slot.screenSourceID })
                    precondition(scene.layers.contains { $0.sourceID == slot.cameraSourceID })
                }
                let roundTrip = try JSONDecoder().decode(Scene.self, from: JSONEncoder().encode(scene))
                precondition(roundTrip == scene)
            }
        }
        // Ordinary caption metadata follows the same slot after a Take-like
        // value copy; editing one layer never changes another layer's frame.
        let prepared = GuestLayoutTemplate.sideBySide.scene(slots: restored.guestSlots, profile: .default)!
        _ = restored.addScene(prepared)
        var taken = prepared
        taken.layers[0].transform.size.width = 0.30
        precondition(prepared.layers[0].transform.size.width != taken.layers[0].transform.size.width)
        precondition(!restored.removeGuestSlot(slot.id))
        slot.name = "Ada Renamed"; restored.updateGuestSlot(slot)
        precondition(TitleTemplate.resolve(slot.nameTemplate, with: TitleTokenStore.shared.snapshot()) == "Ada Renamed")
        let upper = LayerNode(name: "Caption", payload: .text(TextSourcePayload(text: "{ "+slot.tokenPrefix.uppercased()+"_NAME }")),
            transform: LayerTransform(position: GraphPoint(x: 0, y: 0), size: GraphSize(width: 1, height: 1), anchor: .topLeft))
        precondition(slot.isReferenced(by: upper))
        var literal = upper
        if case .text(var text) = literal.payload { text.recordingChatMessageID = "public-comment"; literal.payload = .text(text) }
        precondition(!slot.isReferenced(by: literal))
        let unused = restored.guestSlots.last!
        precondition(restored.removeGuestSlot(unused.id))
        precondition(restored.source(withID: unused.cameraSourceID) == nil && restored.source(withID: unused.screenSourceID) == nil)
        restored.flushPendingWrites()
        let afterRemoval = SceneStore(directory: first)
        precondition(afterRemoval.guestSlots.count == 9 && !afterRemoval.guestSlots.contains { $0.id == unused.id })
        print("PASS guest preparation: project reload/isolation, legacy/malformed documents, stable separate sources, capacity guard, all 50 layout/count cases, fitting captions, automatic metadata and referenced-slot deletion")
    }
}
