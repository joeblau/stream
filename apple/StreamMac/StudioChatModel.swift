import Foundation
import CryptoKit

enum StudioChatMessageIdentity {
    static func make(provider: String, messageID: String) -> String {
        let data = try! JSONEncoder().encode([provider.lowercased(), messageID])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
/// Public provider message IDs are independent of adapter/socket identity.
struct StudioChatMessage: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let connectionID: String
    let platform: String
    let author: String
    let roles: [String]
    let text: String
    let timestamp: Date
    let timestampIsReceiptTime: Bool
    let kind: String
    let avatarURL: URL?
}

enum StudioChatAction: Sendable {
    case message(StudioChatMessage)
    case connection(id: String, uuid: String, platform: String, state: String)
    case closed(uuid: String)
    case heartbeat
    case removed(ids: [String])
}

/// Documented public Restream events only. Unknown events and private whispers
/// are excluded. Raw envelopes, tokens and private messages never enter logs.
enum StudioRestreamDecoder {
    static func decode(_ data: Data, receivedAt: Date = Date()) -> StudioChatAction? {
        guard data.count <= 262_144,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = object["action"] as? String else { return nil }
        if action == "heartbeat" { return .heartbeat }
        guard let payload = object["payload"] as? [String: Any] else { return nil }
        if action == "connection_closed", let uuid = bounded(payload["connectionUuid"], limit: 256) {
            return .closed(uuid: uuid)
        }
        if action == "connection_info",
           let id = bounded(payload["connectionIdentifier"], limit: 256),
           let uuid = bounded(payload["connectionUuid"], limit: 256),
           let state = payload["status"] as? String,
           ["connecting", "connected", "error"].contains(state) {
            return .connection(id: id, uuid: uuid, platform: platform(payload["eventSourceId"] as? Int), state: state)
        }
        guard action == "event", let event = payload["eventPayload"] as? [String: Any],
              let connection = bounded(payload["connectionIdentifier"], limit: 256),
              let type = payload["eventTypeId"] as? Int,
              let name = eventNames[type],
              let text = bounded(event["text"], limit: 16_384), !text.isEmpty,
              (event["contentModifiers"] as? [String: Any])?["whisper"] as? Bool != true else { return nil }
        let author = event["author"] as? [String: Any] ?? [:]
        let displayName = bounded(author["displayName"], limit: 512)
            ?? bounded(author["name"], limit: 512) ?? bounded(author["username"], limit: 512) ?? "Unknown author"
        // Restream eventIdentifier is explicitly not unique. When the provider
        // has no message identity, retain distinct deliveries instead of
        // conflating repeated messages by hashing their content.
        let providerID = bounded(event["liveChatMessageId"], limit: 512)
            ?? bounded(event["twitchMessageId"], limit: 512)
        let identity: String
        if let providerID {
            identity = StudioChatMessageIdentity.make(provider: name.0, messageID: providerID)
        } else { identity = UUID().uuidString }
        let seconds = object["timestamp"] as? Double
        let validTime = seconds.flatMap { $0.isFinite && $0 > 0 && $0 < 253_402_300_800 ? Date(timeIntervalSince1970: $0) : nil }
        var roles: [String] = []
        for (key, label) in [("isChatOwner", "Owner"), ("isChatModerator", "Moderator"), ("isChatSponsor", "Member"), ("isVerified", "Verified")] {
            if author[key] as? Bool == true { roles.append(label) }
        }
        if event["bot"] as? Bool == true { roles.append("Bot") }
        let avatar = bounded(author["avatar"] ?? author["picture"] ?? author["avatarUrl"], limit: 2048)
            .flatMap(URL.init(string:)).flatMap { $0.scheme == "https" && $0.user == nil && $0.password == nil ? $0 : nil }
        return .message(.init(id: identity, connectionID: connection, platform: name.0, author: displayName,
            roles: roles, text: text, timestamp: validTime ?? receivedAt, timestampIsReceiptTime: validTime == nil,
            kind: name.1, avatarURL: avatar))
    }

    private static func bounded(_ value: Any?, limit: Int) -> String? {
        guard let text = value as? String, text.utf8.count <= limit else { return nil }
        return text
    }
    private static let eventNames: [Int: (String, String)] = [
        1: ("Discord", "Text"), 2: ("DLive", "Text"), 4: ("Twitch", "Text"),
        5: ("YouTube", "Text"), 7: ("YouTube", "Super Chat"), 8: ("YouTube", "Super Sticker"),
        11: ("Facebook", "Text"), 13: ("Facebook", "Text"), 21: ("LinkedIn", "Text"),
        22: ("Trovo", "Text"), 23: ("YouTube", "Milestone"), 24: ("X", "Text"),
        25: ("Kick", "Text"), 28: ("YouTube", "Membership"), 29: ("YouTube", "Gift"), 32: ("Rumble", "Text")
    ]
    private static func platform(_ id: Int?) -> String { "Restream source \(id.map(String.init) ?? "unknown")" }
}

struct StudioChatQueue: Sendable {
    private(set) var messages: [StudioChatMessage] = []
    private(set) var favorites: Set<String> = []
    private(set) var queue: [String] = []
    private(set) var selectedID: String?
    private(set) var featuredID: String?
    private(set) var readingID: String?
    mutating func retainReadingPosition(_ id: String?) { readingID = id.flatMap { message($0)?.id } }
    private var seen: Set<String> = []
    private var seenOrder: [String] = []
    var current: StudioChatMessage? { selectedID.flatMap(message) }
    var featured: StudioChatMessage? { featuredID.flatMap(message) }
    var next: StudioChatMessage? {
        guard let selectedID else { return queue.first.flatMap(message) }
        guard let index = queue.firstIndex(of: selectedID), index + 1 < queue.count else { return nil }
        return message(queue[index + 1])
    }
    func message(_ id: String) -> StudioChatMessage? { messages.first { $0.id == id } }
    mutating func receive(_ message: StudioChatMessage) {
        guard self.message(message.id) == nil, seen.insert(message.id).inserted else { return }
        seenOrder.append(message.id)
        if seenOrder.count > 4_000 { seen.remove(seenOrder.removeFirst()) }
        messages.append(message)
        while messages.count > 1_000 {
            if let index = messages.firstIndex(where: { !favorites.contains($0.id) && !queue.contains($0.id) && $0.id != featuredID && $0.id != readingID }) {
                messages.remove(at: index)
            } else { break }
        }
    }
    mutating func favorite(_ id: String) {
        guard message(id) != nil else { return }
        if favorites.contains(id) { favorites.remove(id) }
        else if favorites.count < 200 { favorites.insert(id) }
    }
    mutating func enqueue(_ id: String) {
        guard queue.count < 100, message(id) != nil, !queue.contains(id) else { return }
        queue.append(id)
        if selectedID == nil { selectedID = id }
    }
    mutating func remove(_ id: String) {
        queue.removeAll { $0 == id }
        if selectedID == id { selectedID = queue.first }
    }
    mutating func select(_ id: String) { if queue.contains(id) { selectedID = id } }
    mutating func advance(_ direction: Int) {
        guard !queue.isEmpty else { selectedID = nil; return }
        let index = selectedID.flatMap { queue.firstIndex(of: $0) } ?? 0
        selectedID = queue[max(0, min(queue.count - 1, index + direction))]
    }
    mutating func show(_ id: String) { if message(id) != nil { featuredID = id } }
    mutating func hide() { featuredID = nil }
    /// Keep tombstones in the bounded identity cache, so reconnect replay cannot
    /// resurrect a moderated message. Queue/favorites never retain removed text.
    mutating func discard(_ ids: [String]) {
        let removed = Set(ids.prefix(4_000))
        messages.removeAll { removed.contains($0.id) }
        favorites.subtract(removed); queue.removeAll { removed.contains($0) }
        if let id = selectedID, removed.contains(id) { selectedID = queue.first }
        if let id = featuredID, removed.contains(id) { featuredID = nil }
        if let id = readingID, removed.contains(id) { readingID = nil }
        for id in removed where seen.insert(id).inserted { seenOrder.append(id) }
        while seenOrder.count > 4_000 { seen.remove(seenOrder.removeFirst()) }
    }
    func filtered(search: String, platform: String? = nil, connectionID: String? = nil, author: String? = nil, kind: String? = nil, favoritesOnly: Bool = false) -> [StudioChatMessage] {
        messages.filter {
            (!favoritesOnly || favorites.contains($0.id)) && (platform == nil || $0.platform == platform)
                && (connectionID == nil || $0.connectionID == connectionID) && (author == nil || $0.author == author) && (kind == nil || $0.kind == kind)
                && (search.isEmpty || "\($0.author) \($0.text)".localizedCaseInsensitiveContains(search))
        }
    }
}
