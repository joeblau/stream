import Combine
import Foundation
import StreamCore

@MainActor final class StudioChatCoordinator: ObservableObject {
    let restream = RestreamChat()
    let recordingMessages = PassthroughSubject<RecordingChatMessage, Never>()
    let recordingBindings = PassthroughSubject<RecordingChatBinding, Never>()
    private(set) var recentRecordingBindings: [RecordingChatBinding] = []
    @Published private(set) var directChat: StudioDirectChatManager?
    @Published private(set) var queue = StudioChatQueue()
    @Published private(set) var connections: [String: Connection] = [:]
    @Published var error: String?
    @Published var selectedSlot: LayerID?
    @Published var includeAuthor = true
    @Published var includePlatform = true
    @Published var includeAvatar = false
    private var avatarTasks: [LayerID: Task<Void, Never>] = [:]
    private var commentLayoutCache: [LayerNode: CommentTextLayout] = [:]
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
        // Signing out of one adapter cannot clear another adapter's messages,
        // curated queue, favorites, or reading position.
        restream.onStudioReset = { [weak self] in
            self?.connections = self?.connections.filter { $0.key.hasPrefix("direct:") } ?? [:]
        }
    }
    func bindAccounts(_ accounts: ProviderAccountSession) {
        directChat?.shutdown()
        let manager = StudioDirectChatManager(request: { [weak accounts] provider, request in
            guard let accounts else { throw CancellationError() }; return try await accounts.chatRequest(provider, request)
        }, identity: { [weak accounts] provider in
            guard let accounts else { throw CancellationError() }; return try await accounts.chatIdentity(provider)
        }, emit: { [weak self] action in self?.receive(action) })
        directChat = manager; accounts.directChat = manager
    }
    func receive(_ data: Data) {
        guard let action = StudioRestreamDecoder.decode(data) else { return }
        receive(action)
    }
    func receive(_ action: StudioChatAction) {
        switch action {
        case .message(let message):
            let before = queue.messages.count
            let last = queue.messages.last?.id
            queue.receive(message)
            if queue.messages.count != before || queue.messages.last?.id != last {
                recordingMessages.send(Self.recordingMessage(message))
            }
        case .heartbeat: break
        case .connection(let id, let uuid, let platform, let state):
            if connections[id] != nil || connections.count < 64 { connections[id] = .init(uuid: uuid, platform: platform, state: state) }
        case .closed(let uuid): connections = connections.filter { $0.value.uuid != uuid }
        case .removed(let ids):
            if let featured = queue.featuredID, ids.contains(featured) { hide() }
            queue.discard(ids)
        }
    }
    var availableSlots: [LayerNode] {
        previewProgram?.stagedScene?.layers.filter { slots.contains($0.id) && $0.payload.isText } ?? []
    }
    func retainReadingPosition(_ id: String?) { queue.retainReadingPosition(id) }
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
        let header = caption.isEmpty ? "" : caption.joined(separator: " · ") + "\n"
        payload.text = header + message.text
        payload.commentHeaderUTF16Length = (header as NSString).length
        payload.commentPageIndex = 0
        payload.commentAvatarKey = nil
        avatarTasks[slotID]?.cancel(); avatarTasks[slotID] = nil
        payload.boxSizing = .fixed; payload.wraps = true; payload.overflow = .scaleDown
        payload.recordingChatMessageID = message.id
        let commands: [StudioCommand] = [.setLayerText(slotID, payload, in: scene.id), .setLayerVisibility(slotID, visible: true, in: scene.id)]
        guard let dispatcher else { return }
        for command in commands {
            if let reason = dispatcher.availabilityError(for: command) { error = reason.description; return }
        }
        for command in commands { if !run(command) { return } }
        queue.show(id)
        let binding = RecordingChatBinding(paint: .init(slotID: slotID.description, messageID: message.id,
            fingerprint: RecordingChatPaint.fingerprint(payload.text)), message: Self.recordingMessage(message))
        recentRecordingBindings.append(binding)
        if recentRecordingBindings.count > 128 { recentRecordingBindings.removeFirst() }
        recordingBindings.send(binding)
        if includeAvatar, message.avatarURL == nil { error = "This message has no public avatar; the comment remains available." }
        if includeAvatar, let url = message.avatarURL {
            guard CommentAvatarLoader.accepts(url) else { error = "This public avatar image host is unsupported; the comment remains available."; return }
            avatarTasks[slotID] = Task { @MainActor [weak self] in
                do {
                    let image = try await CommentAvatarLoader.load(url)
                    guard let self, !Task.isCancelled, self.includeAvatar,
                          let staged = self.previewProgram?.stagedScene, staged.id == scene.id,
                          let current = staged.layers.first(where: { $0.id == slotID }), current.isVisible,
                          case .text(var content) = current.payload, content.recordingChatMessageID == message.id else { return }
                    content.commentAvatarKey = CommentAvatarStore.shared.publish(image)
                    _ = self.run(.setLayerText(slotID, content, in: scene.id))
                    self.avatarTasks[slotID] = nil
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    self.error = "The public avatar could not be loaded; the comment remains available."
                    self.avatarTasks[slotID] = nil
                }
            }
        }
    }
    var selectedCommentPresentation: CommentTextLayout? {
        guard let layer = availableSlots.first(where: { $0.id == selectedSlot }), case .text(let text) = layer.payload,
              let header = text.commentHeaderUTF16Length else { return nil }
        let hasAvatar = CommentAvatarStore.shared.image(text.commentAvatarKey) != nil
        var key = layer
        if case .text(var canonical) = key.payload {
            canonical.commentPageIndex = 0
            if !hasAvatar { canonical.commentAvatarKey = nil }
            key.payload = .text(canonical)
        }
        if let cached = commentLayoutCache[key] { return cached }
        let layout = CommentTextLayout.make(text: text.text, headerLength: header, requestedFontSize: CGFloat(text.fontSize),
            minimumFontSize: 24, fontName: text.fontName,
            box: CGSize(width: max(1, layer.transform.size.width * 1920 - text.padding * 2
                        - (hasAvatar ? 64 + text.padding : 0)),
                        height: max(1, layer.transform.size.height * 1080 - text.padding * 2)), alignment: text.alignment)
        if commentLayoutCache.count >= 32 { commentLayoutCache.removeAll() }
        commentLayoutCache[key] = layout
        return layout
    }
    var selectedCommentPage: Int {
        guard let layer = availableSlots.first(where: { $0.id == selectedSlot }), case .text(let text) = layer.payload else { return 0 }
        return text.commentPageIndex
    }
    func advanceCommentPage(_ direction: Int) {
        guard let scene = previewProgram?.stagedScene,
              let layer = availableSlots.first(where: { $0.id == selectedSlot }), case .text(var text) = layer.payload,
              let layout = selectedCommentPresentation, !layout.pages.isEmpty else { return }
        text.commentPageIndex = min(layout.pages.count - 1, max(0, text.commentPageIndex + direction))
        _ = run(.setLayerText(layer.id, text, in: scene.id))
    }
    func dropMessage(_ id: String, into slotID: LayerID? = nil) -> Bool {
        guard queue.message(id) != nil else { return false }
        if let slotID { guard availableSlots.contains(where: { $0.id == slotID }) else { return false }; selectedSlot = slotID }
        guard selectedSlot != nil else { error = "Choose a staged comment slot first."; return false }
        show(id)
        return availableSlots.contains { layer in
            guard layer.id == selectedSlot, layer.isVisible, case .text(let text) = layer.payload else { return false }
            return text.recordingChatMessageID == id
        }
    }
    func hide() {
        guard let scene = previewProgram?.stagedScene, let slot = selectedSlot else { return }
        avatarTasks[slot]?.cancel(); avatarTasks[slot] = nil
        if run(.setLayerVisibility(slot, visible: false, in: scene.id)) { queue.hide() }
    }
    private static func recordingMessage(_ message: StudioChatMessage) -> RecordingChatMessage {
        .init(id: message.id, platform: message.platform, author: message.author, text: message.text,
            providerTimestamp: message.timestamp, timestampIsReceiptTime: message.timestampIsReceiptTime, kind: message.kind)
    }
    func shutdown() { directChat?.shutdown(); avatarTasks.values.forEach { $0.cancel() }; avatarTasks.removeAll(); restream.disconnectStudioSession() }
    private func run(_ command: StudioCommand) -> Bool {
        guard let dispatcher else { return false }
        if let reason = dispatcher.execute(command).error { error = reason.description; return false }
        error = nil; return true
    }
}
