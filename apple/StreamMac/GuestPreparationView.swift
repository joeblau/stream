import SwiftUI
import StreamCore

/// Prepares saved sources and editable layouts. Live interview controls must
/// remain unavailable until a native transport is configured and qualified.
struct GuestPreparationView: View {
    @ObservedObject var sceneStore: SceneStore
    let profile: OutputProfile
    let addToPreview: (Scene) -> Void
    var stagedScene: () -> Scene? = { nil }
    @State private var template: GuestLayoutTemplate = .sideBySide
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("Prepare Interview", systemImage: "person.2")
                    .font(.headline)
                Text("Prepare persistent guest slots and editable layouts before guests arrive. Native guest connections, invitations, return audio and talkback are unavailable in this build.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("\(sceneStore.guestSlots.count) of 10 preparation slots")
                    Spacer()
                    Button("Add Slot") { _ = sceneStore.addGuestSlot() }
                        .disabled(sceneStore.guestSlots.count >= 10)
                }
                Text("Preparation slots are saved with this project. They do not establish connected guest capacity.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(sceneStore.guestSlots) { slot in
                    GuestSlotEditor(slot: slot, save: sceneStore.updateGuestSlot) {
                        if stagedScene().map({ slot.isReferenced(by: $0) }) == true || !sceneStore.removeGuestSlot(slot.id) {
                            error = "This slot is used by a scene or overlay. Remove its camera, screen and captions from those layers first."
                        }
                    }
                }
                if sceneStore.guestSlots.isEmpty {
                    Text("Add a slot to prepare a guest's camera, independent screen source, name and title.")
                        .foregroundStyle(.secondary)
                }
                Divider()
                Picker("Layout", selection: $template) {
                    ForEach(GuestLayoutTemplate.allCases) { item in Text(item.rawValue).tag(item) }
                }
                Text(template.guidance).font(.caption).foregroundStyle(.secondary)
                Button("Add Layout to Preview") {
                    if let scene = template.scene(slots: sceneStore.guestSlots, profile: profile) {
                        addToPreview(scene)
                    }
                }.disabled(sceneStore.guestSlots.count < template.minimumSlots)
                Text("Each layout creates ordinary editable layers with independent camera and screen framing. Names and titles follow saved slot metadata. Placeholder settings apply to new layouts; existing placeholders can be edited in Layers.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            }.padding()
        }
    }
}

private struct GuestSlotEditor: View {
    let slot: GuestSlot
    let save: (GuestSlot) -> Void
    let remove: () -> Void
    @State private var draft: GuestSlot

    init(slot: GuestSlot, save: @escaping (GuestSlot) -> Void, remove: @escaping () -> Void) {
        self.slot = slot; self.save = save; self.remove = remove
        _draft = State(initialValue: slot)
    }

    var body: some View {
        DisclosureGroup(slot.name) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $draft.name)
                TextField("Title", text: $draft.title)
                TextField("Offline message", text: $draft.offlineMessage)
                Picker("Placeholder", selection: $draft.placeholderColorHex) {
                    Text("Blue").tag("#253858")
                    Text("Charcoal").tag("#25282D")
                    Text("Purple").tag("#443358")
                    Text("Green").tag("#25483D")
                }
                HStack {
                    Button("Save Slot") { save(draft) }.disabled(draft == slot)
                    Spacer()
                    Button("Remove Slot", role: .destructive, action: remove)
                }
            }.padding(.top, 6)
        }
        .onChange(of: slot) { _, updated in draft = updated }
    }
}
