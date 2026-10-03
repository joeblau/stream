import SwiftUI

struct GuestSlotsView: View {
    @ObservedObject var store: SceneStore
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher
    @State private var template: GuestSceneTemplate = .sideBySide

    var body: some View {
        DisclosureGroup("Saved Guest Slots and Layouts") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Prepare up to 16 saved positions. One native guest can connect at a time; the remaining positions show their offline cards.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Add Saved Guest Slot") { _ = store.createGuestSlot(name: "Guest \(store.guestSlots.count + 1)") }
                    .disabled(store.guestSlots.count >= 16)
                ForEach(store.guestSlots) { slot in
                    DisclosureGroup(slot.name) {
                        TextField("Slot label", text: binding(slot.id, \.name))
                        TextField("Display name (guest metadata updates it)", text: binding(slot.id, \.displayName))
                        TextField("Local name override", text: .init(
                            get: { store.guestSlots.first(where: { $0.id == slot.id })?.localName ?? "" },
                            set: { value in update(slot.id) { $0.localName = value } }))
                        TextField("Title", text: binding(slot.id, \.title))
                        placeholder(slot.id, role: .camera)
                        placeholder(slot.id, role: .screen)
                        if slot.reconnectPeerID != nil {
                            Button("Forget Saved Reconnect Identity") { update(slot.id) { $0.reconnectPeerID = nil } }
                            Text("The saved public guest identity grants no admission or Program permission.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Picker("Editable Layout", selection: $template) {
                    ForEach(GuestSceneTemplate.allCases) { Text($0.rawValue).tag($0) }
                }
                Button("Add Guest Layout to Preview") {
                    if let scene = template.scene(slots: store.guestSlots, sources: store.sources,
                        hostCamera: store.sources.first(where: { $0.payload.isCamera })?.id) {
                        dispatcher.execute(.insertScene(scene))
                    }
                }.disabled(store.guestSlots.isEmpty)
                Text("Layouts are ordinary editable layers. Names and titles follow their saved slot; Take publishes the layout separately from On Air admission.")
                    .font(.caption).foregroundStyle(.secondary)
            }.textFieldStyle(.roundedBorder).padding(.top, 8)
        }
    }
    private func binding(_ id: UUID, _ path: WritableKeyPath<GuestSlot, String>) -> Binding<String> {
        .init(get: { store.guestSlots.first(where: { $0.id == id })?[keyPath: path] ?? "" },
              set: { value in update(id) { $0[keyPath: path] = value } })
    }
    private func update(_ id: UUID, _ body: (inout GuestSlot) -> Void) {
        guard var slot = store.guestSlots.first(where: { $0.id == id }) else { return }
        body(&slot); store.replaceGuestSlot(slot)
    }
    private func placeholder(_ id: UUID, role: GuestSourceRole) -> some View {
        let path: WritableKeyPath<GuestSlot, GuestOfflinePlaceholder> = role == .camera ? \.cameraPlaceholder : \.screenPlaceholder
        return VStack(alignment: .leading) {
            Toggle("\(role == .camera ? "Camera" : "Screen") Offline Card", isOn: .init(
                get: { store.guestSlots.first(where: { $0.id == id })?[keyPath: path].visible ?? false },
                set: { enabled in update(id) { $0[keyPath: path].visible = enabled } }))
            TextField("Offline message", text: .init(
                get: { store.guestSlots.first(where: { $0.id == id })?[keyPath: path].message ?? "" },
                set: { value in update(id) { $0[keyPath: path].message = value } }))
            ColorPicker("Card Color", selection: .init(
                get: {
                    let rgb = HexColor.components(store.guestSlots.first(where: { $0.id == id })?[keyPath: path].colorHex ?? "#253858")
                    return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
                },
                set: { value in
                    let rgb = NSColor(value).usingColorSpace(.sRGB) ?? NSColor(value)
                    update(id) { $0[keyPath: path].colorHex = HexColor.string(red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent)) }
                }), supportsOpacity: false)
        }
    }
}
