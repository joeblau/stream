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
}

/// One authenticated reader per provider feeds every workspace consumer. No
/// reader starts on load, sign-in or wake. Requests and sockets are injectable.
@MainActor final class StudioDirectChatManager: ObservableObject {
    typealias Request = @MainActor (ManagedProvider, URLRequest) async throws -> Data
    typealias Identity = @MainActor (ManagedProvider) async throws -> DirectChatIdentity
    typealias Sleep = @Sendable (Double) async throws -> Void
    @Published private(set) var snapshots: [ManagedProvider: DirectChatSnapshot] = [.youtube: .init(), .twitch: .init()]
    private let request: Request
    private let identity: Identity
    private let socketFactory: @Sendable (URL) -> any StudioChatSocket
    private let sleep: Sleep
    private let deadlineSleep: Sleep
    private let emit: (StudioChatAction) -> Void
    private var generations: [ManagedProvider: UUID] = [:]
    private var jobs: [ManagedProvider: Task<Void, Never>] = [:]
    private var writes: [ManagedProvider: Task<Void, Never>] = [:]
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
         deadlineSleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) }, emit: @escaping (StudioChatAction) -> Void) {
        self.request = request; self.identity = identity; self.socketFactory = socketFactory; self.sleep = sleep
        self.deadlineSleep = deadlineSleep; self.emit = emit
    }
    func snapshot(_ provider: ManagedProvider) -> DirectChatSnapshot { snapshots[provider] ?? .init() }
    func stop(_ provider: ManagedProvider) {
        let old = generations[provider]
        generations[provider] = UUID(); jobs[provider]?.cancel(); jobs[provider] = nil
        writes[provider]?.cancel(); writes[provider] = nil; active[provider] = nil
        if provider == .twitch { cancelCycles(); reconnectAttempts = 0 }
        if let old { emit(.closed(uuid: old.uuidString)) }
        snapshots[provider] = .init()
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
            let data = try await request(.youtube, ProviderAPI.request(.youtube, path: "/youtube/v3/liveChat/messages", query: query))
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
        writes[provider]?.cancel(); writes[provider] = nil; snapshots[provider]?.isMutating = false
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
    func canSend(_ provider: ManagedProvider) -> Bool {
        guard snapshot(provider).isConnected, !snapshot(provider).isMutating, let (account, _) = active[provider] else { return false }
        return provider == .youtube || account.scopes.contains("user:write:chat")
    }
    func canDelete(_ id: String) -> Bool {
        guard let route = routes[id], snapshot(route.provider).isConnected, !snapshot(route.provider).isMutating,
              let (account, chatID) = active[route.provider], chatID == route.chatID,
              account.channelID != route.authorID,
              !route.roles.contains("Owner"), !route.roles.contains("Moderator") else { return false }
        return route.provider == .youtube || (account.scopes.contains("moderator:manage:chat_messages") && Date().timeIntervalSince(route.timestamp) < 21_600)
    }
    func canReply(_ id: String) -> Bool {
        guard let route = routes[id], route.provider == .twitch, let (_, chatID) = active[.twitch], chatID == route.chatID else { return false }
        return canSend(.twitch)
    }
    /// Never retries a write or synthesizes a successful local chat echo.
    func send(_ text: String, provider: ManagedProvider, replyingTo id: String? = nil) {
        guard canSend(provider), let (account, chatID) = active[provider], let generation = generations[provider],
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= (provider == .twitch ? 500 : 200), text.utf8.count <= 4_096,
              id == nil || canReply(id!) else { return }
        let reply = id.flatMap { routes[$0]?.providerMessageID }
        mutate(provider, generation) { [request] in
            var call = try ProviderAPI.request(provider, path: provider == .youtube ? "/youtube/v3/liveChat/messages" : "/helix/chat/messages",
                query: provider == .youtube ? ["part": "snippet"] : [:])
            call.httpMethod = "POST"; call.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if provider == .youtube {
                call.httpBody = try JSONSerialization.data(withJSONObject: ["snippet": ["liveChatId": chatID, "type": "textMessageEvent", "textMessageDetails": ["messageText": text]]])
            } else {
                var body: [String: Any] = ["broadcaster_id": account.channelID, "sender_id": account.channelID, "message": text]
                if let reply { body["reply_parent_message_id"] = reply }
                call.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let result = try StudioDirectChatDecoder.object(try await request(provider, call))
            if provider == .twitch {
                guard let rows = result["data"] as? [[String: Any]], rows.count == 1, rows[0]["is_sent"] as? Bool == true,
                      StudioDirectChatDecoder.identifier(rows[0]["message_id"]) != nil else { throw ProviderFailure(.permission) }
            } else { guard StudioDirectChatDecoder.identifier(result["id"]) != nil else { throw ProviderFailure(.invalidResponse) } }
        }
    }
    func delete(_ id: String) {
        guard canDelete(id), let route = routes[id], let generation = generations[route.provider] else { return }
        mutate(route.provider, generation) { [request] in
            let query = route.provider == .youtube ? ["id": route.providerMessageID] : ["broadcaster_id": route.channelID,
                "moderator_id": route.channelID, "message_id": route.providerMessageID]
            var call = try ProviderAPI.request(route.provider, path: route.provider == .youtube ? "/youtube/v3/liveChat/messages" : "/helix/moderation/chat", query: query)
            call.httpMethod = "DELETE"; _ = try await request(route.provider, call)
        } acknowledged: { [weak self] in self?.remove([id]) }
    }
    private func mutate(_ provider: ManagedProvider, _ generation: UUID, operation: @escaping @MainActor () async throws -> Void,
                        acknowledged: @escaping () -> Void = {}) {
        snapshots[provider]?.isMutating = true; snapshots[provider]?.failure = nil
        writes[provider] = Task { [weak self] in
            guard let self else { return }
            do {
                try await operation(); guard current(provider, generation) else { return }
                snapshots[provider]?.notice = "Provider acknowledged the action. Sends appear only when delivered by the public reader."
                acknowledged()
            } catch {
                guard current(provider, generation) else { return }
                if (error as? ProviderFailure)?.kind == .authorization {
                    failed(provider, generation, error); snapshots[provider]?.isMutating = false; writes[provider] = nil; return
                }
                snapshots[provider]?.failure = (error as? ProviderFailure ?? ProviderFailure(.unavailable)).localizedDescription
                snapshots[provider]?.notice = "The action was not confirmed. Refresh or inspect the provider before manually retrying."
            }
            snapshots[provider]?.isMutating = false; writes[provider] = nil
        }
    }
}
