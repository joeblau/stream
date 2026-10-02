import Combine
import Foundation
import StreamCore

struct DirectChatIdentity: Sendable { let channelID: String; let scopes: [String] }
struct DirectChatSnapshot {
    var state = "Offline"
    var target = ""
    var isConnected = false
    var failure: String?
    var notice: String?
    var isMutating = false
    var retryUntil: Date?
}

/// One authenticated reader per provider feeds every workspace consumer. No
/// reader starts on load, sign-in or wake. Requests and sockets are injectable.
@MainActor final class StudioDirectChatManager: ObservableObject {
    typealias Request = @MainActor (ManagedProvider, URLRequest) async throws -> Data
    typealias Identity = @MainActor (ManagedProvider) async throws -> DirectChatIdentity
    typealias Sleep = @Sendable (Double) async throws -> Void
    @Published private(set) var snapshots: [ManagedProvider: DirectChatSnapshot] = [.youtube: .init(), .twitch: .init()]
    @Published private(set) var receipts: [DirectChatWriteReceipt] = []
    let presets: StudioChatPresetStore
    private let request: Request
    private let identity: Identity
    private let socketFactory: @Sendable (URL) -> any StudioChatSocket
    private let sleep: Sleep
    private let deadlineSleep: Sleep
    private let emit: (StudioChatAction) -> Void
    private var generations: [ManagedProvider: UUID] = [:]
    private var jobs: [ManagedProvider: Task<Void, Never>] = [:]
    private var writes: [ManagedProvider: Task<Void, Never>] = [:]
    private var writeIDs: [ManagedProvider: UUID] = [:]
    private var writeDenials: [ManagedProvider: Set<DirectChatWriteKind>] = [:]
    private var cooldowns: [ManagedProvider: Date] = [:]
    private let now: @Sendable () -> Date
    private var active: [ManagedProvider: (DirectChatIdentity, String)] = [:]
    private var routes: [String: DirectChatRoute] = [:]
    private var routeOrder: [String] = []
    private var cycles: [UUID: Cycle] = [:]
    private var currentCycle: UUID?
    private var reconnectAttempts = 0
    private final class Cycle {
        let id = UUID()
        let socket: any StudioChatSocket
        let migration: Bool
        var task: Task<Void, Never>?
        var watchdog: Task<Void, Never>?
        var timeout: Double = 10
        var subscribed = false
        var expired = false
        init(socket: any StudioChatSocket, migration: Bool) { self.socket = socket; self.migration = migration }
        func cancel() { task?.cancel(); watchdog?.cancel(); socket.cancel() }
    }
    init(request: @escaping Request, identity: @escaping Identity,
         socketFactory: @escaping @Sendable (URL) -> any StudioChatSocket = { NativeStudioChatSocket($0) },
         sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) },
         deadlineSleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) },
         presetDirectory: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }, emit: @escaping (StudioChatAction) -> Void) {
        self.request = request; self.identity = identity; self.socketFactory = socketFactory; self.sleep = sleep
        self.deadlineSleep = deadlineSleep; self.emit = emit
        self.presets = StudioChatPresetStore(directory: presetDirectory); self.now = now
    }
    func snapshot(_ provider: ManagedProvider) -> DirectChatSnapshot { snapshots[provider] ?? .init() }
    func stop(_ provider: ManagedProvider) {
        let old = generations[provider]
        generations[provider] = UUID(); jobs[provider]?.cancel(); jobs[provider] = nil
        cancelWrite(provider); active[provider] = nil
        if provider == .twitch { cancelCycles(); reconnectAttempts = 0 }
        if let old { emit(.closed(uuid: old.uuidString)) }
        snapshots[provider] = .init(retryUntil: cooldowns[provider])
    }
    func shutdown() { stop(.youtube); stop(.twitch) }
    private func current(_ provider: ManagedProvider, _ generation: UUID) -> Bool {
        generations[provider] == generation && !Task.isCancelled
    }
    private func status(_ provider: ManagedProvider, _ generation: UUID, _ state: String, connected: Bool = false) {
        guard current(provider, generation) else { return }
        snapshots[provider]?.state = state; snapshots[provider]?.isConnected = connected
        if let (_, chatID) = active[provider] {
            emit(.connection(id: StudioDirectChatDecoder.connection(provider, chatID), uuid: generation.uuidString,
                             platform: provider.name, state: state))
        }
    }
    func connect(_ provider: ManagedProvider, eventID: String = "") {
        guard [.youtube, .twitch].contains(provider) else { return }
        stop(provider); let generation = UUID(); generations[provider] = generation
        writeDenials[provider] = []
        snapshots[provider]?.state = "Verifying authorization"
        jobs[provider] = Task { [weak self] in
            guard let self else { return }
            do {
                let account = try await identity(provider)
                guard current(provider, generation) else { return }
                if provider == .youtube {
                    guard account.scopes.contains("https://www.googleapis.com/auth/youtube") || account.scopes.contains("https://www.googleapis.com/auth/youtube.force-ssl") else {
                        throw ProviderFailure(.permission)
                    }
                    guard ProviderChannel.validID(eventID) else { throw ProviderFailure(.invalidRequest) }
                    let data = try await request(.youtube, ProviderAPI.request(.youtube, path: "/youtube/v3/liveBroadcasts",
                        query: ["part": "snippet,status", "id": eventID]))
                    let object = try StudioDirectChatDecoder.object(data, limit: 2_097_152)
                    guard let rows = object["items"] as? [[String: Any]], rows.count == 1, rows[0]["id"] as? String == eventID,
                          let snippet = rows[0]["snippet"] as? [String: Any], snippet["channelId"] as? String == account.channelID,
                          let chatID = StudioDirectChatDecoder.identifier(snippet["liveChatId"]),
                          let state = rows[0]["status"] as? [String: Any], state["lifeCycleStatus"] as? String == "live" else {
                        throw ProviderFailure(.unavailable)
                    }
                    guard current(provider, generation) else { return }
                    active[provider] = (account, chatID); snapshots[provider]?.target = eventID
                    snapshots[provider]?.notice = "YouTube REST polling follows the provider interval; limited recent history and quota apply."
                    try await readYouTube(account: account, chatID: chatID, generation: generation)
                } else {
                    guard account.scopes.contains("user:read:chat"), ProviderChannel.validID(account.channelID) else { throw ProviderFailure(.permission) }
                    active[provider] = (account, account.channelID); snapshots[provider]?.target = account.channelID
                    snapshots[provider]?.notice = "Own-channel public EventSub chat. A lost session may leave an unrecoverable message gap."
                    startSocket(URL(string: "wss://eventsub.wss.twitch.tv/ws")!, account: account, generation: generation, migration: false)
                }
            } catch {
                guard current(provider, generation) else { return }; failed(provider, generation, error)
            }
        }
    }
    private func readYouTube(account: DirectChatIdentity, chatID: String, generation: UUID) async throws {
        var page: String?
        while current(.youtube, generation) {
            var query = ["part": "id,snippet,authorDetails", "liveChatId": chatID, "maxResults": "200"]
            if let page { query["pageToken"] = page }
            let data: Data
            do { data = try await request(.youtube, ProviderAPI.request(.youtube, path: "/youtube/v3/liveChat/messages", query: query)) }
            catch let failure as ProviderFailure where failure.kind == .rateLimited {
                guard current(.youtube, generation) else { return }
                let seconds = failure.retryAfter.flatMap { $0.isFinite ? min(86400, max(1, $0)) : nil } ?? 60
                let until = now().addingTimeInterval(seconds)
                cooldowns[.youtube] = until; snapshots[.youtube]?.retryUntil = until
                status(.youtube, generation, "Rate limited; waiting to resume reading")
                snapshots[.youtube]?.notice = "The queue is retained. Only the read request resumes after cooldown; no public action is replayed."
                try await sleep(seconds); continue
            }
            let result = try StudioDirectChatDecoder.youtube(data, channelID: account.channelID, chatID: chatID)
            guard current(.youtube, generation) else { return }
            status(.youtube, generation, "Connected", connected: true)
            for delivery in result.deliveries { receive(delivery) }
            remove(result.removedIDs)
            for author in result.bannedAuthors { clear(provider: .youtube, chatID: chatID, author: author) }
            if result.ended { status(.youtube, generation, "Chat ended"); active[.youtube] = nil; return }
            page = result.nextPage
            try await sleep(result.interval)
        }
    }
    private func receive(_ delivery: DirectChatDelivery) {
        let id = delivery.message.id
        if routes[id] == nil {
            routes[id] = delivery.route; routeOrder.append(id)
            while routeOrder.count > 4_000 { routes.removeValue(forKey: routeOrder.removeFirst()) }
        }
        emit(.message(delivery.message))
    }
    private func remove(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        for id in ids { routes.removeValue(forKey: id) }
        routeOrder.removeAll { ids.contains($0) }; emit(.removed(ids: ids))
    }
    private func clear(provider: ManagedProvider, chatID: String, author: String? = nil) {
        let ids = routes.filter { $0.value.provider == provider && $0.value.chatID == chatID && (author == nil || $0.value.authorID == author) }.map(\.key)
        remove(ids)
    }
    private func failed(_ provider: ManagedProvider, _ generation: UUID, _ error: Error) {
        guard current(provider, generation) else { return }
        status(provider, generation, "Failed")
        snapshots[provider]?.failure = (error as? ProviderFailure ?? ProviderFailure(.unavailable)).localizedDescription
        active[provider] = nil
        if provider == .twitch { cancelCycles() }
        generations[provider] = UUID(); jobs[provider]?.cancel(); jobs[provider] = nil
        cancelWrite(provider)
        emit(.closed(uuid: generation.uuidString))
    }
    private func cancelCycles() {
        for cycle in cycles.values { cycle.cancel() }; cycles = [:]; currentCycle = nil
    }
    private func arm(_ cycle: Cycle) {
        cycle.watchdog?.cancel()
        let seconds = cycle.timeout
        let wait = deadlineSleep
        cycle.watchdog = Task { [weak cycle] in
            do { try await wait(seconds) } catch { return }
            guard !Task.isCancelled else { return }; cycle?.expired = true; cycle?.socket.cancel()
        }
    }
    private func startSocket(_ url: URL, account: DirectChatIdentity, generation: UUID, migration: Bool) {
        guard current(.twitch, generation), cycles.count < 2 else { return }
        let cycle = Cycle(socket: socketFactory(url), migration: migration); cycles[cycle.id] = cycle; arm(cycle)
        cycle.task = Task { [weak self, weak cycle] in
            guard let self, let cycle else { return }
            do {
                while current(.twitch, generation), cycles[cycle.id] != nil {
                    let data = try await cycle.socket.receive()
                    guard current(.twitch, generation), cycles[cycle.id] != nil else { return }
                    let envelope = try StudioDirectChatDecoder.twitch(data, channelID: account.channelID, userID: account.channelID)
                    arm(cycle)
                    if envelope.type == "session_welcome" {
                        guard !cycle.subscribed, let sessionID = envelope.sessionID else { throw ProviderFailure(.invalidResponse) }
                        cycle.timeout = envelope.timeout!
                        if !cycle.migration { try await subscribe(sessionID, account: account, generation: generation) }
                        guard current(.twitch, generation), cycles[cycle.id] != nil else { return }
                        guard !cycle.expired else { throw URLError(.timedOut) }
                        cycle.subscribed = true; currentCycle = cycle.id
                        for old in Array(cycles.values) where old.id != cycle.id { old.cancel(); cycles[old.id] = nil }
                        arm(cycle); status(.twitch, generation, "Connected", connected: true)
                    } else {
                        guard cycle.subscribed else { throw ProviderFailure(.invalidResponse) }
                        if let url = envelope.reconnectURL {
                            guard currentCycle == cycle.id else { continue }
                            startSocket(url, account: account, generation: generation, migration: true)
                        }
                        if let delivery = envelope.delivery { receive(delivery) }
                        if let id = envelope.removedID { remove([id]) }
                        if envelope.clearAll { clear(provider: .twitch, chatID: account.channelID) }
                        if let author = envelope.clearedAuthor { clear(provider: .twitch, chatID: account.channelID, author: author) }
                    }
                }
            } catch {
                guard current(.twitch, generation), cycles[cycle.id] != nil else { return }
                // Do not cancel this task before its failure/retry transition:
                // current() deliberately rejects cancelled continuations.
                cycle.watchdog?.cancel(); cycle.socket.cancel(); cycle.task = nil; cycles[cycle.id] = nil
                if cycle.migration, currentCycle != cycle.id, currentCycle != nil {
                    snapshots[.twitch]?.notice = "Socket migration failed; the previous reader remains active until it disconnects."
                    return
                }
                if let failure = error as? ProviderFailure { failed(.twitch, generation, failure); return }
                cancelCycles(); reconnectAttempts += 1
                guard reconnectAttempts <= 3 else { failed(.twitch, generation, error); return }
                status(.twitch, generation, "Reconnecting")
                snapshots[.twitch]?.notice = "Connection interrupted. Messages sent during the gap cannot be replayed."
                jobs[.twitch] = Task { [weak self] in
                    guard let self else { return }
                    do { try await sleep(pow(2, Double(reconnectAttempts - 1))) } catch { return }
                    guard current(.twitch, generation) else { return }
                    startSocket(URL(string: "wss://eventsub.wss.twitch.tv/ws")!, account: account, generation: generation, migration: false)
                }
            }
        }
    }
    private func subscribe(_ sessionID: String, account: DirectChatIdentity, generation: UUID) async throws {
        for type in ["channel.chat.message", "channel.chat.message_delete", "channel.chat.clear", "channel.chat.clear_user_messages"] {
            var call = try ProviderAPI.request(.twitch, path: "/helix/eventsub/subscriptions")
            call.httpMethod = "POST"; call.setValue("application/json", forHTTPHeaderField: "Content-Type")
            call.httpBody = try JSONSerialization.data(withJSONObject: ["type": type, "version": "1",
                "condition": ["broadcaster_user_id": account.channelID, "user_id": account.channelID],
                "transport": ["method": "websocket", "session_id": sessionID]])
            let result = try StudioDirectChatDecoder.object(try await request(.twitch, call))
            guard current(.twitch, generation) else { throw CancellationError() }
            guard let rows = result["data"] as? [[String: Any]], rows.count == 1, rows[0]["status"] as? String == "enabled",
                  rows[0]["type"] as? String == type, rows[0]["version"] as? String == "1",
                  let condition = rows[0]["condition"] as? [String: Any], condition["broadcaster_user_id"] as? String == account.channelID,
                  condition["user_id"] as? String == account.channelID,
                  let transport = rows[0]["transport"] as? [String: Any], transport["method"] as? String == "websocket",
                  transport["session_id"] as? String == sessionID else { throw ProviderFailure(.invalidResponse) }
        }
    }
    func writeTarget(_ provider: ManagedProvider) -> DirectChatWriteTarget? {
        guard snapshot(provider).isConnected, let (account, chatID) = active[provider], let generation = generations[provider] else { return nil }
        return .init(provider: provider, channelID: account.channelID, chatID: chatID,
                     broadcastID: snapshot(provider).target, generation: generation)
    }
    func sendAvailabilityError(_ provider: ManagedProvider) -> String? { writeAvailabilityError(provider, kind: .post) }
    private func writeAvailabilityError(_ provider: ManagedProvider, kind: DirectChatWriteKind) -> String? {
        guard [.youtube, .twitch].contains(provider) else { return "This provider feed is read-only in Stream." }
        guard snapshot(provider).isConnected, let (account, _) = active[provider] else { return "Connect and verify an owned direct public chat first." }
        guard !snapshot(provider).isMutating else { return "Another action is waiting for this provider." }
        if let until = cooldowns[provider], until > now() { return "Provider rate limit: wait until \(until.formatted(date: .omitted, time: .standard))." }
        if writeDenials[provider]?.contains(kind) == true { return "This permission was denied. Reconnect and verify the account before retrying." }
        let required: String?
        switch (provider, kind) {
        case (.twitch, .post), (.twitch, .reply): required = "user:write:chat"
        case (.twitch, .delete): required = "moderator:manage:chat_messages"
        case (.twitch, .timeout), (.twitch, .ban): required = "moderator:manage:banned_users"
        default: required = nil
        }
        if let required, !account.scopes.contains(required) { return "Reauthorize with the optional \(required) grant." }
        if provider == .youtube && !account.scopes.contains("https://www.googleapis.com/auth/youtube") &&
            !account.scopes.contains("https://www.googleapis.com/auth/youtube.force-ssl") { return "A granted YouTube write scope is required." }
        return nil
    }
    func canSend(_ provider: ManagedProvider) -> Bool { sendAvailabilityError(provider) == nil }
    func moderationAvailabilityError(_ id: String, kind: DirectChatWriteKind) -> String? {
        guard [.delete, .timeout, .ban].contains(kind) else { return "Choose a supported moderation action." }
        guard let route = routes[id] else { return "This message has no current authorized direct-provider route; this feed is read-only." }
        if let error = writeAvailabilityError(route.provider, kind: kind) { return error }
        guard let (account, chatID) = active[route.provider], chatID == route.chatID else { return "This message belongs to a different chat session." }
        guard account.channelID != route.authorID, !route.roles.contains("Owner"), !route.roles.contains("Moderator") else {
            return "Owner and moderator messages are protected. Manage their roles in the provider's controls."
        }
        if kind == .delete, route.provider == .twitch, now().timeIntervalSince(route.timestamp) >= 21600 {
            return "Twitch only allows targeted deletion of messages less than six hours old."
        }
        return nil
    }
    func canDelete(_ id: String) -> Bool { moderationAvailabilityError(id, kind: .delete) == nil }
    func canReply(_ id: String) -> Bool {
        guard let route = routes[id], route.provider == .twitch, let (_, chatID) = active[.twitch], chatID == route.chatID else { return false }
        return writeAvailabilityError(.twitch, kind: .reply) == nil
    }
    func targetForMessage(_ id: String) -> DirectChatWriteTarget? { routes[id].flatMap { writeTarget($0.provider) } }
    /// A reviewed batch contains at most the two supported direct providers.
    /// Each target executes once; a failure cannot cancel another provider.
    @discardableResult func send(_ text: String, to targets: [DirectChatWriteTarget]) -> [UUID] {
        guard !targets.isEmpty, targets.count <= 2, Set(targets.map(\.provider)).count == targets.count else { return [] }
        let batch = UUID()
        return targets.map { send(text, provider: $0.provider, expectedTarget: $0, batchID: batch) }
    }
    @discardableResult func send(_ text: String, provider: ManagedProvider, replyingTo id: String? = nil,
                                expectedTarget: DirectChatWriteTarget? = nil, batchID: UUID = UUID()) -> UUID {
        let kind: DirectChatWriteKind = id == nil ? .post : .reply
        let target = expectedTarget ?? writeTarget(provider)
        let receipt = appendReceipt(provider, target: target?.broadcastID ?? snapshot(provider).target, kind: kind,
                                    summary: text, batchID: batchID)
        let error = writeAvailabilityError(provider, kind: kind)
        guard error == nil, let target, target.provider == provider, target == writeTarget(provider) else {
            finishReceipt(receipt, .notSent(error ?? "The reviewed account or broadcast changed. Review its new target.")); return receipt
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= (provider == .twitch ? 500 : 200), text.utf8.count <= 4096,
              id == nil || (provider == .twitch && canReply(id!)) else {
            finishReceipt(receipt, .notSent("Review the message length and current reply target.")); return receipt
        }
        let reply = id.flatMap { routes[$0]?.providerMessageID }
        mutate(target, receipt: receipt, kind: kind) { [request] in
            var call = try ProviderAPI.request(provider, path: provider == .youtube ? "/youtube/v3/liveChat/messages" : "/helix/chat/messages",
                query: provider == .youtube ? ["part": "snippet"] : [:])
            call.httpMethod = "POST"; call.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if provider == .youtube {
                call.httpBody = try JSONSerialization.data(withJSONObject: ["snippet": ["liveChatId": target.chatID, "type": "textMessageEvent", "textMessageDetails": ["messageText": text]]])
            } else {
                var body: [String: Any] = ["broadcaster_id": target.channelID, "sender_id": target.channelID, "message": text]
                if let reply { body["reply_parent_message_id"] = reply }
                call.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let result = try StudioDirectChatDecoder.object(try await request(provider, call))
            if provider == .twitch {
                guard let rows = result["data"] as? [[String: Any]], rows.count == 1, let sent = rows[0]["is_sent"] as? Bool else { throw ProviderFailure(.invalidResponse) }
                guard sent else { throw WriteRefusal() }
                guard StudioDirectChatDecoder.identifier(rows[0]["message_id"]) != nil else { throw ProviderFailure(.invalidResponse) }
            } else { guard StudioDirectChatDecoder.identifier(result["id"]) != nil else { throw ProviderFailure(.invalidResponse) } }
        }
        return receipt
    }
    @discardableResult func delete(_ id: String, expectedTarget: DirectChatWriteTarget? = nil) -> UUID? {
        moderate(id, kind: .delete, expectedTarget: expectedTarget)
    }
    /// UI timeouts are deliberately fixed at ten minutes. No arbitrary numeric
    /// value or untrusted message text can become a provider moderation command.
    @discardableResult func moderate(_ id: String, kind: DirectChatWriteKind,
                                    expectedTarget: DirectChatWriteTarget? = nil) -> UUID? {
        guard [.delete, .timeout, .ban].contains(kind), let route = routes[id] else { return nil }
        let target = expectedTarget ?? writeTarget(route.provider)
        let receipt = appendReceipt(route.provider, target: target?.broadcastID ?? snapshot(route.provider).target,
                                    kind: kind, summary: kind == .delete ? route.providerMessageID : route.authorID)
        let error = moderationAvailabilityError(id, kind: kind)
        guard error == nil, let target, target == writeTarget(route.provider), target.provider == route.provider else {
            finishReceipt(receipt, .notSent(error ?? "The reviewed account or broadcast changed. Review its new target.")); return receipt
        }
        mutate(target, receipt: receipt, kind: kind) { [request] in
            if kind == .delete {
                let query = route.provider == .youtube ? ["id": route.providerMessageID] : ["broadcaster_id": route.channelID,
                    "moderator_id": target.channelID, "message_id": route.providerMessageID]
                var call = try ProviderAPI.request(route.provider, path: route.provider == .youtube ? "/youtube/v3/liveChat/messages" : "/helix/moderation/chat", query: query)
                call.httpMethod = "DELETE"; _ = try await request(route.provider, call); return
            }
            var call = try ProviderAPI.request(route.provider, path: route.provider == .youtube ? "/youtube/v3/liveChat/bans" : "/helix/moderation/bans",
                query: route.provider == .youtube ? ["part": "snippet"] : ["broadcaster_id": route.channelID, "moderator_id": target.channelID])
            call.httpMethod = "POST"; call.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if route.provider == .youtube {
                var snippet: [String: Any] = ["liveChatId": route.chatID, "type": kind == .ban ? "permanent" : "temporary",
                    "bannedUserDetails": ["channelId": route.authorID]]
                if kind == .timeout { snippet["banDurationSeconds"] = 600 }
                call.httpBody = try JSONSerialization.data(withJSONObject: ["snippet": snippet])
            } else {
                var body: [String: Any] = ["user_id": route.authorID]
                if kind == .timeout { body["duration"] = 600 }
                call.httpBody = try JSONSerialization.data(withJSONObject: ["data": body])
            }
            let result = try StudioDirectChatDecoder.object(try await request(route.provider, call))
            if route.provider == .youtube {
                guard StudioDirectChatDecoder.identifier(result["id"]) != nil,
                      let snippet = result["snippet"] as? [String: Any], snippet["liveChatId"] as? String == route.chatID,
                      snippet["type"] as? String == (kind == .ban ? "permanent" : "temporary"),
                      (snippet["bannedUserDetails"] as? [String: Any])?["channelId"] as? String == route.authorID else { throw ProviderFailure(.invalidResponse) }
                if kind == .timeout, (snippet["banDurationSeconds"] as? NSNumber)?.doubleValue != 600 { throw ProviderFailure(.invalidResponse) }
            } else {
                guard let rows = result["data"] as? [[String: Any]], rows.count == 1,
                      rows[0]["broadcaster_id"] as? String == route.channelID, rows[0]["moderator_id"] as? String == target.channelID,
                      rows[0]["user_id"] as? String == route.authorID else { throw ProviderFailure(.invalidResponse) }
                if kind == .ban { guard rows[0]["end_time"] is NSNull else { throw ProviderFailure(.invalidResponse) } }
                else { guard StudioDirectChatDecoder.date(rows[0]["end_time"]) != nil else { throw ProviderFailure(.invalidResponse) } }
            }
        } acknowledged: { [weak self] in
            if kind == .delete { self?.remove([id]) }
            else { self?.clear(provider: route.provider, chatID: route.chatID, author: route.authorID) }
        }
        return receipt
    }
    private func appendReceipt(_ provider: ManagedProvider, target: String, kind: DirectChatWriteKind,
                               summary: String, batchID: UUID = UUID()) -> UUID {
        while receipts.count >= 64 {
            guard let index = receipts.firstIndex(where: { !$0.state.isPending }) else { break }
            receipts.remove(at: index)
        }
        let id = UUID()
        let bounded = String(decoding: summary.utf8.prefix(4096), as: UTF8.self)
        receipts.append(.init(id: id, batchID: batchID, provider: provider, target: target, kind: kind,
                              summary: String(bounded.prefix(500)), createdAt: now(), state: .sending))
        return id
    }
    private func finishReceipt(_ id: UUID, _ state: DirectChatWriteState) {
        guard let index = receipts.firstIndex(where: { $0.id == id }), receipts[index].state.isPending else { return }
        receipts[index].state = state
    }
    func clearReceipts() { receipts.removeAll { !$0.state.isPending } }
    func cancelWrite(receiptID: UUID) {
        guard let provider = writeIDs.first(where: { $0.value == receiptID })?.key else { return }
        cancelWrite(provider)
    }
    private func cancelWrite(_ provider: ManagedProvider) {
        if let id = writeIDs.removeValue(forKey: provider) { finishReceipt(id, .stopped) }
        writes[provider]?.cancel(); writes[provider] = nil; snapshots[provider]?.isMutating = false
    }
    private struct WriteRefusal: Error {}
    private func mutate(_ target: DirectChatWriteTarget, receipt: UUID, kind: DirectChatWriteKind,
                        operation: @escaping @MainActor () async throws -> Void, acknowledged: @escaping () -> Void = {}) {
        let provider = target.provider
        snapshots[provider]?.isMutating = true; snapshots[provider]?.failure = nil
        writeIDs[provider] = receipt
        writes[provider] = Task { [weak self] in
            do {
                try await operation()
                guard let self, self.current(provider, target.generation), self.writeIDs[provider] == receipt else { return }
                self.finishReceipt(receipt, .acknowledged)
                self.snapshots[provider]?.notice = "Provider acknowledged the action. Sends appear only when delivered by the public reader."
                acknowledged()
            } catch {
                guard let self, self.current(provider, target.generation), self.writeIDs[provider] == receipt else { return }
                if error is WriteRefusal {
                    self.finishReceipt(receipt, .rejected("Twitch did not send this message."))
                    self.snapshots[provider]?.failure = "Twitch did not send this message. Incoming chat continues."
                } else {
                    let failure = error as? ProviderFailure ?? ProviderFailure(.unavailable)
                    let definitive = [.authorization, .permission, .rateLimited, .invalidRequest].contains(failure.kind)
                    self.finishReceipt(receipt, definitive ? .rejected(failure.localizedDescription) : .unconfirmed(failure.localizedDescription))
                    self.snapshots[provider]?.failure = failure.localizedDescription
                    if failure.kind == .rateLimited {
                        let seconds = failure.retryAfter.flatMap { $0.isFinite ? min(86400, max(1, $0)) : nil } ?? 60
                        let until = self.now().addingTimeInterval(seconds)
                        self.cooldowns[provider] = until; self.snapshots[provider]?.retryUntil = until
                    }
                    if failure.kind == .permission {
                        let related: Set<DirectChatWriteKind> = [.post, .reply].contains(kind) ? [.post, .reply] : ([.timeout, .ban].contains(kind) ? [.timeout, .ban] : [.delete])
                        self.writeDenials[provider, default: []].formUnion(related)
                    }
                    if failure.kind == .authorization { self.failed(provider, target.generation, error); return }
                }
                self.snapshots[provider]?.notice = "No action is replayed automatically. Verify the provider before a deliberate manual retry."
            }
            guard let self, self.writeIDs[provider] == receipt else { return }
            self.snapshots[provider]?.isMutating = false; self.writeIDs[provider] = nil; self.writes[provider] = nil
        }
    }
}
