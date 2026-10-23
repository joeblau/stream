import Foundation
import StreamCore

private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
private final class FixtureSocket: StudioChatSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    private var closed = false
    var isClosed: Bool { lock.withLock { closed } }
    func push(_ data: Data) {
        let pending = lock.withLock { () -> CheckedContinuation<Data, Error>? in
            guard !closed else { return nil }
            if let waiter { self.waiter = nil; return waiter }
            messages.append(data); return nil
        }
        pending?.resume(returning: data)
    }
    func receive() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready = lock.withLock { () -> Result<Data, Error>? in
                    if closed { return .failure(URLError(.networkConnectionLost)) }
                    if !messages.isEmpty { return .success(messages.removeFirst()) }
                    precondition(waiter == nil); waiter = continuation; return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: { self.cancel() }
    }
    func cancel() {
        let pending = lock.withLock { () -> CheckedContinuation<Data, Error>? in
            closed = true; let pending = waiter; waiter = nil; return pending
        }; pending?.resume(throwing: URLError(.networkConnectionLost))
    }
}
private final class FixtureSockets: @unchecked Sendable {
    private let lock = NSLock()
    private var available: [FixtureSocket]
    private var urls: [URL] = []
    init(_ available: [FixtureSocket]) { self.available = available }
    func make(_ url: URL) -> any StudioChatSocket {
        lock.withLock { urls.append(url); precondition(!available.isEmpty); return available.removeFirst() }
    }
    var opened: [URL] { lock.withLock { urls } }
}
private actor PollGate {
    private var sleeps: [Double] = []
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var order: [UUID] = []
    func sleep(_ seconds: Double) async throws {
        try Task.checkCancellation()
        let id = UUID()
        sleeps.append(seconds)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters[id] = $0; order.append(id) }
        } onCancel: { Task { await self.cancel(id) } }
        try Task.checkCancellation()
    }
    func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()); order.removeAll { $0 == id } }
    func resume() { if let id = order.first { order.removeFirst(); waiters.removeValue(forKey: id)?.resume() } }
    var intervals: [Double] { sleeps }
    var waiting: Int { waiters.count }
}
private final class FixtureTime: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}
@MainActor private final class HTTPFixture {
    var calls: [(ManagedProvider, URLRequest)] = []
    var pages = 0
    var dropSend = false
    var subscriptionDenied = false
    var holdBroadcast = false
    var lateBroadcast: CheckedContinuation<Data, Error>?
    var writeFailures: [ManagedProvider: ProviderFailure] = [:]
    var holdWrites: Set<ManagedProvider> = []
    var heldWrites: [ManagedProvider: CheckedContinuation<Data, Error>] = [:]
    var holdEmotes = false, emoteReads = 0
    var lateEmote: CheckedContinuation<Data, Error>?
    func emoteMetadata() -> Data {
        json(["template": "https://static-cdn.jtvnw.net/emoticons/v2/{{id}}/{{format}}/{{theme_mode}}/{{scale}}",
            "data": [["id": "25", "emote_set_id": "0", "format": ["static"], "theme_mode": ["light", "dark"], "scale": ["1.0", "2.0", "3.0"]]]])
    }
    var malformedBan = false
    var banDurationOverride: Double?
    var rateLimitedReads = 0
    var readItems: [[String: Any]]?
    var broadcastEventID = "owned-event", broadcastChatID = "live-chat"
    var audienceResponse: Data?
    var audienceFailure: ProviderFailure?
    var holdAudience = false
    var lateAudience: CheckedContinuation<Data, Error>?
    func send(_ provider: ManagedProvider, _ call: URLRequest) async throws -> Data {
        calls.append((provider, call))
        let path = call.url!.path, method = call.httpMethod ?? "GET"
        if path == "/helix/chat/emotes/global" || path == "/helix/chat/emotes/set" {
            precondition(provider == .twitch && method == "GET" && call.httpBody == nil)
            emoteReads += 1
            if holdEmotes { return try await withCheckedThrowingContinuation { lateEmote = $0 } }
            return emoteMetadata()
        }
        if path == "/youtube/v3/videos" || path == "/helix/streams" {
            if holdAudience { return try await withCheckedThrowingContinuation { lateAudience = $0 } }
            if let audienceFailure { throw audienceFailure }
            if let audienceResponse { return audienceResponse }
            return provider == .youtube ? audienceYouTube("123") : json(["data": [["user_id": "owner", "type": "live", "viewer_count": 37]]])
        }
        if path == "/youtube/v3/liveBroadcasts" {
            if holdBroadcast { return try await withCheckedThrowingContinuation { lateBroadcast = $0 } }
            return broadcast()
        }
        if path == "/helix/eventsub/subscriptions" {
            if subscriptionDenied { throw ProviderFailure(.permission) }
            var payload = try! JSONSerialization.jsonObject(with: call.httpBody!) as! [String: Any]
            payload["status"] = "enabled"; payload["id"] = UUID().uuidString
            return json(["data": [payload]])
        }
        if method != "GET" {
            if let error = writeFailures[provider] { throw error }
            if holdWrites.contains(provider) { return try await withCheckedThrowingContinuation { heldWrites[provider] = $0 } }
        }
        if path == "/youtube/v3/liveChat/bans" {
            var payload = try JSONSerialization.jsonObject(with: call.httpBody!) as! [String: Any]
            payload["id"] = "acknowledged-ban"
            if let banDurationOverride, var snippet = payload["snippet"] as? [String: Any] {
                snippet["banDurationSeconds"] = banDurationOverride; payload["snippet"] = snippet
            }
            if malformedBan { payload["snippet"] = ["liveChatId": "wrong-chat"] }
            return json(payload)
        }
        if path == "/helix/moderation/bans" {
            let payload = try JSONSerialization.jsonObject(with: call.httpBody!) as! [String: Any]
            let body = payload["data"] as! [String: Any]
            let end: Any = body["duration"] == nil ? NSNull() : "2026-10-02T19:40:00Z" as Any
            return json(["data": [["broadcaster_id": "owner", "moderator_id": "owner", "user_id": malformedBan ? "wrong-author" : body["user_id"]!,
                "end_time": end]]])
        }
        if path == "/helix/chat/messages" {
            return json(["data": [["message_id": "sent", "is_sent": !dropSend, "drop_reason": NSNull()]]])
        }
        if method == "DELETE" { return Data() }
        if provider == .youtube, method == "POST" { return json(["id": "youtube-posted"]) }
        if path == "/youtube/v3/liveChat/messages" {
            if rateLimitedReads > 0 { rateLimitedReads -= 1; throw ProviderFailure(.rateLimited, retryAfter: 5) }
            pages += 1
            if let readItems { return youtubePage(readItems, token: "after-custom") }
            if pages == 1 { return youtubePage([youtubeItem("one"), youtubeItem("two", kind: "superChatEvent")]) }
            if pages == 2 { return youtubePage([youtubeItem("two", kind: "superChatEvent"), youtubeItem("three", kind: "superStickerEvent")], token: "after-two") }
            return youtubePage([], ended: true)
        }
        throw ProviderFailure(.invalidRequest)
    }
    func broadcast() -> Data { json(["items": [["id": broadcastEventID, "snippet": ["channelId": "owner", "liveChatId": broadcastChatID], "status": ["lifeCycleStatus": "live"]]]]) }
}
private func audienceYouTube(_ count: Any? = nil, chatID: String = "live-chat", ended: Bool = false) -> Data {
    var details: [String: Any] = ["activeLiveChatId": chatID]
    if let count { details["concurrentViewers"] = count }
    if ended { details["actualEndTime"] = "2026-10-21T01:00:00Z" }
    return json(["items": [["id": "owned-event", "snippet": ["channelId": "owner"], "liveStreamingDetails": details]]])
}
private func youtubeItem(_ id: String, kind: String = "textMessageEvent") -> [String: Any] {
    ["id": id, "snippet": ["type": kind, "liveChatId": "live-chat", "hasDisplayContent": true,
        "displayMessage": "Hello 👩🏽‍🚀 世界 \(id)", "publishedAt": "2026-10-02T19:30:00.123Z"],
     "authorDetails": ["channelId": "viewer", "displayName": "Viewer 世界", "isChatSponsor": true,
        "profileImageUrl": "https://example.test/avatar"]]
}
private func youtubePage(_ items: [[String: Any]], token: String = "after-one", ended: Bool = false) -> Data {
    var page: [String: Any] = ["items": items, "pollingIntervalMillis": 2_500, "nextPageToken": token]
    if ended { page["offlineAt"] = "2026-10-02T19:35:00Z" }; return json(page)
}
private func twitchControl(_ type: String, session: String = "session-one", reconnect: String? = nil) -> Data {
    var detail: [String: Any] = ["id": session, "keepalive_timeout_seconds": 10]
    if let reconnect { detail["reconnect_url"] = reconnect }
    return json(["metadata": ["message_type": type, "message_timestamp": "2026-10-02T19:30:00.123456789Z"], "payload": type == "session_keepalive" ? [:] : ["session": detail]])
}
private func twitchEvent(_ id: String, type: String = "channel.chat.message", author: String = "viewer", moderator: Bool = false) -> Data {
    var event: [String: Any] = ["broadcaster_user_id": "owner", "chatter_user_id": author, "chatter_user_name": "Viewer 世界",
        "message_id": id, "message": ["text": "Hello 👩🏽‍🚀 世界 Kappa", "fragments": [["type": "text", "text": "Hello 👩🏽‍🚀 世界 "], ["type": "emote", "text": "Kappa", "emote": ["id": "25", "emote_set_id": "0", "format": ["static"]]]]],
        "badges": [["set_id": moderator ? "moderator" : "subscriber"]]]
    if type == "channel.chat.clear_user_messages" { event["target_user_id"] = author }
    return json(["metadata": ["message_type": "notification", "message_timestamp": ISO8601DateFormatter().string(from: Date())],
                 "payload": ["subscription": ["id": "subscription", "type": type, "version": "1", "condition": ["broadcaster_user_id": "owner", "user_id": "owner"]], "event": event]])
}
@MainActor private final class StreamFixture {
    var queue = StudioChatQueue()
    var connections: [String: String] = [:]
    func receive(_ action: StudioChatAction) {
        switch action {
        case .message(let message): queue.receive(message)
        case .removed(let ids): queue.discard(ids)
        case .connection(let id, let uuid, _, _): connections[id] = uuid
        case .closed(let uuid): connections = connections.filter { $0.value != uuid }
        case .heartbeat: break
        }
    }
}
@main struct DirectChatHarness {
    @MainActor static func until(line: Int = #line, _ predicate: @escaping @MainActor () -> Bool) async {
        for _ in 0..<400 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(5)) }
        precondition(predicate(), "Fixture deadline exceeded at line \(line)")
    }
    // Independent fixture contract: every fresh socket must acknowledge all
    // five public subscriptions. A migrated socket transfers them unchanged.
    @MainActor private static func requireTwitchSubscriptions(_ http: HTTPFixture, sessions: [String]) throws {
        let expectedTypes = ["channel.chat.message", "channel.chat.message_delete", "channel.chat.clear",
                             "channel.chat.clear_user_messages", "channel.chat.notification"]
        let requests = http.calls.filter { $0.1.url!.path == "/helix/eventsub/subscriptions" }.map(\.1)
        FileHandle.standardOutput.write(Data("CHECK: Twitch subscription sets \(sessions.joined(separator: ",")); expected \(expectedTypes.count * sessions.count), actual \(requests.count)\n".utf8))
        precondition(requests.count == expectedTypes.count * sessions.count,
                     "Each fresh Twitch session requires exactly five public subscription requests")
        var typesBySession: [String: [String]] = [:]
        for request in requests {
            precondition(request.httpMethod == "POST" && request.url?.scheme == "https"
                && request.url?.host == "api.twitch.tv" && request.url?.port == nil && request.url?.query == nil)
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            precondition(Set(body.keys) == ["type", "version", "condition", "transport"])
            precondition(body["version"] as? String == "1")
            precondition(body["condition"] as? [String: String] == ["broadcaster_user_id": "owner", "user_id": "owner"])
            let transport = body["transport"] as! [String: String]
            precondition(Set(transport.keys) == ["method", "session_id"] && transport["method"] == "websocket")
            let session = transport["session_id"]!
            precondition(sessions.contains(session), "Transferred migration must not create subscriptions on another session")
            typesBySession[session, default: []].append(body["type"] as! String)
        }
        precondition(Set(typesBySession.keys) == Set(sessions))
        for session in sessions {
            let actualTypes = typesBySession[session] ?? []
            precondition(actualTypes.count == expectedTypes.count && Set(actualTypes) == Set(expectedTypes),
                         "Fresh Twitch session is missing, duplicating or replacing a required subscription type")
        }
    }
    @MainActor static func main() async throws {
        let http = HTTPFixture(), gate = PollGate(), stream = StreamFixture()
        let first = FixtureSocket(), second = FixtureSocket(), third = FixtureSocket()
        let sockets = FixtureSockets([first, second, third])
        let manager = StudioDirectChatManager(request: http.send, identity: { provider in
            .init(channelID: "owner", scopes: provider == .youtube ? ManagedProvider.youtube.scopes : TwitchDeviceAuthorization.optionalChatScopes)
        }, socketFactory: sockets.make, sleep: { seconds in try await gate.sleep(seconds) }, emit: stream.receive)
        precondition(!manager.snapshot(.youtube).isConnected && sockets.opened.isEmpty && http.calls.isEmpty)
        manager.connect(.youtube, eventID: "owned-event")
        await until { stream.queue.messages.count == 2 && manager.snapshot(.youtube).isConnected }
        precondition(stream.queue.messages.map(\.kind) == ["Text", "Super Chat"])
        precondition(stream.queue.messages.map(\.audienceEvent) == [.text, .superChat])
        precondition(stream.queue.messages[0].roles == ["Member"] && !stream.queue.messages[0].timestampIsReceiptTime)
        precondition(stream.queue.messages[0].text.contains("👩🏽‍🚀 世界"))
        await until { http.pages == 1 }; let intervals = await gate.intervals; precondition(intervals == [2.5])
        manager.send("YouTube public post", provider: .youtube)
        await until { !manager.snapshot(.youtube).isMutating }
        precondition(stream.queue.messages.count == 2) // no local fake echo
        await gate.resume(); await until { stream.queue.messages.count == 3 }
        let secondQuery = http.calls.filter { $0.1.url!.path == "/youtube/v3/liveChat/messages" && ($0.1.httpMethod ?? "GET") == "GET" }[1].1.url!
        precondition(URLComponents(url: secondQuery, resolvingAgainstBaseURL: false)!.queryItems!.contains { $0.name == "pageToken" && $0.value == "after-one" })
        let one = stream.queue.messages[0].id
        stream.queue.favorite(one); stream.queue.enqueue(one); stream.queue.show(one)
        manager.delete(one); await until { stream.queue.message(one) == nil }
        precondition(stream.queue.featuredID == nil && stream.queue.favorites.isEmpty && stream.queue.queue.isEmpty)
        let deleteYT = http.calls.last!.1
        precondition(deleteYT.httpMethod == "DELETE" && URLComponents(url: deleteYT.url!, resolvingAgainstBaseURL: false)!.queryItems!.contains { $0.name == "id" && $0.value == "one" })
        manager.connect(.twitch)
        await until { sockets.opened.count == 1 }
        precondition(!manager.snapshot(.twitch).isConnected)
        first.push(twitchControl("session_welcome"))
        await until { manager.snapshot(.twitch).isConnected }
        try requireTwitchSubscriptions(http, sessions: ["session-one"])
        first.push(twitchEvent("twitch-one")); first.push(twitchEvent("twitch-one"))
        await until { stream.queue.messages.contains { $0.platform == "Twitch" } }
        let twitchID = StudioDirectChatDecoder.identity(.twitch, "owner", "twitch-one")
        precondition(stream.queue.messages.filter { $0.platform == "Twitch" }.count == 1)
        precondition(stream.queue.message(twitchID)?.kind == "Emotes" && manager.canReply(twitchID))
        precondition(stream.queue.message(twitchID)?.audienceEvent == .emotes)
        // A relay carrying the same actual provider identity shares the dedup key.
        let relay = json(["action": "event", "payload": ["connectionIdentifier": "relay/twitch", "eventTypeId": 4,
            "eventPayload": ["twitchMessageId": "twitch-one", "text": "Hello", "author": ["displayName": "Viewer"]]]])
        if let action = StudioRestreamDecoder.decode(relay) { stream.receive(action) }
        precondition(stream.queue.messages.filter { $0.platform == "Twitch" }.count == 1)
        http.dropSend = true
        manager.send("Explicit public reply", provider: .twitch, replyingTo: twitchID)
        await until { !manager.snapshot(.twitch).isMutating }
        precondition(manager.snapshot(.twitch).failure != nil && stream.queue.messages.count == 3)
        let replyCall = http.calls.last!.1, replyBody = try JSONSerialization.jsonObject(with: replyCall.httpBody!) as! [String: Any]
        precondition(replyBody["reply_parent_message_id"] as? String == "twitch-one" && replyBody["for_source_only"] == nil)
        precondition(http.calls.filter { $0.1.url!.path == "/helix/chat/messages" }.count == 1)
        http.dropSend = false
        let beforeAcknowledgedSend = stream.queue.messages.count
        manager.send("Acknowledged public reply", provider: .twitch, replyingTo: twitchID)
        await until { !manager.snapshot(.twitch).isMutating }
        precondition(manager.snapshot(.twitch).failure == nil && stream.queue.messages.count == beforeAcknowledgedSend)
        // Requested migration retains old delivery until the new welcome and
        // never creates duplicate subscriptions on the transferred session.
        let reconnect = "wss://eventsub.wss.twitch.tv/ws?reconnect=opaque-issued-value"
        first.push(twitchControl("session_reconnect", reconnect: reconnect))
        await until { sockets.opened.count == 2 }
        first.push(twitchEvent("during-migration"))
        await until { stream.queue.message(StudioDirectChatDecoder.identity(.twitch, "owner", "during-migration")) != nil }
        precondition(!first.isClosed && sockets.opened[1].absoluteString == reconnect)
        second.push(twitchControl("session_welcome", session: "session-two"))
        await until { first.isClosed }
        try requireTwitchSubscriptions(http, sessions: ["session-one"])
        let duringID = StudioDirectChatDecoder.identity(.twitch, "owner", "during-migration")
        precondition(manager.canDelete(duringID))
        manager.delete(duringID); await until { stream.queue.message(duringID) == nil }
        let targeted = http.calls.last!.1
        let deletionQuery = URLComponents(url: targeted.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        precondition(targeted.httpMethod == "DELETE" && deletionQuery.contains { $0.name == "message_id" && $0.value == "during-migration" })
        second.push(twitchEvent("moderator-message", moderator: true))
        await until { stream.queue.message(StudioDirectChatDecoder.identity(.twitch, "owner", "moderator-message")) != nil }
        precondition(!manager.canDelete(StudioDirectChatDecoder.identity(.twitch, "owner", "moderator-message")))
        second.push(twitchEvent("twitch-one", type: "channel.chat.message_delete"))
        await until { stream.queue.message(twitchID) == nil }
        second.push(twitchEvent("twitch-one")); try? await Task.sleep(for: .milliseconds(20))
        precondition(stream.queue.message(twitchID) == nil) // tombstone survives replay
        manager.stop(.youtube)
        precondition(manager.snapshot(.twitch).isConnected && !second.isClosed)
        second.cancel(); await until { manager.snapshot(.twitch).state == "Reconnecting" }
        await gate.resume(); await until { sockets.opened.count == 3 }
        third.push(twitchControl("session_welcome", session: "session-three"))
        await until { manager.snapshot(.twitch).isConnected }
        try requireTwitchSubscriptions(http, sessions: ["session-one", "session-three"])
        manager.shutdown(); precondition(third.isClosed && !manager.snapshot(.twitch).isConnected && stream.connections.isEmpty)
        third.push(twitchEvent("late-after-shutdown")); try? await Task.sleep(for: .milliseconds(20))
        precondition(stream.queue.message(StudioDirectChatDecoder.identity(.twitch, "owner", "late-after-shutdown")) == nil)
        // Noncooperative late HTTP completion cannot revive a stopped reader.
        let late = HTTPFixture(); late.holdBroadcast = true
        let stopped = StudioDirectChatManager(request: late.send, identity: { _ in .init(channelID: "owner", scopes: ManagedProvider.youtube.scopes) }, emit: stream.receive)
        stopped.connect(.youtube, eventID: "owned-event"); await until { late.lateBroadcast != nil }
        stopped.shutdown(); late.lateBroadcast?.resume(returning: late.broadcast()); late.lateBroadcast = nil
        try? await Task.sleep(for: .milliseconds(20)); precondition(late.calls.count == 1 && !stopped.snapshot(.youtube).isConnected)
        // Missing grants and declined EventSub acknowledgements stay offline.
        let denied = StudioDirectChatManager(request: http.send, identity: { _ in .init(channelID: "owner", scopes: []) }, emit: stream.receive)
        let previousCalls = http.calls.count; denied.connect(.twitch); await until { denied.snapshot(.twitch).state == "Failed" }
        precondition(http.calls.count == previousCalls && !denied.snapshot(.twitch).isConnected)
        let deniedSocket = FixtureSocket(), deniedPool = FixtureSockets([deniedSocket]); http.subscriptionDenied = true
        let rejected = StudioDirectChatManager(request: http.send, identity: { _ in .init(channelID: "owner", scopes: ["user:read:chat"]) }, socketFactory: deniedPool.make, emit: stream.receive)
        rejected.connect(.twitch); await until { !deniedPool.opened.isEmpty }; deniedSocket.push(twitchControl("session_welcome"))
        await until { rejected.snapshot(.twitch).state == "Failed" }; precondition(deniedSocket.isClosed && !rejected.snapshot(.twitch).isConnected)
        precondition(rejected.snapshot(.twitch).publicReaderState == "failed")
        // A received chat-ended acknowledgement ends reading without any
        // remote broadcast mutation or unexpected restart.
        let endingHTTP = HTTPFixture(); endingHTTP.pages = 2
        let ending = StudioDirectChatManager(request: endingHTTP.send, identity: { _ in .init(channelID: "owner", scopes: ManagedProvider.youtube.scopes) }, emit: stream.receive)
        ending.connect(.youtube, eventID: "owned-event"); await until { ending.snapshot(.youtube).state == "Chat ended" }
        precondition(!ending.canSend(.youtube) && endingHTTP.calls.count == 2 && endingHTTP.calls.allSatisfy { ($0.1.httpMethod ?? "GET") == "GET" })
        let wrongOwnerHTTP = HTTPFixture()
        let wrongOwner = StudioDirectChatManager(request: wrongOwnerHTTP.send, identity: { _ in .init(channelID: "another-owner", scopes: ManagedProvider.youtube.scopes) }, emit: stream.receive)
        wrongOwner.connect(.youtube, eventID: "owned-event"); await until { wrongOwner.snapshot(.youtube).state == "Failed" }
        precondition(wrongOwnerHTTP.calls.count == 1)
        // Inject the actual welcome deadline; an unacknowledged socket never
        // enters Connected and shutdown cancels its pending retry.
        let welcomeGate = PollGate(), retryGate = PollGate(), silentSocket = FixtureSocket()
        let silentPool = FixtureSockets([silentSocket])
        let silent = StudioDirectChatManager(request: http.send, identity: { _ in .init(channelID: "owner", scopes: ["user:read:chat"]) }, socketFactory: silentPool.make,
            sleep: { try await retryGate.sleep($0) }, deadlineSleep: { try await welcomeGate.sleep($0) }, emit: stream.receive)
        silent.connect(.twitch); await until { !silentPool.opened.isEmpty }
        let welcomeIntervals = await welcomeGate.intervals; precondition(welcomeIntervals == [10])
        await welcomeGate.resume(); await until { silent.snapshot(.twitch).state == "Reconnecting" }
        precondition(silentSocket.isClosed && !silent.snapshot(.twitch).isConnected)
        silent.shutdown()
        // Provider envelopes cannot smuggle private/unknown/oversized events.
        do { _ = try StudioDirectChatDecoder.twitch(twitchControl("session_reconnect", reconnect: "wss://evil.test/ws"), channelID: "owner", userID: "owner"); preconditionFailure() } catch {}
        do { _ = try StudioDirectChatDecoder.twitch(Data(repeating: 32, count: 262_145), channelID: "owner", userID: "owner"); preconditionFailure() } catch {}
        do { _ = try StudioDirectChatDecoder.youtube(json(["items": [], "nextPageToken": "next", "pollingIntervalMillis": -1]), channelID: "owner", chatID: "live-chat"); preconditionFailure() } catch {}
        let tombstone = try StudioDirectChatDecoder.youtube(youtubePage([["id": "deleted", "snippet": ["type": "tombstone", "liveChatId": "live-chat"]]]), channelID: "owner", chatID: "live-chat")
        precondition(tombstone.deliveries.isEmpty && tombstone.removedIDs.count == 1)
        precondition(StudioDirectChatDecoder.date("2026-10-02T19:30:00.123456789Z") != nil)
        try await validatePreflightCancellation()
        try await validateRetainedMessageTargets()
        try await validateStaticEmotes()
        try await validateAudience()
        try await validateOutbox()
        print("PASS: actual direct chat manager HTTP/WebSocket fixtures; granted-scope readers, provider intervals/page tokens, Unicode/kinds/roles, relay dedup, targeted deletion/tombstones, explicit send acknowledgement/no retry/echo, migration without resubscription, disconnect resubscription, independent stop, cancellation and late HTTP/socket rejection")
    }
    @MainActor static func validatePreflightCancellation() async throws {
        for kind in [DirectChatWriteKind.post, .delete, .timeout, .ban] {
            let http = HTTPFixture(), gate = PollGate(), stream = StreamFixture()
            let manager = StudioDirectChatManager(request: http.send,
                identity: { _ in .init(channelID: "owner", scopes: ManagedProvider.youtube.scopes) },
                sleep: { try await gate.sleep($0) }, emit: stream.receive)
            manager.connect(.youtube, eventID: "owned-event")
            await until { manager.snapshot(.youtube).isConnected && !stream.queue.messages.isEmpty }
            let before = http.calls.count
            let receipt = kind == .post ? manager.send("Cancel before provider dispatch", provider: .youtube)
                : manager.moderate(stream.queue.messages[0].id, kind: kind)!
            // Still on the same actor turn: no provider operation has started.
            manager.cancelWrite(receiptID: receipt)
            for _ in 0..<8 { await Task.yield() }
            precondition(http.calls.count == before,
                         "A locally canceled action began an HTTP mutation after cancellation")
            guard let state = manager.receipts.first(where: { $0.id == receipt })?.state,
                  case .notSent = state else { preconditionFailure() }
            precondition(manager.snapshot(.youtube).isConnected && stream.queue.messages.count == 2)
            manager.shutdown()
        }
        print("PASS: cancellation before provider dispatch prevents post/delete/timeout/ban HTTP calls while preserving reader, incoming messages and precise not-sent receipts")
    }
    @MainActor static func validateRetainedMessageTargets() async throws {
        let http = HTTPFixture(), gate = PollGate(), stream = StreamFixture()
        let manager = StudioDirectChatManager(request: http.send,
            identity: { _ in .init(channelID: "owner", scopes: ManagedProvider.youtube.scopes) },
            sleep: { try await gate.sleep($0) }, emit: stream.receive)
        manager.connect(.youtube, eventID: "owned-event")
        precondition(manager.snapshot(.youtube).publicReaderState == "connecting")
        await until { stream.queue.messages.count == 2 && manager.snapshot(.youtube).isConnected }
        let historical = stream.queue.messages[0].id
        precondition(manager.targetForMessage(historical)?.chatID == "live-chat")
        http.broadcastEventID = "replacement-event"; http.broadcastChatID = "replacement-chat"; http.readItems = []
        manager.connect(.youtube, eventID: "replacement-event")
        await until { manager.snapshot(.youtube).isConnected }
        precondition(stream.queue.message(historical) != nil) // preserve incoming/curation
        precondition(manager.targetForMessage(historical) == nil,
                     "A historical message was presented as routed to a replacement broadcast")
        let count = http.calls.count
        let receipt = manager.delete(historical)!
        guard case .notSent = manager.receipts.first(where: { $0.id == receipt })!.state else { preconditionFailure() }
        precondition(http.calls.count == count && !manager.canDelete(historical))
        manager.authorizationDidChange(.youtube)
        precondition(manager.snapshot(.youtube).publicReaderState == "failed" && !manager.canSend(.youtube))
        precondition(stream.queue.message(historical) != nil && manager.targetForMessage(historical) == nil)
        manager.stop(.youtube)
        precondition(manager.snapshot(.youtube).publicReaderState == "offline")
        manager.shutdown()
        print("PASS: retained incoming messages stay read-only after broadcast replacement; exact original channel/chat review route, no HTTP mutation, truthful public-reader connection states")
    }
    @MainActor static func validateStaticEmotes() async throws {
        let http = HTTPFixture(), socket = FixtureSocket(), stream = StreamFixture(), clock = FixtureTime()
        let manager = StudioDirectChatManager(request: http.send, identity: { _ in .init(channelID: "owner", scopes: ["user:read:chat"]) },
            socketFactory: { _ in socket }, now: clock.now, emit: stream.receive)
        manager.connect(.twitch); await until { !manager.snapshot(.twitch).target.isEmpty }
        socket.push(twitchControl("session_welcome")); await until { manager.snapshot(.twitch).isConnected }
        socket.push(twitchEvent("static-emote")); await until { stream.queue.messages.count == 1 }
        let message = stream.queue.messages[0]
        precondition(message.staticEmote == .init(id: "25", setID: "0", label: "Kappa"))
        let url = try await manager.staticEmoteURL(for: message)
        precondition(url.absoluteString == "https://static-cdn.jtvnw.net/emoticons/v2/25/static/light/3.0" && http.emoteReads == 1)
        do { _ = try await manager.staticEmoteURL(for: message); preconditionFailure("Metadata read rate guard missing") } catch {}
        precondition(http.emoteReads == 1)
        let metadata = message.staticEmote!
        var object = try JSONSerialization.jsonObject(with: http.emoteMetadata()) as! [String: Any]
        for template in ["https://evil.invalid/{{id}}", "https://static-cdn.jtvnw.net@evil.invalid/{{id}}"] {
            object["template"] = template
            do { _ = try StudioDirectChatDecoder.twitchStaticEmote(json(object), metadata: metadata); preconditionFailure() } catch {}
        }
        for (key, value) in [("format", ["animated"]), ("theme_mode", ["dark"]), ("scale", ["1.0"])] {
            object = try JSONSerialization.jsonObject(with: http.emoteMetadata()) as! [String: Any]
            var items = object["data"] as! [[String: Any]]; items[0][key] = value; object["data"] = items
            do { _ = try StudioDirectChatDecoder.twitchStaticEmote(json(object), metadata: metadata); preconditionFailure() } catch {}
        }
        clock.advance(2); http.holdEmotes = true
        let pending = Task { try await manager.staticEmoteURL(for: message) }
        await until { http.lateEmote != nil }; manager.shutdown()
        http.lateEmote?.resume(returning: http.emoteMetadata()); http.lateEmote = nil
        do { _ = try await pending.value; preconditionFailure("Late metadata read survived reader retirement") } catch {}
        print("PASS: authorized shared Twitch reader static emote identity/template/capability lookup; one-per-second metadata guard, no guessed artwork URL and retired-response refusal")
    }
    @MainActor static func validateAudience() async throws {
        let http = HTTPFixture(), gate = PollGate(), stream = StreamFixture(), clock = FixtureTime()
        let socket = FixtureSocket(), pool = FixtureSockets([socket])
        let manager = StudioDirectChatManager(request: http.send, identity: { provider in
            .init(channelID: "owner", scopes: provider == .youtube ? ManagedProvider.youtube.scopes : TwitchDeviceAuthorization.optionalChatScopes)
        }, socketFactory: pool.make, sleep: { try await gate.sleep($0) }, now: clock.now, emit: stream.receive)
        manager.refreshAudience(.youtube)
        precondition(http.calls.isEmpty && manager.audience(.youtube).availability == .notRequested)
        manager.connect(.youtube, eventID: "owned-event")
        manager.connect(.twitch)
        await until { manager.snapshot(.youtube).isConnected && !pool.opened.isEmpty }
        socket.push(twitchControl("session_welcome"))
        await until { manager.snapshot(.twitch).isConnected }
        precondition(http.calls.allSatisfy { !["/youtube/v3/videos", "/helix/streams"].contains($0.1.url!.path) })
        manager.refreshAudience(.youtube); manager.refreshAudience(.youtube); manager.refreshAudience(.twitch)
        await until { manager.audience(.youtube).count == 123 && manager.audience(.twitch).count == 37 }
        precondition(http.calls.filter { $0.1.url!.path == "/youtube/v3/videos" }.count == 1)
        precondition(!manager.canRefreshAudience(.youtube) && manager.audience(.youtube).isFresh(at: clock.now()))
        let youtubeCall = http.calls.first { $0.1.url!.path == "/youtube/v3/videos" }!.1
        let youtubeQuery = URLComponents(url: youtubeCall.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(youtubeQuery.contains { $0.name == "id" && $0.value == "owned-event" })
        precondition(youtubeQuery.contains { $0.name == "part" && $0.value == "snippet,liveStreamingDetails" })
        let twitchQuery = URLComponents(url: http.calls.first { $0.1.url!.path == "/helix/streams" }!.1.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(twitchQuery.contains { $0.name == "user_id" && $0.value == "owner" })
        clock.advance(61)
        precondition(!manager.audience(.youtube).isFresh(at: clock.now()) && manager.canRefreshAudience(.youtube))
        http.audienceFailure = ProviderFailure(.permission)
        manager.refreshAudience(.youtube)
        await until { manager.audience(.youtube).availability == .failed }
        precondition(manager.audience(.youtube).count == 123 && !manager.audience(.youtube).isFresh(at: clock.now()))
        precondition(manager.snapshot(.youtube).isConnected && manager.snapshot(.twitch).isConnected)
        let incomingID = "during-metrics-failure"
        socket.push(twitchEvent(incomingID))
        await until { stream.queue.messages.contains { $0.id == StudioDirectChatDecoder.identity(.twitch, "owner", incomingID) } }
        clock.advance(31); http.audienceFailure = ProviderFailure(.rateLimited, retryAfter: 120)
        manager.refreshAudience(.youtube)
        await until { !manager.audience(.youtube).isRefreshing }
        precondition(manager.audience(.youtube).retryUntil == clock.now().addingTimeInterval(120))
        clock.advance(121); http.audienceFailure = nil; http.holdAudience = true
        manager.refreshAudience(.youtube)
        await until { http.lateAudience != nil }
        manager.stop(.youtube)
        http.lateAudience?.resume(returning: audienceYouTube("999")); http.lateAudience = nil
        for _ in 0..<5 { await Task.yield() }
        precondition(manager.audience(.youtube) == DirectChatAudience() && manager.audience(.twitch).count == 37)
        manager.shutdown()

        // Completion while the same account generation is reconnecting must
        // release its pending refresh, for both success and failure outcomes.
        for completionFails in [false, true] {
            let transientHTTP = HTTPFixture(), transientGate = PollGate(), transientTime = FixtureTime()
            let first = FixtureSocket(), second = FixtureSocket(), transientPool = FixtureSockets([first, second])
            let transient = StudioDirectChatManager(request: transientHTTP.send,
                identity: { _ in .init(channelID: "owner", scopes: TwitchDeviceAuthorization.optionalChatScopes) },
                socketFactory: transientPool.make, sleep: { try await transientGate.sleep($0) }, now: transientTime.now, emit: { _ in })
            transient.connect(.twitch); await until { transientPool.opened.count == 1 }
            first.push(twitchControl("session_welcome")); await until { transient.snapshot(.twitch).isConnected }
            transientHTTP.holdAudience = true; transient.refreshAudience(.twitch)
            await until { transientHTTP.lateAudience != nil }
            first.cancel(); await until { transient.snapshot(.twitch).state == "Reconnecting" }
            if completionFails { transientHTTP.lateAudience?.resume(throwing: ProviderFailure(.permission)) }
            else { transientHTTP.lateAudience?.resume(returning: json(["data": [["user_id": "owner", "type": "live", "viewer_count": 99]]])) }
            transientHTTP.lateAudience = nil
            await until { !transient.audience(.twitch).isRefreshing }
            precondition(transient.audience(.twitch).count == nil) // disconnected result rejected
            transientTime.advance(31); transientHTTP.holdAudience = false
            await transientGate.resume(); await until { transientPool.opened.count == 2 }
            second.push(twitchControl("session_welcome", session: "after-reconnect"))
            await until { transient.snapshot(.twitch).isConnected }
            precondition(transient.canRefreshAudience(.twitch))
            transient.refreshAudience(.twitch); await until { transient.audience(.twitch).count == 37 }
            transient.shutdown()
        }

        let target = DirectChatWriteTarget(provider: .youtube, channelID: "owner", chatID: "live-chat", broadcastID: "owned-event", generation: UUID())
        let hidden = try StudioAudienceDecoder.decode(audienceYouTube(), provider: .youtube, target: target, observedAt: clock.now())
        precondition(hidden.count == nil && hidden.availability == .unavailable)
        let zero = try StudioAudienceDecoder.decode(audienceYouTube("0"), provider: .youtube, target: target, observedAt: clock.now())
        precondition(zero.count == 0 && zero.availability == .available)
        let offline = try StudioAudienceDecoder.decode(audienceYouTube("123", ended: true), provider: .youtube, target: target, observedAt: clock.now())
        precondition(offline.count == nil && offline.availability == .offline)
        for invalid: Any in ["-1", "1.5", "١٢", "18446744073709551616", true, 99] {
            do { _ = try StudioAudienceDecoder.decode(audienceYouTube(invalid), provider: .youtube, target: target, observedAt: clock.now()); preconditionFailure("Invalid YouTube count accepted") } catch {}
        }
        do { _ = try StudioAudienceDecoder.decode(audienceYouTube("3", chatID: "another-chat"), provider: .youtube, target: target, observedAt: clock.now()); preconditionFailure("Wrong live target accepted") } catch {}
        let twitchTarget = DirectChatWriteTarget(provider: .twitch, channelID: "owner", chatID: "owner", broadcastID: "owner", generation: UUID())
        let absent = try StudioAudienceDecoder.decode(json(["data": []]), provider: .twitch, target: twitchTarget, observedAt: clock.now())
        precondition(absent.availability == .offline && absent.count == nil)
        for invalid: Any in [-1, 0.5, true, "37"] {
            do { _ = try StudioAudienceDecoder.decode(json(["data": [["user_id": "owner", "type": "live", "viewer_count": invalid]]]), provider: .twitch, target: twitchTarget, observedAt: clock.now()); preconditionFailure("Invalid Twitch count accepted") } catch {}
        }
        precondition(StudioChatActivity(kind: "Super Sticker").canPromoteAlert)
        precondition(StudioChatActivity(kind: "Gift").canPromoteAlert)
        precondition(!StudioChatActivity(kind: "Text").canPromoteAlert && !StudioChatActivity(kind: "Unknown").canPromoteAlert)
        print("PASS: native audience metrics; explicit owned-target reads, independent providers, bounded counts, absent/hidden/offline vs zero, freshness and throttling, permission/rate failure with incoming continuity, late response cancellation, transient reconnect success/error completion cleanup, typed event/alert eligibility")
    }
    @MainActor static func validateOutbox() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stream-chat-presets-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let presets = StudioChatPresetStore(directory: root)
        precondition(presets.save(name: "Welcome", text: "Welcome 👩🏽‍🚀 世界"))
        let presetID = presets.document.presets[0].id
        precondition(presets.save(name: "Edited", text: "Literal 123e4567-e89b-12d3-a456-426614174000", replacing: presetID))
        let restored = StudioChatPresetStore(directory: root)
        precondition(restored.document == presets.document)
        var remap: [String: String] = [:]
        let portable = try PortableShow.redact(Data(contentsOf: root.appendingPathComponent("chat-presets.json")), remappingIDs: true, idMap: &remap)
        let imported = try JSONDecoder().decode(DirectChatPresetDocument.self, from: portable)
        precondition(imported.presets[0].id != presetID && imported.presets[0].text == restored.document.presets[0].text)
        precondition(PortableShow.documentNames.contains("chat-presets.json"))
        let plain = String(decoding: try Data(contentsOf: root.appendingPathComponent("chat-presets.json")), as: UTF8.self)
        precondition(!plain.contains("provider") && !plain.contains("target") && !plain.contains("credential") && !plain.contains("receipts"))
        for index in 1..<32 { precondition(presets.save(name: "Preset \(index)", text: "Text")) }
        precondition(!presets.save(name: "Too many", text: "Text") && presets.document.presets.count == 32)
        presets.remove(presetID); precondition(presets.document.presets.count == 31)
        precondition(!presets.save(name: "Long", text: String(repeating: "x", count: 501)))
        let future = root.appendingPathComponent("future"); try FileManager.default.createDirectory(at: future, withIntermediateDirectories: true)
        let futureData = json(["version": 2, "presets": []]); try futureData.write(to: future.appendingPathComponent("chat-presets.json"))
        let futureStore = StudioChatPresetStore(directory: future)
        precondition(!futureStore.writable && !futureStore.save(name: "Overwrite", text: "No"))
        let preservedFuture = try Data(contentsOf: future.appendingPathComponent("chat-presets.json"))
        precondition(preservedFuture == futureData)
        let oversized = root.appendingPathComponent("oversized"); try FileManager.default.createDirectory(at: oversized, withIntermediateDirectories: true)
        let oversizedData = Data(repeating: 32, count: 262145)
        try oversizedData.write(to: oversized.appendingPathComponent("chat-presets.json"))
        let oversizedStore = StudioChatPresetStore(directory: oversized)
        precondition(!oversizedStore.writable && oversizedStore.document.presets.isEmpty)
        let preservedOversized = try Data(contentsOf: oversized.appendingPathComponent("chat-presets.json"))
        precondition(preservedOversized == oversizedData)

        let http = HTTPFixture(), gate = PollGate(), stream = StreamFixture(), time = FixtureTime()
        let first = FixtureSocket(), second = FixtureSocket(), third = FixtureSocket()
        let sockets = FixtureSockets([first, second, third])
        let manager = StudioDirectChatManager(request: http.send, identity: { provider in
            .init(channelID: "owner", scopes: provider == .youtube ? ManagedProvider.youtube.scopes : TwitchDeviceAuthorization.optionalChatScopes)
        }, socketFactory: sockets.make, sleep: { try await gate.sleep($0) }, presetDirectory: root,
            now: { time.now() }, emit: stream.receive)
        precondition(manager.presets.document.presets.count == 31 && manager.receipts.isEmpty && http.calls.isEmpty)
        manager.connect(.youtube, eventID: "owned-event"); await until { manager.snapshot(.youtube).isConnected }
        manager.connect(.twitch); await until { !sockets.opened.isEmpty }; first.push(twitchControl("session_welcome"))
        await until { manager.snapshot(.twitch).isConnected }
        first.push(twitchEvent("outbox-one")); await until { stream.queue.messages.count == 3 }
        let capturedYT = manager.writeTarget(.youtube)!, capturedTW = manager.writeTarget(.twitch)!
        let queueCount = stream.queue.messages.count
        http.writeFailures[.twitch] = ProviderFailure(.permission)
        let partial = manager.send("Explicit multi-provider 👩🏽‍🚀 世界", to: [capturedYT, capturedTW])
        await until { !manager.snapshot(.youtube).isMutating && !manager.snapshot(.twitch).isMutating }
        precondition(partial.count == 2 && manager.receipts.count == 2)
        precondition(manager.receipts[0].state == .acknowledged)
        if case .rejected = manager.receipts[1].state {} else { preconditionFailure("403 was not a refusal") }
        precondition(manager.receipts[0].batchID == manager.receipts[1].batchID && stream.queue.messages.count == queueCount)
        precondition(manager.snapshot(.twitch).isConnected && !manager.canSend(.twitch) && manager.canSend(.youtube))
        precondition(manager.snapshot(.twitch).publicReaderState == "connected",
                     "A refused write incorrectly marked the public incoming reader failed")
        first.push(twitchEvent("after-post-denied")); await until { stream.queue.messages.count == queueCount + 1 }
        precondition(manager.send("Duplicate targets", to: [capturedYT, capturedYT]).isEmpty)
        let postsBefore = http.calls.filter { ["/helix/chat/messages", "/youtube/v3/liveChat/messages"].contains($0.1.url!.path) && $0.1.httpMethod == "POST" }.count
        http.writeFailures[.twitch] = nil
        manager.send("Denied grant is not retried", provider: .twitch)
        precondition(http.calls.filter { ["/helix/chat/messages", "/youtube/v3/liveChat/messages"].contains($0.1.url!.path) && $0.1.httpMethod == "POST" }.count == postsBefore)
        // A failed write does not interrupt the same provider's incoming reader.
        let one = stream.queue.messages.first!.id; stream.queue.favorite(one); stream.queue.enqueue(one); stream.queue.show(one)
        await gate.resume(); await until { stream.queue.messages.contains { $0.kind == "Super Sticker" } }
        precondition(stream.queue.favorites.contains(one) && stream.queue.featuredID == one)

        http.writeFailures[.youtube] = ProviderFailure(.rateLimited, retryAfter: 7)
        let limited = manager.send("Rate-limited action", provider: .youtube)
        await until { !manager.snapshot(.youtube).isMutating }
        if case .rejected = manager.receipts.first(where: { $0.id == limited })!.state {} else { preconditionFailure() }
        precondition(!manager.canSend(.youtube) && manager.snapshot(.twitch).isConnected)
        http.writeFailures[.youtube] = nil; time.advance(8)
        precondition(manager.canSend(.youtube))
        http.rateLimitedReads = 1; http.readItems = [youtubeItem("fresh-youtube")]
        await gate.resume(); await until { manager.snapshot(.youtube).state.contains("Rate limited") }
        precondition(manager.snapshot(.youtube).publicReaderState == "connecting")
        let beforeResume = stream.queue.messages.count
        precondition(stream.queue.featuredID == one && stream.queue.favorites.contains(one))
        time.advance(6); await gate.resume(); await until { manager.snapshot(.youtube).isConnected && stream.queue.messages.count > beforeResume }
        precondition(http.calls.filter { ["/helix/chat/messages", "/youtube/v3/liveChat/messages"].contains($0.1.url!.path) && $0.1.httpMethod == "POST" }.count == postsBefore + 1)
        // The identical read page token resumes; public writes are never replayed.
        let reads = http.calls.filter { $0.1.url!.path == "/youtube/v3/liveChat/messages" && ($0.1.httpMethod ?? "GET") == "GET" }
        precondition(reads[reads.count-2].1.url == reads.last!.1.url)

        let freshYT = StudioDirectChatDecoder.identity(.youtube, "live-chat", "fresh-youtube")
        let twitchOne = StudioDirectChatDecoder.identity(.twitch, "owner", "outbox-one")
        precondition(manager.moderationAvailabilityError(freshYT, kind: .timeout) == nil)
        http.banDurationOverride = 600.5
        let wrongDuration = manager.moderate(freshYT, kind: .timeout)!
        await until { !manager.snapshot(.youtube).isMutating }
        if case .unconfirmed = manager.receipts.first(where: { $0.id == wrongDuration })!.state {} else { preconditionFailure() }
        precondition(stream.queue.message(freshYT) != nil)
        http.banDurationOverride = nil
        manager.moderate(freshYT, kind: .timeout, expectedTarget: manager.writeTarget(.youtube))
        await until { !manager.snapshot(.youtube).isMutating }
        precondition(stream.queue.message(freshYT) == nil && stream.queue.message(twitchOne) != nil)
        let ytTimeout = http.calls.last!.1, ytBody = try JSONSerialization.jsonObject(with: ytTimeout.httpBody!) as! [String: Any]
        let ytSnippet = ytBody["snippet"] as! [String: Any]
        precondition(ytTimeout.url!.path == "/youtube/v3/liveChat/bans" && ytTimeout.httpMethod == "POST")
        precondition(ytSnippet["type"] as? String == "temporary" && ytSnippet["banDurationSeconds"] as? Int == 600)
        precondition((ytSnippet["bannedUserDetails"] as! [String: Any])["channelId"] as? String == "viewer")
        // A malformed response is uncertain and does not remove incoming text.
        http.readItems = [youtubeItem("ban-youtube")]; await gate.resume()
        let ytBanID = StudioDirectChatDecoder.identity(.youtube, "live-chat", "ban-youtube")
        await until { stream.queue.message(ytBanID) != nil }; http.malformedBan = true
        let uncertain = manager.moderate(ytBanID, kind: .ban)!
        await until { !manager.snapshot(.youtube).isMutating }
        if case .unconfirmed = manager.receipts.first(where: { $0.id == uncertain })!.state {} else { preconditionFailure() }
        precondition(stream.queue.message(ytBanID) != nil)
        http.malformedBan = false; manager.moderate(ytBanID, kind: .ban)
        await until { stream.queue.message(ytBanID) == nil }
        let ytBan = (try JSONSerialization.jsonObject(with: http.calls.last!.1.httpBody!) as! [String: Any])["snippet"] as! [String: Any]
        precondition(ytBan["type"] as? String == "permanent" && ytBan["banDurationSeconds"] == nil)

        manager.moderate(twitchOne, kind: .timeout)
        await until { !manager.snapshot(.twitch).isMutating }
        let twTimeout = http.calls.last!.1, twBody = (try JSONSerialization.jsonObject(with: twTimeout.httpBody!) as! [String: Any])["data"] as! [String: Any]
        precondition(twTimeout.url!.path == "/helix/moderation/bans" && twTimeout.httpMethod == "POST")
        precondition(twBody["duration"] as? Int == 600 && twBody["user_id"] as? String == "viewer")
        precondition(stream.queue.message(twitchOne) == nil)
        first.push(twitchEvent("ban-twitch", author: "other-viewer"))
        let twBanID = StudioDirectChatDecoder.identity(.twitch, "owner", "ban-twitch")
        await until { stream.queue.message(twBanID) != nil }; manager.moderate(twBanID, kind: .ban)
        await until { stream.queue.message(twBanID) == nil }
        let twBan = (try JSONSerialization.jsonObject(with: http.calls.last!.1.httpBody!) as! [String: Any])["data"] as! [String: Any]
        precondition(twBan["duration"] == nil && twBan["user_id"] as? String == "other-viewer")
        first.push(twitchEvent("protected", moderator: true)); first.push(twitchEvent("own-message", author: "owner"))
        let protected = StudioDirectChatDecoder.identity(.twitch, "owner", "protected")
        await until { stream.queue.message(protected) != nil && stream.queue.message(StudioDirectChatDecoder.identity(.twitch, "owner", "own-message")) != nil }
        precondition(manager.moderationAvailabilityError(protected, kind: .ban) != nil)
        precondition(manager.moderationAvailabilityError(StudioDirectChatDecoder.identity(.twitch, "owner", "own-message"), kind: .timeout) != nil)
        let protectedCount = http.calls.count; manager.moderate(protected, kind: .ban); precondition(http.calls.count == protectedCount)

        // An explicit reconnect re-verifies grants and cannot replay a send.
        manager.connect(.twitch); await until { sockets.opened.count == 2 }
        second.push(twitchControl("session_welcome", session: "outbox-two")); await until { manager.canSend(.twitch) }
        let afterReconnect = http.calls.filter { $0.1.url!.path == "/helix/chat/messages" }.count
        precondition(afterReconnect == 1)
        http.holdWrites = [.youtube, .twitch]
        let held = manager.send("Wait for actual outcomes", to: [manager.writeTarget(.youtube)!, manager.writeTarget(.twitch)!])
        await until { http.heldWrites.count == 2 }
        let heldTW = held[1], heldYT = held[0]
        let countHeld = http.calls.count; manager.send("Busy provider is not queued", provider: .twitch); precondition(http.calls.count == countHeld)
        manager.stop(.youtube)
        precondition(manager.receipts.first(where: { $0.id == heldYT })!.state == .stopped && manager.snapshot(.twitch).isConnected)
        http.heldWrites.removeValue(forKey: .youtube)?.resume(returning: json(["id": "late-after-account-disconnect"]))
        try? await Task.sleep(for: .milliseconds(20)); precondition(manager.receipts.first(where: { $0.id == heldYT })!.state == .stopped)
        manager.cancelWrite(receiptID: heldTW); precondition(manager.receipts.first(where: { $0.id == heldTW })!.state == .stopped)
        http.holdWrites = []; let fresh = manager.send("Explicit new write", provider: .twitch)
        await until { manager.receipts.first(where: { $0.id == fresh })?.state == .acknowledged }
        http.heldWrites.removeValue(forKey: .twitch)?.resume(returning: json(["data": [["is_sent": true, "message_id": "old-late"]]]))
        try? await Task.sleep(for: .milliseconds(20)); precondition(manager.receipts.first(where: { $0.id == heldTW })!.state == .stopped)
        precondition(manager.receipts.first(where: { $0.id == fresh })!.state == .acknowledged)
        manager.connect(.youtube, eventID: "owned-event"); await until { manager.snapshot(.youtube).isConnected }
        let beforeStale = http.calls.count
        let stale = manager.send("Old review", provider: .youtube, expectedTarget: capturedYT)
        if case .notSent = manager.receipts.first(where: { $0.id == stale })!.state {} else { preconditionFailure() }
        precondition(http.calls.count == beforeStale)
        // Requests have no unbounded pending queue; history stays at 64.
        for _ in 0..<80 { manager.send("Read-only unsupported target", provider: .restream) }
        precondition(manager.receipts.count == 64 && http.calls.count == beforeStale)
        let hugeCluster = manager.send("x" + String(repeating: "\u{0301}", count: 20000), provider: .twitch)
        precondition(manager.receipts.first(where: { $0.id == hugeCluster })!.summary.utf8.count <= 4100)
        precondition(http.calls.count == beforeStale)
        http.holdWrites = [.youtube, .twitch]
        let stoppedBatch = manager.send("Shutdown unknown outcomes", to: [manager.writeTarget(.youtube)!, manager.writeTarget(.twitch)!])
        await until { http.heldWrites.count == 2 }; manager.shutdown()
        precondition(stoppedBatch.allSatisfy { id in manager.receipts.first(where: { $0.id == id })!.state == .stopped })
        http.heldWrites.removeValue(forKey: .youtube)?.resume(returning: json(["id": "late-profile-change"]))
        http.heldWrites.removeValue(forKey: .twitch)?.resume(returning: json(["data": [["is_sent": true, "message_id": "late-recovery"]]]))
        try? await Task.sleep(for: .milliseconds(20))
        precondition(stoppedBatch.allSatisfy { id in manager.receipts.first(where: { $0.id == id })!.state == .stopped })
        manager.clearReceipts(); precondition(manager.receipts.isEmpty && stream.queue.messages.contains { $0.id == protected })

        let readOnlyHTTP = HTTPFixture(), readOnlySocket = FixtureSocket(), readOnlyPool = FixtureSockets([readOnlySocket])
        let readOnlyStream = StreamFixture()
        let readOnly = StudioDirectChatManager(request: readOnlyHTTP.send, identity: { _ in .init(channelID: "owner", scopes: ["user:read:chat"]) },
            socketFactory: readOnlyPool.make, emit: readOnlyStream.receive)
        readOnly.connect(.twitch); await until { !readOnlyPool.opened.isEmpty }; readOnlySocket.push(twitchControl("session_welcome"))
        await until { readOnly.snapshot(.twitch).isConnected }; readOnlySocket.push(twitchEvent("readonly"))
        let readOnlyID = StudioDirectChatDecoder.identity(.twitch, "owner", "readonly")
        await until { readOnlyStream.queue.message(readOnlyID) != nil }
        precondition(!readOnly.canSend(.twitch) && !readOnly.canDelete(readOnlyID))
        precondition(readOnly.moderationAvailabilityError(readOnlyID, kind: .ban)!.contains("moderator:manage:banned_users"))
        let readOnlyCalls = readOnlyHTTP.calls.count; readOnly.moderate(readOnlyID, kind: .ban)
        precondition(readOnlyHTTP.calls.count == readOnlyCalls && readOnly.snapshot(.twitch).isConnected)
        readOnly.shutdown()
        print("PASS: native chat outbox; exact per-provider opt-in/targets and send-once partial receipts; permission/rate/read cooldown isolation; no fake echo/replay; YouTube/Twitch targeted delete/600s timeout/ban body and response gates; protected/read-only routes; stopped/late/stale-generation results; bounded64 receipts; project-only32 presets/restart/portable literal text/future-document preservation")
    }

}
