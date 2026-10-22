import Foundation
import StreamCore

private struct GiftFailure: Error, CustomStringConvertible { let description: String }
private func check(_ value: @autoclosure () -> Bool, _ reason: String) throws {
    if !value() { throw GiftFailure(description: reason) }
}
private func json(_ value: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: value) }
private func item(_ id: String, type: String = "giftEvent", text: String = "Gift public caption 👩🏽‍🚀 世界 {host}",
                  chat: String = "owned-chat", display: Bool = true) -> [String: Any] {
    ["id": id, "snippet": ["type": type, "liveChatId": chat, "hasDisplayContent": display,
        "displayMessage": text, "publishedAt": "2026-10-22T20:00:00Z",
        "giftDetails": ["jewelsAmount": 100, "comboCount": 9, "giftName": "NOT PUBLIC DISPLAY TEXT",
            "giftUrl": "https://invalid.invalid/never-fetch", "giftDuration": ["seconds": 100_000],
            "altText": "NOT PUBLIC DISPLAY TEXT", "hasVisualEffect": true]],
     "authorDetails": ["channelId": "viewer", "displayName": "Viewer 世界", "isChatSponsor": true]]
}
private func page(_ items: [[String: Any]], token: String = "next-owned-page") -> Data {
    json(["items": items, "pollingIntervalMillis": 2_500, "nextPageToken": token])
}
private actor GiftPoll {
    private var pending: CheckedContinuation<Void, Error>?
    private var values: [Double] = []
    var waiting: Bool { pending != nil }
    var intervals: [Double] { values }
    func sleep(_ seconds: Double) async throws {
        try Task.checkCancellation(); values.append(seconds)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending = $0 }
        } onCancel: { Task { await self.cancel() } }
        try Task.checkCancellation()
    }
    func resume() { let value = pending; pending = nil; value?.resume() }
    func cancel() { let value = pending; pending = nil; value?.resume(throwing: CancellationError()) }
}
@MainActor private final class GiftHTTP {
    var pages = 0
    var tokens: [String?] = []
    var held: CheckedContinuation<Data, Error>?
    func send(_ provider: ManagedProvider, _ request: URLRequest) async throws -> Data {
        try check(provider == .youtube && request.url?.host == "www.googleapis.com" && (request.httpMethod ?? "GET") == "GET",
                  "Unexpected provider, mutation or external request")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        if request.url?.path == "/youtube/v3/liveBroadcasts" {
            try check(query.contains { $0.name == "id" && $0.value == "owned-broadcast" }, "Broadcast lookup changed target")
            return json(["items": [["id": "owned-broadcast", "snippet": ["channelId": "owner", "liveChatId": "owned-chat"],
                "status": ["lifeCycleStatus": "live"]]]])
        }
        try check(request.url?.path == "/youtube/v3/liveChat/messages" && query.contains { $0.name == "liveChatId" && $0.value == "owned-chat" },
                  "Reader did not keep verified chat")
        tokens.append(query.first { $0.name == "pageToken" }?.value); pages += 1
        if pages == 1 { return page([item("ordinary", type: "textMessageEvent"), item("gift"), item("membership", type: "membershipGiftingEvent")]) }
        if pages == 2 { return page([item("gift", text: "Changed combo caption must not replace first delivery"), item("fresh")], token: "after-update") }
        return try await withCheckedThrowingContinuation { held = $0 }
    }
}
@MainActor private final class GiftStream {
    var queue = StudioChatQueue(), actions = 0
    func receive(_ action: StudioChatAction) {
        actions += 1
        switch action {
        case .message(let message): queue.receive(message)
        case .removed(let ids): queue.discard(ids)
        default: break
        }
    }
}
@main @MainActor private enum YouTubeGiftEventsHarness {
    static func until(_ reason: String, _ predicate: () async -> Bool) async throws {
        for _ in 0..<400 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw GiftFailure(description: "Deadline: " + reason)
    }
    static func run() async throws {
        print("CHECK decoder giftEvent")
        let decoded = try StudioDirectChatDecoder.youtube(page([item("gift")]), channelID: "owner", chatID: "owned-chat")
        try check(decoded.deliveries.count == 1, "Documented giftEvent omitted")
        let value = decoded.deliveries[0]
        try check(value.message.audienceEvent == .gift && value.message.text == "Gift public caption 👩🏽‍🚀 世界 {host}"
            && value.message.roles == ["Member"] && value.route.providerMessageID == "gift", "Gift public display/identity changed")
        let wire = String(decoding: try JSONEncoder().encode(value.message), as: UTF8.self)
        for forbidden in ["never-fetch", "giftDetails", "jewelsAmount", "comboCount", "NOT PUBLIC DISPLAY TEXT", "giftDuration"] {
            try check(!wire.contains(forbidden), "Gift metadata/media entered public typed message")
        }
        let refused = try StudioDirectChatDecoder.youtube(page([item("unknown", type: "futureGiftEvent"),
            item("hidden", display: false), item("wrong-chat", chat: "other-chat"), item("huge", text: String(repeating: "x", count: 16_385)),
            item("empty", text: "")]), channelID: "owner", chatID: "owned-chat")
        try check(refused.deliveries.isEmpty, "Unsupported/undisplayable/unbound/oversized gift accepted")
        print("PASS decoder: documented giftEvent, exact public Unicode/display identity;5 invalid cases; gift media/amount/combo metadata excluded")
        let http = GiftHTTP(), gate = GiftPoll(), stream = GiftStream()
        let manager = StudioDirectChatManager(request: http.send, identity: { _ in
            .init(channelID: "owner", scopes: ["https://www.googleapis.com/auth/youtube.force-ssl"])
        }, socketFactory: { _ in preconditionFailure("YouTube fixture opened a Twitch socket") },
            sleep: { try await gate.sleep($0) }, emit: stream.receive)
        defer { manager.shutdown() }
        manager.connect(.youtube, eventID: "owned-broadcast")
        try await until("initial page") {
            let waiting = await gate.waiting
            return stream.queue.messages.count == 3 && manager.snapshot(.youtube).isConnected && waiting
        }
        try check(stream.queue.messages.map(\.kind) == ["Text", "Gift", "Gift"], "Gift dropped neighboring ordinary/membership events")
        let target = manager.writeTarget(.youtube)!
        try check(target.channelID == "owner" && target.chatID == "owned-chat" && target.broadcastID == "owned-broadcast", "Gift changed owned reader target")
        let giftID = StudioDirectChatDecoder.identity(.youtube, "owned-chat", "gift")
        print("CHECK giftEvent deliberate mutation refusal")
        try check(manager.targetForMessage(giftID) == nil && !manager.canDelete(giftID), "giftEvent exposed a mutation target")
        try check(manager.canDelete(StudioDirectChatDecoder.identity(.youtube, "owned-chat", "ordinary"))
            && manager.canDelete(StudioDirectChatDecoder.identity(.youtube, "owned-chat", "membership")),
                  "New gift policy disabled existing ordinary/membership actions")
        for kind in [DirectChatWriteKind.delete, .timeout, .ban] {
            try check(manager.moderationAvailabilityError(giftID, kind: kind) != nil, "Gift exposed moderation eligibility")
            _ = manager.moderate(giftID, kind: kind)
        }
        _ = manager.send("Never deliver to giftEvent", provider: .youtube, replyingTo: giftID)
        try check(manager.receipts.count == 4 && manager.receipts.allSatisfy {
            if case .notSent = $0.state { return true }; return false
        }, "Gift mutation attempt was not refused before request")
        await gate.resume()
        try await until("second page") {
            let waiting = await gate.waiting
            return stream.queue.messages.count == 4 && waiting
        }
        try check(stream.queue.message(giftID)?.text == "Gift public caption 👩🏽‍🚀 世界 {host}"
            && stream.queue.filtered(search: "", audienceEvent: .gift).count == 3, "Same provider ID changed first public event or lost Gift filter")
        try check(StudioAudienceEventKind.gift.supportsAlert && StudioAudienceEventKind.gift.defaultStyle == .violet
            && manager.receipts.count == 4 && http.tokens == [nil, "next-owned-page"], "Gift altered styling, write history or read cursor")
        let intervals = await gate.intervals; try check(intervals == [2.5, 2.5], "Gift changed provider polling interval")
        await gate.resume(); try await until("held page") { http.held != nil }
        let before = stream.actions
        manager.stop(.youtube); http.held?.resume(returning: page([item("late")])); http.held = nil
        try await Task.sleep(for: .milliseconds(30))
        try check(!manager.snapshot(.youtube).isConnected && stream.queue.messages.count == 4 && stream.actions == before + 1,
                  "Late retired gift page rearmed reader or lost existing messages")
        print("PASS manager: real owned lookup/page cursor/interval, mixed events, first-ID gift dedup/filter/style,4 explicit mutation refusals,existing user actions preserved,late retired page refusal")
    }
    static func main() async {
        do { try await run(); print("PASS controlled YouTube giftEvent fixture") }
        catch { print("FAIL YouTube giftEvent fixture: \(error)"); exit(1) }
    }
}
