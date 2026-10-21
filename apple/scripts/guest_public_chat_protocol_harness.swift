import Foundation

@main private enum PublicChatProtocolHarness {
    static func decoded(_ envelope: GuestPublicChatEnvelope, negotiation: UUID) throws -> [String: Any] {
        let wire = envelope.wire(negotiation: negotiation)!
        precondition(wire.utf8.count <= 1024)
        return try JSONSerialization.jsonObject(with: Data(wire.utf8)) as! [String: Any]
    }
    static func main() throws {
        let negotiation = UUID(), feed = UUID()
        let body = String(repeating: "👩🏽‍🚀 العربية café e\u{301} {host}\n", count: 100)
        let prefix = GuestPublicChatEnvelope.prefix(body, bytes: 512)
        precondition(prefix.utf8.count <= 512 && body.hasPrefix(prefix))
        let entry = GuestPublicChatEntry(id: String(repeating: "a", count: 64), source: "abcdef123456", platform: "YouTube",
            author: String(repeating: "\\", count: 64), roles: ["Owner", "Moderator", "Member", "Verified", "VIP", "Bot"],
            text: String(repeating: "\\", count: 512), timestamp: 1_800_000_000, receiptTime: false, kind: "Super Chat", truncated: false)
        let wire = GuestPublicChatEnvelope.message(feed: feed, reset: 1, sequence: .max, dropped: 6, entry: entry)
        let object = try decoded(wire, negotiation: negotiation)
        precondition(object["negotiation"] as? String == negotiation.uuidString.lowercased()
            && object["feed"] as? String == feed.uuidString.lowercased() && object["truncated"] as? Bool == true)
        precondition(entry.text.hasPrefix(object["text"] as! String))
        precondition(GuestPrivateControlEnvelope.parse(wire.wire(negotiation: negotiation)!, negotiation: negotiation) == nil)
        let state = GuestPublicChatEnvelope.state(feed: feed, enabled: true, reset: 1, sequence: 1, dropped: 2,
            adapters: ["youtube": "connected", "twitch": "unavailable"], sources: (0..<4).map { index in
                .init(id: "abcdef12345\(index)", platform: String(repeating: "\\", count: 32), state: String(repeating: "\0", count: 64))
            }, sourcesTruncated: false)
        let status = try decoded(state, negotiation: negotiation)
        precondition(status["sourcesTruncated"] as? Bool == true && (status["sources"] as! [[String: String]]).count < 4)
        let unsupported = GuestPublicChatEnvelope.state(feed: feed, enabled: true, reset: 0, sequence: 0, dropped: 0,
            adapters: ["guessed-provider": "connected"], sources: [], sourcesTruncated: false)
        precondition(unsupported.wire(negotiation: negotiation) == nil)
        let oversized = GuestPublicChatEntry(id: "id", source: "abcdef123456", platform: "YouTube", author: "Viewer", roles: [],
            text: String(repeating: "x", count: 513), timestamp: 1_800_000_000, receiptTime: false, kind: "Text", truncated: false)
        precondition(GuestPublicChatEnvelope.message(feed: feed, reset: 0, sequence: 1, dropped: 0, entry: oversized).wire(negotiation: negotiation) == nil)
        print("PASS: actual one-way public chat protocol; composed Unicode prefixes, adaptive escaped-text clipping within1KiB, exact negotiation/feed/sequence, bounded status omission and unsupported adapter rejection; private parser stays separate")
    }
}
