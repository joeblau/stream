import Foundation
import StreamCore

private struct NoticeFailure: Error, CustomStringConvertible { let description: String }
private func check(_ value: @autoclosure () -> Bool, _ reason: String) throws {
    if !value() { throw NoticeFailure(description: reason) }
}
private func json(_ value: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: value) }
private func notification(_ id: String, type: String = "sub", anonymous: Bool = false,
                          changes: [String: Any] = [:], channel: String = "owner") -> Data {
    var event: [String: Any] = ["broadcaster_user_id": channel, "message_id": id, "notice_type": type,
        "chatter_user_id": "viewer", "chatter_user_name": "Viewer 世界", "chatter_is_anonymous": anonymous,
        "badges": [["set_id": "subscriber"]], "system_message": "Provider public notice 👩🏽‍🚀 {host}",
        "message": ["text": "Literal user caption 世界 {private}", "fragments": []],
        "sub": ["sub_tier": "1000", "duration_months": 1],
        "unused_private_field": "MUST NOT RETAIN", "image_url": "https://invalid.invalid/never-fetch"]
    for (key, value) in changes { event[key] = value }
    return json(["metadata": ["message_type": "notification", "message_timestamp": "2026-10-22T20:00:00Z"],
        "payload": ["subscription": ["type": "channel.chat.notification", "version": "1",
            "condition": ["broadcaster_user_id": "owner", "user_id": "owner"]], "event": event]])
}
private func control(_ type: String, session: String = "owned-session", url: String? = nil) -> Data {
    var value: [String: Any] = ["id": session, "keepalive_timeout_seconds": 600]
    if let url { value["reconnect_url"] = url }
    return json(["metadata": ["message_type": type], "payload": ["session": value]])
}
private final class NoticeSocket: StudioChatSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []
    private var pending: CheckedContinuation<Data, Error>?
    private var closed = false
    let holdsCancellation: Bool
    init(holdsCancellation: Bool = false) { self.holdsCancellation = holdsCancellation }
    var isClosed: Bool { lock.withLock { closed } }
    var isWaiting: Bool { lock.withLock { pending != nil } }
    func push(_ data: Data) {
        let waiter = lock.withLock { () -> CheckedContinuation<Data, Error>? in
            guard !closed else { return nil }
            if let pending { self.pending = nil; return pending }
            values.append(data); return nil
        }; waiter?.resume(returning: data)
    }
    func receive() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { next in
                let value = lock.withLock { () -> Result<Data, Error>? in
                    if closed { return .failure(CancellationError()) }
                    if !values.isEmpty { return .success(values.removeFirst()) }
                    precondition(pending == nil); pending = next; return nil
                }
                if let value { next.resume(with: value) }
            }
        } onCancel: { self.cancel() }
    }
    func cancel() {
        let waiter = lock.withLock { () -> CheckedContinuation<Data, Error>? in
            closed = true
            guard !holdsCancellation else { return nil }
            let result = pending; pending = nil; return result
        }; waiter?.resume(throwing: CancellationError())
    }
    func releaseAfterCancellation(_ data: Data) {
        let waiter = lock.withLock { () -> CheckedContinuation<Data, Error>? in
            precondition(closed); let result = pending; pending = nil; return result
        }; precondition(waiter != nil); waiter?.resume(returning: data)
    }
}
private final class NoticeSockets: @unchecked Sendable {
    private let lock = NSLock()
    private var available: [NoticeSocket]
    private var count = 0
    init(_ available: [NoticeSocket]) { self.available = available }
    func make(_ url: URL) -> any StudioChatSocket {
        lock.withLock {
            precondition(url.scheme == "wss" && url.host == "eventsub.wss.twitch.tv")
            precondition(!available.isEmpty); count += 1; return available.removeFirst()
        }
    }
    var opened: Int { lock.withLock { count } }
}
@MainActor private final class NoticeHTTP {
    var types: [String] = []
    var malformedNoticeACK = false
    var heldNoticeACK: CheckedContinuation<Data, Error>?
    var holdNoticeACK = false
    func send(_ provider: ManagedProvider, _ request: URLRequest) async throws -> Data {
        try check(provider == .twitch && request.httpMethod == "POST" && request.url?.host == "api.twitch.tv"
            && request.url?.path == "/helix/eventsub/subscriptions", "Unexpected external or mutation request")
        var body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let condition = body["condition"] as! [String: String]
        try check(condition == ["broadcaster_user_id": "owner", "user_id": "owner"] && body["version"] as? String == "1",
                  "Subscription changed account/condition/version")
        let transport = body["transport"] as! [String: String]
        try check(transport["method"] == "websocket" && transport["session_id"] != nil, "Subscription lost socket ownership")
        let type = body["type"] as! String; types.append(type)
        body["status"] = "enabled"
        if type == "channel.chat.notification" && malformedNoticeACK { body["type"] = "channel.chat.message" }
        let result = json(["data": [body]])
        if type == "channel.chat.notification" && holdNoticeACK {
            return try await withCheckedThrowingContinuation { heldNoticeACK = $0 }
        }
        return result
    }
}
@MainActor private final class NoticeStream {
    var queue = StudioChatQueue()
    var actions = 0
    func receive(_ value: StudioChatAction) {
        actions += 1
        switch value {
        case .message(let message): queue.receive(message)
        case .removed(let ids): queue.discard(ids)
        default: break
        }
    }
}
@main @MainActor private enum TwitchChatNotificationsHarness {
    static let expectedTypes = ["channel.chat.message", "channel.chat.message_delete", "channel.chat.clear",
                                "channel.chat.clear_user_messages", "channel.chat.notification"]
    static func until(_ reason: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<400 { if predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw NoticeFailure(description: "Deadline: " + reason)
    }
    static func make(_ http: NoticeHTTP, _ sockets: NoticeSockets, _ stream: NoticeStream) -> StudioDirectChatManager {
        StudioDirectChatManager(request: http.send, identity: { _ in
            // Controlled existing identity inlet; no account/Keychain/OAuth object.
            .init(channelID: "owner", scopes: ["user:read:chat", "user:write:chat", "moderator:manage:chat_messages", "moderator:manage:banned_users"])
        }, socketFactory: sockets.make, emit: stream.receive)
    }
    static func run() async throws {
        let kinds = ["sub": "Membership", "resub": "Milestone", "sub_gift": "Gift", "community_sub_gift": "Gift"]
        for type in ["sub", "resub", "sub_gift", "community_sub_gift"] {
            print("CHECK decoder " + type)
            let value = try StudioDirectChatDecoder.twitch(notification(type, type: type), channelID: "owner", userID: "owner")
            guard let message = value.delivery?.message else { throw NoticeFailure(description: "Supported notice omitted: " + type) }
            try check(message.kind == kinds[type] && message.text == "Provider public notice 👩🏽‍🚀 {host}\nLiteral user caption 世界 {private}", "Notice kind or literal public fields changed")
            try check(message.author == "Viewer 世界" && message.roles == ["Member"] && message.staticEmote == nil && message.avatarURL == nil,
                      "Notice invented author roles or media")
            let serialized = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
            try check(!serialized.contains("MUST NOT RETAIN") && !serialized.contains("never-fetch") && !serialized.contains("sub_tier"),
                      "Raw metadata leaked into typed message")
        }
        let anonymous = try StudioDirectChatDecoder.twitch(notification("anonymous", type: "sub_gift", anonymous: true,
            changes: ["chatter_user_id": "CONTRADICTORY PRIVATE ID", "chatter_user_name": "CONTRADICTORY PRIVATE NAME", "badges": [["set_id": "moderator"]]]), channelID: "owner", userID: "owner").delivery!
        try check(anonymous.message.author == "Anonymous" && anonymous.message.roles.isEmpty && anonymous.route.authorID.isEmpty,
                  "Anonymous notice retained contradictory identity/roles")
        let onlySystem = try StudioDirectChatDecoder.twitch(notification("system", changes: ["message": ["text": ""]]), channelID: "owner", userID: "owner")
        try check(onlySystem.delivery?.message.text == "Provider public notice 👩🏽‍🚀 {host}", "Empty public user message lost system notice")
        for type in ["unknown", "shared_chat_sub", "shared_chat_resub", "shared_chat_sub_gift", "raid", "announcement", "charity_donation"] {
            let value = try StudioDirectChatDecoder.twitch(notification(type, type: type), channelID: "owner", userID: "owner")
            try check(value.delivery == nil, "Unsupported notice entered public stream")
        }
        for changes: [String: Any] in [["source_broadcaster_user_id": "different-source"], ["chatter_is_anonymous": 1],
            ["chatter_is_anonymous": NSNull()], ["system_message": String(repeating: "x", count: 16_385)],
            ["system_message": String(repeating: "x", count: 16_380)], ["message": ["text": String(repeating: "x", count: 16_385)]],
            ["system_message": "", "message": ["text": ""]], ["chatter_user_name": String(repeating: "x", count: 513)]] {
            let value = try StudioDirectChatDecoder.twitch(notification("bad", changes: changes), channelID: "owner", userID: "owner")
            try check(value.delivery == nil, "Malformed/oversized notice was accepted")
        }
        do {
            _ = try StudioDirectChatDecoder.twitch(notification("wrong-owner", channel: "different-channel"), channelID: "owner", userID: "owner")
            throw NoticeFailure(description: "Wrong event owner was accepted")
        } catch is ProviderFailure {}
        print("PASS decoder:4 kinds, public text/Unicode, anonymous privacy,7 unsupported,8 malformed, owner binding")

        let http = NoticeHTTP(), first = NoticeSocket(), migrated = NoticeSocket(holdsCancellation: true)
        let sockets = NoticeSockets([first, migrated]), stream = NoticeStream(), manager = make(http, sockets, stream)
        defer { manager.shutdown() }
        manager.connect(.twitch); try await until("socket") { sockets.opened == 1 }
        first.push(control("session_welcome")); try await until("subscriptions") { manager.snapshot(.twitch).isConnected }
        try check(http.types == expectedTypes, "Public notification subscription absent/duplicated")
        for type in ["sub", "resub", "sub_gift", "community_sub_gift"] { first.push(notification(type, type: type)) }
        first.push(notification("sub"))
        try await until("four notices") { stream.queue.messages.count == 4 }
        let memberID = StudioDirectChatDecoder.identity(.twitch, "owner", "sub")
        try check(stream.queue.filtered(search: "", audienceEvent: .membership).count == 1
            && stream.queue.filtered(search: "", audienceEvent: .milestone).count == 1
            && stream.queue.filtered(search: "", audienceEvent: .gift).count == 2, "Existing event filters lost notice kinds")
        try check(StudioAudienceEventKind.gift.defaultStyle == .violet && StudioAudienceEventKind.membership.supportsAlert,
                  "Notice lost existing event styling/manual promotion capability")
        try check(!manager.canReply(memberID) && manager.targetForMessage(memberID) == nil, "Notice became public reply target")
        for kind in [DirectChatWriteKind.delete, .timeout, .ban] {
            try check(manager.moderationAvailabilityError(memberID, kind: kind) != nil, "Notice exposed moderation")
            _ = manager.moderate(memberID, kind: kind)
        }
        _ = manager.send("Never deliver to notification", provider: .twitch, replyingTo: memberID)
        try check(http.types == expectedTypes && manager.receipts.count == 4 && manager.receipts.allSatisfy {
            if case .notSent = $0.state { return true }; return false
        }, "Read-only notification triggered mutation or misleading receipt")
        first.push(notification("ignored", type: "shared_chat_sub")); first.push(control("session_reconnect", url: "wss://eventsub.wss.twitch.tv/ws?owned=migrate"))
        try await until("migration socket") { sockets.opened == 2 }
        first.push(notification("during", type: "resub")); try await until("old live during migration") { stream.queue.messages.count == 5 }
        migrated.push(control("session_welcome", session: "migrated")); try await until("old retired") { first.isClosed }
        try check(http.types == expectedTypes, "Migration resubscribed public notices")
        migrated.push(notification("during", type: "resub")); migrated.push(notification("fresh", type: "sub_gift"))
        try await until("new live") { stream.queue.messages.count == 6 && migrated.isWaiting }
        let actions = stream.actions
        manager.stop(.twitch)
        migrated.releaseAfterCancellation(notification("late", type: "sub_gift"))
        try await Task.sleep(for: .milliseconds(30))
        try check(!manager.snapshot(.twitch).isConnected && stream.queue.messages.count == 6 && stream.actions == actions + 1,
                  "Retired notification completion rearmed stream")
        print("PASS manager:5 exact subscription ACKs, dedup/filter/style,4 refused actions,no mutation,migration,retired late response")

        let badHTTP = NoticeHTTP(); badHTTP.malformedNoticeACK = true
        let badSocket = NoticeSocket(), badSockets = NoticeSockets([badSocket]), badStream = NoticeStream()
        let badManager = make(badHTTP, badSockets, badStream); defer { badManager.shutdown() }
        badManager.connect(.twitch); try await until("bad ACK socket") { badSockets.opened == 1 }
        badSocket.push(control("session_welcome")); try await until("bad ACK refused") { badManager.snapshot(.twitch).state == "Failed" }
        try check(!badManager.snapshot(.twitch).isConnected && badSocket.isClosed && badStream.queue.messages.isEmpty,
                  "Mismatched notification ACK accepted")

        let heldHTTP = NoticeHTTP(); heldHTTP.holdNoticeACK = true
        let heldSocket = NoticeSocket(), heldSockets = NoticeSockets([heldSocket]), heldStream = NoticeStream()
        let heldManager = make(heldHTTP, heldSockets, heldStream); defer { heldManager.shutdown() }
        heldManager.connect(.twitch); try await until("held ACK socket") { heldSockets.opened == 1 }
        heldSocket.push(control("session_welcome")); try await until("held ACK") { heldHTTP.heldNoticeACK != nil }
        heldManager.stop(.twitch)
        heldHTTP.heldNoticeACK?.resume(returning: json(["data": []])); heldHTTP.heldNoticeACK = nil
        try await Task.sleep(for: .milliseconds(30))
        try check(!heldManager.snapshot(.twitch).isConnected && heldStream.queue.messages.isEmpty && heldSocket.isClosed,
                  "Retired subscription ACK reconnected")
        print("PASS lifecycle: exact ACK mismatch refused; canceled fifth subscription ACK stays retired")
    }
    static func main() async {
        do { try await run(); print("PASS controlled Twitch public notification fixture") }
        catch { print("FAIL Twitch public notification fixture: \(error)"); exit(1) }
    }
}
