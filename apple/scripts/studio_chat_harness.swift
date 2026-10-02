import Foundation

@main struct StudioChatHarness {
    static func event(_ id: String?, connection: String = "youtube/channel", text: String = "Hello 👩🏽‍🚀 世界", whisper: Bool = false, type: Int = 5) throws -> Data {
        var body: [String: Any] = ["text": text, "author": ["displayName": "Creator", "isChatModerator": true], "contentModifiers": ["whisper": whisper]]
        if let id { body["liveChatMessageId"] = id }
        return try JSONSerialization.data(withJSONObject: ["action": "event", "timestamp": 1_800_000_000,
            "payload": ["connectionIdentifier": connection, "eventIdentifier": "not-unique", "eventTypeId": type, "eventPayload": body]])
    }
    static func message(_ data: Data) -> StudioChatMessage {
        guard case .message(let result) = StudioRestreamDecoder.decode(data) else { fatalError("Expected public message") }
        return result
    }
    static func main() throws {
        let first = message(try event("1"))
        precondition(first.roles == ["Moderator"] && first.platform == "YouTube" && first.text.contains("世界"))
        precondition(!first.timestampIsReceiptTime)
        let privateEvent = try event("private", whisper: true)
        precondition(StudioRestreamDecoder.decode(privateEvent) == nil)
        let unknownEvent = try event("unknown", type: 999)
        precondition(StudioRestreamDecoder.decode(unknownEvent) == nil)
        let oversizedEvent = try event("huge", text: String(repeating: "a", count: 16_385))
        precondition(StudioRestreamDecoder.decode(oversizedEvent) == nil)
        precondition(StudioRestreamDecoder.decode(Data(repeating: 32, count: 262_145)) == nil)
        var queue = StudioChatQueue()
        queue.receive(first); queue.receive(message(try event("1")))
        precondition(queue.messages.count == 1)
        queue.receive(message(try event("1", connection: "another/channel")))
        precondition(queue.messages.count == 2)
        let second = message(try event("2", text: "Next"))
        queue.receive(second); queue.favorite(first.id); queue.enqueue(first.id); queue.enqueue(second.id)
        queue.show(first.id)
        precondition(queue.current?.id == first.id && queue.next?.id == second.id)
        queue.advance(1)
        precondition(queue.current?.id == second.id && queue.next == nil && queue.featured?.id == first.id)
        queue.hide(); precondition(queue.featured == nil && queue.message(first.id) != nil)
        for index in 3..<5_010 { queue.receive(message(try event(String(index), text: "A message"))) }
        precondition(queue.messages.count == 1_000 && queue.current?.id == second.id && queue.message(first.id) != nil)
        queue.receive(first); precondition(queue.messages.count == 1_000)
        precondition(queue.filtered(search: "世界", favoritesOnly: true).count == 1)
        precondition(queue.filtered(search: "", platform: "Twitch").isEmpty)
        // Identical text without a real provider ID remains two distinct
        // deliveries; eventIdentifier must never collapse legitimate messages.
        let unidentified = try event(nil)
        let a = message(unidentified), b = message(unidentified)
        precondition(a.id != b.id)
        queue.receive(a); queue.receive(b)
        precondition(queue.message(a.id) != nil && queue.message(b.id) != nil)
        print("PASS: documented Restream public events, provider identity/scope deduplication, private/unknown/oversize rejection, Unicode, bounded queue/favorites, selection under message churn and reconnect replay, independent featured state")
    }
}
