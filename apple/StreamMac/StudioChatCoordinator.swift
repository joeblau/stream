import Combine
import Foundation
import StreamCore

@MainActor final class StudioChatCoordinator: ObservableObject {
    let restream = RestreamChat()
    @Published private(set) var queue = StudioChatQueue()
    @Published private(set) var connections: [String: Connection] = [:]
    @Published var error: String?
    @Published var selectedSlot: LayerID?
    @Published var includeAuthor = true
    @Published var includePlatform = true
    private weak var dispatcher: StudioCommandDispatcher?
    private weak var previewProgram: PreviewProgramModel?
    private var slots: Set<LayerID> = []
    private let slotsURL: URL

    struct Connection { let uuid: String; let platform: String; let state: String }
    struct SlotPreferences: Codable { var version = 1; var slots: [LayerID] }

    init(dispatcher: StudioCommandDispatcher, previewProgram: PreviewProgramModel) {
        self.dispatcher = dispatcher; self.previewProgram = previewProgram
        slotsURL = DesktopStorage.projectDirectory.appendingPathComponent("comment-slots.json")
        if let data = try? Data(contentsOf: slotsURL), data.count <= 65_536,
           let saved = try? JSONDecoder().decode(SlotPreferences.self, from: data), saved.version == 1, saved.slots.count <= 16 {
            slots = Set(saved.slots)
        }
        restream.onStudioEnvelope = { [weak self] data in self?.receive(data) }
        restream.onStudioReset = { [weak self] in self?.queue = .init(); self?.connections = [:] }
    }
    func receive(_ data: Data) {
        guard let action = StudioRestreamDecoder.decode(data) else { return }
        switch action {
        case .message(let message): queue.receive(message)
        case .heartbeat: break
        case .connection(let id, let uuid, let platform, let state):
            if connections[id] != nil || connections.count < 64 { connections[id] = .init(uuid: uuid, platform: platform, state: state) }
        case .closed(let uuid): connections = connections.filter { $0.value.uuid != uuid }
        }
    }
    var availableSlots: [LayerNode] {
        previewProgram?.stagedScene?.layers.filter { slots.contains($0.id) && $0.payload.isText } ?? []
    }
    func favorite(_ id: String) { queue.favorite(id) }
    func enqueue(_ id: String) { queue.enqueue(id) }
    func dequeue(_ id: String) { queue.remove(id) }
    func select(_ id: String) { queue.select(id) }
    func advance(_ direction: Int) { queue.advance(direction) }
    func createSlot() {
        guard slots.count < 16, let scene = previewProgram?.stagedScene else { return }
        let before = Set(scene.layers.map(\.id))
        var payload = TextSourcePayload(text: "")
        payload.fontSize = 42; payload.backgroundColorHex = "#171717E6"
        payload.padding = 20; payload.overflow = .scaleDown
        guard run(.addLayer(.text(payload), in: scene.id)),
              let layer = previewProgram?.stagedScene?.layers.first(where: { !before.contains($0.id) }) else { return }
        let transform = LayerTransform(position: .init(x: 0.08, y: 0.65), size: .init(width: 0.84, height: 0.28), anchor: .topLeft)
        guard run(.renameLayer(layer.id, to: "Comment Slot", in: scene.id)),
              run(.setLayerTransform(layer.id, transform, in: scene.id)),
              run(.setLayerVisibility(layer.id, visible: false, in: scene.id)) else { return }
        slots.insert(layer.id); selectedSlot = layer.id
        do { try JSONEncoder().encode(SlotPreferences(slots: slots.sorted { $0.description < $1.description })).write(to: slotsURL, options: .atomic) }
        catch { self.error = "The comment slot could not be saved." }
    }
    func show(_ id: String) {
        guard let message = queue.message(id), let scene = previewProgram?.stagedScene,
              let slotID = selectedSlot, let layer = availableSlots.first(where: { $0.id == slotID }),
              case .text(var payload) = layer.payload else { error = "Create or select a comment slot in the staged scene first."; return }
        var caption: [String] = []
        if includeAuthor { caption.append(message.author) }
        if includePlatform { caption.append(message.platform) }
        payload.text = (caption.isEmpty ? "" : caption.joined(separator: " · ") + "\n") + message.text
        let commands: [StudioCommand] = [.setLayerText(slotID, payload, in: scene.id), .setLayerVisibility(slotID, visible: true, in: scene.id)]
        guard let dispatcher else { return }
        for command in commands {
            if let reason = dispatcher.availabilityError(for: command) { error = reason.description; return }
        }
        for command in commands { if !run(command) { return } }
        queue.show(id)
    }
    func hide() {
        guard let scene = previewProgram?.stagedScene, let slot = selectedSlot else { return }
        if run(.setLayerVisibility(slot, visible: false, in: scene.id)) { queue.hide() }
    }
    func shutdown() { restream.disconnectStudioSession() }
    private func run(_ command: StudioCommand) -> Bool {
        guard let dispatcher else { return false }
        if let reason = dispatcher.execute(command).error { error = reason.description; return false }
        error = nil; return true
    }
}
