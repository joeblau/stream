import Combine
import CoreGraphics
import Foundation
import StreamCore

enum StudioGuestPublicChatUpdate {
    case message(StudioChatMessage), removed, closed
}

@MainActor final class StudioChatCoordinator: ObservableObject {
    let restream = RestreamChat()
    let recordingMessages = PassthroughSubject<RecordingChatMessage, Never>()
    let recordingBindings = PassthroughSubject<RecordingChatBinding, Never>()
    let guestPublicUpdates = PassthroughSubject<StudioGuestPublicChatUpdate, Never>()
    private(set) var recentRecordingBindings: [RecordingChatBinding] = []
    @Published private(set) var directChat: StudioDirectChatManager?
    @Published private(set) var queue = StudioChatQueue()
    @Published private(set) var connections: [String: Connection] = [:]
    @Published var error: String?
    @Published var selectedSlot: LayerID?
    @Published var includeAuthor = true
    @Published var includePlatform = true
    @Published var includeAvatar = false
    @Published var staticEmotesEnabled = false { didSet { if !staticEmotesEnabled { cancelStaticEmoteLoads() } } }
    @Published private(set) var staticEmoteLoads = 0
    private struct EmoteLoad { let id: UUID; let task: Task<Void, Never> }
    private var emoteTasks: [LayerID: EmoteLoad] = [:]
    private var sourceEpochs: [String: UUID] = [:], emoteMessageEpochs: [String: UUID] = [:]
    private let staticEmoteResolve: (@MainActor (StudioChatMessage) async throws -> URL)?
    private let staticEmoteLoad: @Sendable (URL) async throws -> CGImage
    @Published var alertPromotionEnabled = false
    @Published var selectedAlertSlot: LayerID?
    @Published private(set) var audienceStyles: [StudioAudienceEventKind: StudioAudienceEventStyle] = [:]
    private var avatarTasks: [LayerID: Task<Void, Never>] = [:]
    private var commentLayoutCache: [LayerNode: CommentTextLayout] = [:]
    private weak var dispatcher: StudioCommandDispatcher?
    private weak var previewProgram: PreviewProgramModel?
    private var slots: Set<LayerID> = []
    private var alertSlots: Set<LayerID> = []
    private let slotsURL: URL
    private let audienceStylesURL: URL
    private var closed = false

    struct Connection { let uuid: String; let platform: String; let state: String }
    struct SlotPreferences: Codable { var version = 1; var slots: [LayerID]; var alertSlots: [LayerID]? = nil }
    private struct AudiencePreferences: Codable { var version = 1; var styles: [String: String] }

    init(dispatcher: StudioCommandDispatcher, previewProgram: PreviewProgramModel,
         staticEmoteResolve: (@MainActor (StudioChatMessage) async throws -> URL)? = nil,
         staticEmoteLoad: @escaping @Sendable (URL) async throws -> CGImage = { try await StudioStaticEmoteLoader.load($0) }) {
        self.staticEmoteResolve = staticEmoteResolve; self.staticEmoteLoad = staticEmoteLoad
        self.dispatcher = dispatcher; self.previewProgram = previewProgram
        slotsURL = DesktopStorage.projectDirectory.appendingPathComponent("comment-slots.json")
        audienceStylesURL = DesktopStorage.projectDirectory.appendingPathComponent("audience-styles.json")
        if let data = Self.preferenceData(at: slotsURL, limit: 65_536),
           let saved = try? JSONDecoder().decode(SlotPreferences.self, from: data), saved.version == 1,
           saved.slots.count + (saved.alertSlots?.count ?? 0) <= 16 {
            slots = Set(saved.slots)
            alertSlots = Set(saved.alertSlots ?? []).subtracting(slots)
        }
        if let data = Self.preferenceData(at: audienceStylesURL, limit: 4_096),
           let saved = try? JSONDecoder().decode(AudiencePreferences.self, from: data), saved.version == 1,
           saved.styles.count <= StudioAudienceEventKind.allCases.count {
            for (kind, style) in saved.styles {
                if let kind = StudioAudienceEventKind(rawValue: kind), let style = StudioAudienceEventStyle(rawValue: style) {
                    audienceStyles[kind] = style
                }
            }
        }
        restream.onStudioEnvelope = { [weak self] data in self?.receive(data) }
        // Signing out of one adapter cannot clear another adapter's messages,
        // curated queue, favorites, or reading position.
        restream.onStudioReset = { [weak self] in
            self?.cancelStaticEmoteLoads()
            self?.sourceEpochs = self?.sourceEpochs.filter { $0.key.hasPrefix("direct:") } ?? [:]
            self?.connections = self?.connections.filter { $0.key.hasPrefix("direct:") } ?? [:]
        }
    }
    private static func preferenceData(at url: URL, limit: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }
    func bindAccounts(_ accounts: ProviderAccountSession) {
        directChat?.shutdown()
        let manager = StudioDirectChatManager(request: { [weak accounts] provider, request in
            guard let accounts else { throw CancellationError() }; return try await accounts.chatRequest(provider, request)
        }, identity: { [weak accounts] provider in
            guard let accounts else { throw CancellationError() }; return try await accounts.chatIdentity(provider)
        }, presetDirectory: DesktopStorage.projectDirectory, emit: { [weak self] action in self?.receive(action) })
        directChat = manager; accounts.directChat = manager
    }
    func receive(_ data: Data) {
        guard let action = StudioRestreamDecoder.decode(data) else { return }
        receive(action)
    }
    func receive(_ action: StudioChatAction) {
        guard !closed else { return }
        switch action {
        case .message(let message):
            if queue.receive(message) {
                if message.staticEmote != nil, let source = sourceEpochs[message.connectionID], connections[message.connectionID]?.state == "Connected" {
                    emoteMessageEpochs[message.id] = source
                    if emoteMessageEpochs.count > 1_000 {
                        let retained = Set(queue.messages.map(\.id)); emoteMessageEpochs = emoteMessageEpochs.filter { retained.contains($0.key) }
                    }
                }
                recordingMessages.send(Self.recordingMessage(message))
                guestPublicUpdates.send(.message(message))
            }
        case .heartbeat: break
        case .connection(let id, let uuid, let platform, let state):
            if connections[id] != nil || connections.count < 64 {
                if connections[id]?.uuid != uuid || connections[id]?.state != state {
                    cancelStaticEmoteLoads(); sourceEpochs[id] = UUID()
                }
                connections[id] = .init(uuid: uuid, platform: platform, state: state)
            }
        case .closed(let uuid):
            cancelStaticEmoteLoads()
            for id in connections.keys where connections[id]?.uuid == uuid { sourceEpochs[id] = nil }
            connections = connections.filter { $0.value.uuid != uuid }
        case .removed(let ids):
            cancelStaticEmoteLoads(); for id in ids { emoteMessageEpochs[id] = nil }
            if let featured = queue.featuredID, ids.contains(featured) { hide() }
            queue.discard(ids)
            guestPublicUpdates.send(.removed)
            if availableAlertSlots.contains(where: { layer in
                guard case .text(let text) = layer.payload, let id = text.recordingChatMessageID else { return false }
                return ids.contains(id)
            }) { error = "An alert's source message was removed. Hide its staged card and Take to remove it from Program." }
        }
    }
    var guestPublicAvailable: Bool { !closed }
    var guestPublicAdapters: [String: String] {
        let restreamState: String
        switch restream.status {
        case .connected: restreamState = "connected"
        case .connecting: restreamState = "connecting"
        case .failed: restreamState = "failed"
        default: restreamState = "offline"
        }
        var result = ["restream": restreamState]
        for provider in [ManagedProvider.youtube, .twitch] {
            if let directChat {
                let value = directChat.snapshot(provider)
                result[provider.rawValue] = value.failure != nil ? "failed" : value.isConnected ? "connected" : "offline"
            } else { result[provider.rawValue] = "unavailable" }
        }
        return result
    }
    var guestPublicSources: [GuestPublicChatSource] {
        connections.keys.sorted().prefix(4).compactMap { id in
            guard let value = connections[id] else { return nil }
            return .init(id: Self.guestSourceID(id), platform: GuestPublicChatEnvelope.prefix(value.platform, bytes: 32),
                state: GuestPublicChatEnvelope.prefix(value.state, bytes: 64))
        }
    }
    var guestPublicSourcesTruncated: Bool {
        connections.count > 4 || connections.values.contains { $0.platform.utf8.count > 32 || $0.state.utf8.count > 64 }
    }
    static func guestSourceID(_ connection: String) -> String {
        String(StudioChatMessageIdentity.make(provider: "guest-public-source", messageID: connection).prefix(12))
    }
    static func guestPublicEntry(_ message: StudioChatMessage) -> GuestPublicChatEntry? {
        guard message.text.utf8.count <= 16_384, message.author.utf8.count <= 512,
              let kind = message.audienceEvent else { return nil }
        let body = GuestPublicChatEnvelope.prefix(message.text, bytes: 512)
        let author = GuestPublicChatEnvelope.prefix(message.author, bytes: 64)
        let platform = GuestPublicChatEnvelope.prefix(message.platform, bytes: 32)
        let roles = Array(message.roles.filter { ["Owner", "Moderator", "Member", "Verified", "VIP", "Bot"].contains($0) }.prefix(6))
        return .init(id: message.id, source: guestSourceID(message.connectionID), platform: platform, author: author,
            roles: roles, text: body, timestamp: message.timestamp.timeIntervalSince1970,
            receiptTime: message.timestampIsReceiptTime, kind: kind.rawValue,
            truncated: body != message.text || author != message.author || platform != message.platform || roles != message.roles)
    }
    var availableSlots: [LayerNode] {
        previewProgram?.stagedScene?.layers.filter { slots.contains($0.id) && $0.payload.isText } ?? []
    }
    var availableAlertSlots: [LayerNode] {
        previewProgram?.stagedScene?.layers.filter { alertSlots.contains($0.id) && $0.payload.isText } ?? []
    }
    func audienceStyle(for kind: StudioAudienceEventKind) -> StudioAudienceEventStyle {
        audienceStyles[kind] ?? kind.defaultStyle
    }
    func setAudienceStyle(_ style: StudioAudienceEventStyle, for kind: StudioAudienceEventKind) {
        guard !closed else { return }
        audienceStyles[kind] = style
        do {
            let values = Dictionary(uniqueKeysWithValues: audienceStyles.map { ($0.key.rawValue, $0.value.rawValue) })
            try JSONEncoder().encode(AudiencePreferences(styles: values)).write(to: audienceStylesURL, options: .atomic)
        } catch { self.error = "The audience event style could not be saved." }
    }
    var audienceStagingError: String? {
        guard !closed else { return "This chat session has ended." }
        guard previewProgram?.stagedScene != nil else { return "Choose a staged scene first." }
        return previewProgram?.directLiveEditing == true ? "Turn off Direct Live Editing before staging an audience alert. Take publishes the card." : nil
    }
    var alertSlotCreationError: String? {
        if let reason = audienceStagingError { return reason }
        return slots.count + alertSlots.count >= 16 ? "Comment and alert slots share a sixteen-slot limit." : nil
    }
    func audienceAlertError(for id: String) -> String? {
        guard alertPromotionEnabled else { return "Enable manual audience alerts first." }
        guard queue.message(id)?.audienceEvent?.supportsAlert == true else { return "This message has no supported audience alert type." }
        if let reason = audienceStagingError { return reason }
        guard availableAlertSlots.contains(where: { $0.id == selectedAlertSlot }) else { return "Create or select a separate staged alert slot first." }
        return nil
    }
    func retainReadingPosition(_ id: String?) { queue.retainReadingPosition(id) }
    func favorite(_ id: String) { queue.favorite(id) }
    func enqueue(_ id: String) { queue.enqueue(id) }
    func dequeue(_ id: String) { queue.remove(id) }
    func select(_ id: String) { queue.select(id) }
    func advance(_ direction: Int) { queue.advance(direction) }
    func createSlot() { createSlot(alert: false) }
    func createAlertSlot() {
        if let reason = alertSlotCreationError { error = reason; return }
        createSlot(alert: true)
    }
    private func createSlot(alert: Bool) {
        guard slots.count + alertSlots.count < 16, let scene = previewProgram?.stagedScene else { return }
        let before = Set(scene.layers.map(\.id))
        var payload = TextSourcePayload(text: "")
        payload.fontSize = 42; payload.backgroundColorHex = "#171717E6"
        payload.padding = 20; payload.overflow = .scaleDown
        guard run(.addLayer(.text(payload), in: scene.id)),
              let layer = previewProgram?.stagedScene?.layers.first(where: { !before.contains($0.id) }) else { return }
        let transform = LayerTransform(position: .init(x: 0.08, y: 0.65), size: .init(width: 0.84, height: 0.28), anchor: .topLeft)
        guard run(.renameLayer(layer.id, to: alert ? "Audience Alert Slot" : "Comment Slot", in: scene.id)),
              run(.setLayerTransform(layer.id, transform, in: scene.id)),
              run(.setLayerVisibility(layer.id, visible: false, in: scene.id)) else { return }
        if alert { alertSlots.insert(layer.id); selectedAlertSlot = layer.id }
        else { slots.insert(layer.id); selectedSlot = layer.id }
        do { try JSONEncoder().encode(SlotPreferences(slots: slots.sorted { $0.description < $1.description },
            alertSlots: alertSlots.sorted { $0.description < $1.description })).write(to: slotsURL, options: .atomic) }
        catch { self.error = "The comment slot could not be saved." }
    }
    @discardableResult func stageAudienceAlert(_ id: String) -> Bool { stageAudienceAlert(id, staticEmoteKey: nil) }
    private func stageAudienceAlert(_ id: String, staticEmoteKey: String?) -> Bool {
        if let reason = audienceAlertError(for: id) { error = reason; return false }
        guard let message = queue.message(id), let kind = message.audienceEvent,
              let scene = previewProgram?.stagedScene, let slot = selectedAlertSlot,
              let layer = availableAlertSlots.first(where: { $0.id == slot }), case .text(var text) = layer.payload else { return false }
        let header = [kind.rawValue, includeAuthor ? message.author : nil, includePlatform ? message.platform : nil]
            .compactMap { $0 }.joined(separator: " · ") + "\n"
        let style = audienceStyle(for: kind)
        text.text = header + message.text
        text.colorHex = style.foreground; text.backgroundColorHex = style.background
        text.commentHeaderUTF16Length = (header as NSString).length; text.commentPageIndex = 0
        text.commentAvatarKey = staticEmoteKey; text.recordingChatMessageID = message.id
        text.boxSizing = .fixed; text.wraps = true; text.overflow = .scaleDown
        text.timer = nil; text.ticker = nil; text.timing = nil; text.guestBinding = nil
        let commands: [StudioCommand] = [.setLayerText(slot, text, in: scene.id), .setLayerVisibility(slot, visible: true, in: scene.id)]
        guard let dispatcher else { return false }
        for command in commands {
            if let reason = dispatcher.availabilityError(for: command) { error = reason.description; return false }
        }
        for command in commands { if !run(command) { return false } }
        let binding = RecordingChatBinding(paint: .init(slotID: slot.description, messageID: id,
            fingerprint: RecordingChatPaint.fingerprint(text.text)), message: Self.recordingMessage(message))
        recentRecordingBindings.append(binding)
        if recentRecordingBindings.count > 128 { recentRecordingBindings.removeFirst() }
        recordingBindings.send(binding)
        return true
    }
    func hideAudienceAlert() {
        if let reason = audienceStagingError { error = reason; return }
        guard let scene = previewProgram?.stagedScene, let slot = selectedAlertSlot,
              availableAlertSlots.contains(where: { $0.id == slot }) else { return }
        _ = run(.setLayerVisibility(slot, visible: false, in: scene.id))
    }
    /// Compatibility entry point uses the same explicit, guarded staged alert route.
    func promoteAlert(_ id: String) { _ = stageAudienceAlert(id) }
    func show(_ id: String) { show(id, staticEmoteKey: nil) }
    private func show(_ id: String, staticEmoteKey: String?) {
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
        payload.commentAvatarKey = staticEmoteKey
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
        if staticEmoteKey == nil, includeAvatar, message.avatarURL == nil { error = "This message has no public avatar; the comment remains available." }
        if staticEmoteKey == nil, includeAvatar, let url = message.avatarURL {
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
    private func cancelStaticEmoteLoads() {
        emoteTasks.values.forEach { $0.task.cancel() }; emoteTasks.removeAll(); staticEmoteLoads = 0
    }
    func staticEmoteStagingError(for id: String, alert: Bool) -> String? {
        guard staticEmotesEnabled else { return "Enable manual static Twitch emote tiles first." }
        if let reason = audienceStagingError { return reason }
        guard let message = queue.message(id), message.platform == "Twitch", message.staticEmote?.valid == true,
              message.connectionID.hasPrefix("direct:twitch:"), connections[message.connectionID]?.state == "Connected",
              let epoch = sourceEpochs[message.connectionID], emoteMessageEpochs[id] == epoch else {
            return "This message has no supported static emote from the current authorized Twitch reader. Text remains available."
        }
        guard let metadata = message.staticEmote, CommentAvatarStore.shared.canPublishStaticEmote(metadata.id) else {
            return "This app run's 32 static emote identities are full. Text and existing taken tiles remain available."
        }
        if alert, let reason = audienceAlertError(for: id) { return reason }
        let slot = alert ? selectedAlertSlot : selectedSlot
        guard let slot, (alert ? availableAlertSlots : availableSlots).contains(where: { $0.id == slot }) else { return "Choose a staged comment or alert slot first." }
        guard emoteTasks[slot] == nil, emoteTasks.count < 2 else { return "Wait for the bounded artwork loads to finish." }
        return nil
    }
    /// Deliberate first-static-emote tile, beside the untouched public caption.
    /// Network completion may edit only the exact still-current staged slot.
    @discardableResult func stageStaticEmote(_ id: String, alert: Bool) -> Bool {
        if let reason = staticEmoteStagingError(for: id, alert: alert) { error = reason; return false }
        guard let message = queue.message(id), let metadata = message.staticEmote,
              let scene = previewProgram?.stagedScene, let slot = alert ? selectedAlertSlot : selectedSlot,
              let layer = scene.layers.first(where: { $0.id == slot }), let epoch = sourceEpochs[message.connectionID] else { return false }
        let resolve: @MainActor (StudioChatMessage) async throws -> URL
        if let supplied = staticEmoteResolve { resolve = supplied }
        else {
            guard let manager = directChat else { error = "The authorized Twitch reader is unavailable."; return false }
            resolve = { [weak manager] value in
                guard let manager else { throw CancellationError() }; return try await manager.staticEmoteURL(for: value)
            }
        }
        let load = staticEmoteLoad, ticket = UUID()
        let author = includeAuthor, platform = includePlatform
        let style = message.audienceEvent.map { audienceStyle(for: $0) }
        let task = Task { @MainActor [weak self] in
            do {
                let cached = CommentAvatarStore.shared.staticEmoteKey(metadata.id)
                var downloaded: CGImage?
                if cached == nil {
                    let url = try await resolve(message)
                    try Task.checkCancellation()
                    guard StudioStaticEmoteLoader.accepts(url) else { throw ProviderFailure(.invalidResponse) }
                    downloaded = try await load(url)
                    try Task.checkCancellation()
                }
                guard let self, !Task.isCancelled, !self.closed, self.staticEmotesEnabled,
                      self.emoteTasks[slot]?.id == ticket, self.audienceStagingError == nil,
                      !alert || self.alertPromotionEnabled, self.queue.message(id) == message,
                      self.includeAuthor == author, self.includePlatform == platform,
                      !alert || message.audienceEvent.map({ self.audienceStyle(for: $0) }) == style,
                      self.sourceEpochs[message.connectionID] == epoch, self.emoteMessageEpochs[id] == epoch,
                      self.connections[message.connectionID]?.state == "Connected",
                      self.previewProgram?.stagedScene?.id == scene.id,
                      self.previewProgram?.stagedScene?.layers.first(where: { $0.id == slot }) == layer,
                      (alert ? self.selectedAlertSlot : self.selectedSlot) == slot else {
                    self?.finishStaticEmote(slot, ticket: ticket); return
                }
                let key: String
                if let cached { key = cached }
                else if let downloaded, let published = CommentAvatarStore.shared.publishStaticEmote(downloaded, identity: metadata.id) { key = published }
                else { throw RecordingChatError.invalid("This app run's 32 static emote identities are full; existing taken artwork is retained. Text remains available.") }
                if alert { _ = self.stageAudienceAlert(id, staticEmoteKey: key) }
                else { self.show(id, staticEmoteKey: key) }
                self.finishStaticEmote(slot, ticket: ticket)
            } catch {
                guard let self, !Task.isCancelled, self.emoteTasks[slot]?.id == ticket else { return }
                self.error = "Static emote artwork could not be staged; text remains available. \(error.localizedDescription)"
                self.finishStaticEmote(slot, ticket: ticket)
            }
        }
        emoteTasks[slot] = .init(id: ticket, task: task); staticEmoteLoads = emoteTasks.count
        return true
    }
    private func finishStaticEmote(_ slot: LayerID, ticket: UUID) {
        if emoteTasks[slot]?.id == ticket { emoteTasks[slot] = nil; staticEmoteLoads = emoteTasks.count }
    }
    var selectedCommentPresentation: CommentTextLayout? {
        commentPresentation(for: availableSlots.first(where: { $0.id == selectedSlot }))
    }
    var selectedAlertPresentation: CommentTextLayout? {
        commentPresentation(for: availableAlertSlots.first(where: { $0.id == selectedAlertSlot }))
    }
    private func commentPresentation(for candidate: LayerNode?) -> CommentTextLayout? {
        guard let layer = candidate, case .text(let text) = layer.payload,
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
    var selectedAlertPage: Int {
        guard let layer = availableAlertSlots.first(where: { $0.id == selectedAlertSlot }), case .text(let text) = layer.payload else { return 0 }
        return text.commentPageIndex
    }
    func advanceAudienceAlertPage(_ direction: Int) {
        if let reason = audienceStagingError { error = reason; return }
        guard let scene = previewProgram?.stagedScene,
              let layer = availableAlertSlots.first(where: { $0.id == selectedAlertSlot }), case .text(var text) = layer.payload,
              let layout = selectedAlertPresentation, !layout.pages.isEmpty else { return }
        text.commentPageIndex = min(layout.pages.count - 1, max(0, text.commentPageIndex + direction))
        _ = run(.setLayerText(layer.id, text, in: scene.id))
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
    func shutdown() {
        guard !closed else { return }
        closed = true; alertPromotionEnabled = false; staticEmotesEnabled = false; cancelStaticEmoteLoads()
        guestPublicUpdates.send(.closed)
        directChat?.shutdown(); avatarTasks.values.forEach { $0.cancel() }; avatarTasks.removeAll(); restream.disconnectStudioSession()
    }
    private func run(_ command: StudioCommand) -> Bool {
        guard !closed, let dispatcher else { return false }
        if let reason = dispatcher.execute(command).error { error = reason.description; return false }
        error = nil; return true
    }
}
