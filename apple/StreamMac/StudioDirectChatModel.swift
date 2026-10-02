import CryptoKit
import Foundation
import StreamCore

struct DirectChatRoute: Sendable {
    let provider: ManagedProvider
    let channelID: String
    let chatID: String
    let providerMessageID: String
    let authorID: String
    let roles: [String]
    let timestamp: Date
}
struct DirectChatDelivery: Sendable {
    let message: StudioChatMessage
    let route: DirectChatRoute
}
struct YouTubeChatPage: Sendable {
    let deliveries: [DirectChatDelivery]
    let removedIDs: [String]
    let bannedAuthors: [String]
    let nextPage: String
    let interval: Double
    let ended: Bool
}
struct TwitchChatEnvelope: Sendable {
    let type: String
    let sessionID: String?
    let timeout: Double?
    let reconnectURL: URL?
    let delivery: DirectChatDelivery?
    let removedID: String?
    let clearedAuthor: String?
    let clearAll: Bool
}

/// Only documented public events enter the common message stream. Raw provider
/// objects never reach logs, project persistence or overlay commands.
enum StudioDirectChatDecoder {
    static func connection(_ provider: ManagedProvider, _ target: String) -> String { "direct:\(provider.rawValue):\(target)" }
    static func identity(_ provider: ManagedProvider, _ target: String, _ messageID: String) -> String {
        StudioChatMessageIdentity.make(provider: provider.rawValue, messageID: messageID)
    }
    static func text(_ value: Any?, limit: Int = 16_384) -> String? {
        guard let value = value as? String, value.utf8.count <= limit else { return nil }; return value
    }
    static func identifier(_ value: Any?) -> String? {
        guard let value = text(value, limit: 1_024), !value.isEmpty,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }
    static func date(_ value: Any?) -> Date? {
        guard let value = text(value, limit: 64) else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: value)
    }
    static func object(_ data: Data, limit: Int = 262_144) throws -> [String: Any] {
        guard data.count <= limit, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderFailure(.invalidResponse)
        }; return object
    }
    static func youtube(_ data: Data, channelID: String, chatID: String, receivedAt: Date = Date()) throws -> YouTubeChatPage {
        let object = try object(data, limit: 2_097_152)
        guard let items = object["items"] as? [[String: Any]], items.count <= 2_000,
              let page = text(object["nextPageToken"], limit: 4_096),
              let millis = object["pollingIntervalMillis"] as? Double,
              millis.isFinite, millis > 0, millis <= 3_600_000 else { throw ProviderFailure(.invalidResponse) }
        var deliveries: [DirectChatDelivery] = [], removed: [String] = [], banned: [String] = []
        var ended = object["offlineAt"] != nil
        for item in items {
            guard let id = identifier(item["id"]), let snippet = item["snippet"] as? [String: Any],
                  snippet["liveChatId"] as? String == chatID, let type = snippet["type"] as? String else { continue }
            if type == "tombstone" { removed.append(identity(.youtube, chatID, id)); continue }
            if type == "chatEndedEvent" { ended = true; continue }
            if type == "userBannedEvent", let detail = snippet["userBannedDetails"] as? [String: Any],
               let user = detail["bannedUserDetails"] as? [String: Any], let author = identifier(user["channelId"]) { banned.append(author); continue }
            let names = ["textMessageEvent": "Text", "superChatEvent": "Super Chat", "superStickerEvent": "Super Sticker",
                         "newSponsorEvent": "Membership", "memberMilestoneChatEvent": "Milestone", "membershipGiftingEvent": "Gift",
                         "giftMembershipReceivedEvent": "Gift"]
            guard let kind = names[type], snippet["hasDisplayContent"] as? Bool == true,
                  let content = text(snippet["displayMessage"]), !content.isEmpty,
                  let author = item["authorDetails"] as? [String: Any], let authorID = identifier(author["channelId"]),
                  let name = text(author["displayName"], limit: 512), !name.isEmpty else { continue }
            var roles: [String] = []
            for (key, role) in [("isChatOwner", "Owner"), ("isChatModerator", "Moderator"), ("isChatSponsor", "Member"), ("isVerified", "Verified")] {
                if author[key] as? Bool == true { roles.append(role) }
            }
            let time = date(snippet["publishedAt"])
            let avatar = text(author["profileImageUrl"], limit: 2_048).flatMap(URL.init(string:)).flatMap {
                $0.scheme == "https" && $0.user == nil && $0.password == nil ? $0 : nil
            }
            let message = StudioChatMessage(id: identity(.youtube, chatID, id), connectionID: connection(.youtube, chatID),
                platform: "YouTube", author: name, roles: roles, text: content, timestamp: time ?? receivedAt,
                timestampIsReceiptTime: time == nil, kind: kind, avatarURL: avatar)
            deliveries.append(.init(message: message, route: .init(provider: .youtube, channelID: channelID, chatID: chatID,
                providerMessageID: id, authorID: authorID, roles: roles, timestamp: time ?? receivedAt)))
        }
        return .init(deliveries: deliveries, removedIDs: removed, bannedAuthors: banned, nextPage: page,
                     interval: millis / 1_000, ended: ended)
    }
    static func twitch(_ data: Data, channelID: String, userID: String, receivedAt: Date = Date()) throws -> TwitchChatEnvelope {
        let object = try object(data)
        guard let metadata = object["metadata"] as? [String: Any], let type = metadata["message_type"] as? String,
              let payload = object["payload"] as? [String: Any] else { throw ProviderFailure(.invalidResponse) }
        func envelope(session: String? = nil, timeout: Double? = nil, reconnect: URL? = nil,
                      delivery: DirectChatDelivery? = nil, removed: String? = nil, author: String? = nil, clear: Bool = false) -> TwitchChatEnvelope {
            .init(type: type, sessionID: session, timeout: timeout, reconnectURL: reconnect, delivery: delivery,
                  removedID: removed, clearedAuthor: author, clearAll: clear)
        }
        if type == "session_welcome" {
            guard let session = payload["session"] as? [String: Any], let id = identifier(session["id"]),
                  let seconds = session["keepalive_timeout_seconds"] as? Double, seconds.isFinite, (10...600).contains(seconds) else {
                throw ProviderFailure(.invalidResponse)
            }; return envelope(session: id, timeout: seconds)
        }
        if type == "session_reconnect" {
            guard let session = payload["session"] as? [String: Any], let raw = text(session["reconnect_url"], limit: 4_096),
                  let url = URL(string: raw), url.scheme == "wss", url.host == "eventsub.wss.twitch.tv",
                  url.user == nil, url.password == nil, url.port == nil else { throw ProviderFailure(.invalidResponse) }
            return envelope(reconnect: url)
        }
        if type == "session_keepalive" { return envelope() }
        guard ["notification", "revocation"].contains(type), let subscription = payload["subscription"] as? [String: Any],
              let subscriptionType = subscription["type"] as? String, subscription["version"] as? String == "1",
              let condition = subscription["condition"] as? [String: Any], condition["broadcaster_user_id"] as? String == channelID,
              condition["user_id"] as? String == userID,
              ["channel.chat.message", "channel.chat.message_delete", "channel.chat.clear", "channel.chat.clear_user_messages"].contains(subscriptionType) else {
            throw ProviderFailure(.invalidResponse)
        }
        if type == "revocation" { throw ProviderFailure(.permission) }
        guard let event = payload["event"] as? [String: Any], event["broadcaster_user_id"] as? String == channelID else {
            throw ProviderFailure(.invalidResponse)
        }
        if subscriptionType == "channel.chat.clear" { return envelope(clear: true) }
        if subscriptionType == "channel.chat.clear_user_messages", let user = identifier(event["target_user_id"]) { return envelope(author: user) }
        if subscriptionType == "channel.chat.message_delete", let id = identifier(event["message_id"]) { return envelope(removed: identity(.twitch, channelID, id)) }
        guard subscriptionType == "channel.chat.message", let id = identifier(event["message_id"]),
              let authorID = identifier(event["chatter_user_id"]), let name = text(event["chatter_user_name"], limit: 512),
              let message = event["message"] as? [String: Any], let content = text(message["text"]), !content.isEmpty else {
            throw ProviderFailure(.invalidResponse)
        }
        let badges = event["badges"] as? [[String: Any]] ?? []
        let labels = ["broadcaster": "Owner", "moderator": "Moderator", "subscriber": "Member", "vip": "VIP"]
        let roles = badges.prefix(64).compactMap { ($0["set_id"] as? String).flatMap { labels[$0] } }
        let time = date(metadata["message_timestamp"])
        // Fragment IDs are provider metadata. Render the documented text only;
        // no guessed CDN URL or untrusted HTML enters the native overlay.
        let hasEmote = (message["fragments"] as? [[String: Any]])?.prefix(1_000).contains { fragment in
            fragment["type"] as? String == "emote" && (fragment["emote"] as? [String: Any]).flatMap { identifier($0["id"]) } != nil
        } ?? false
        let normalized = StudioChatMessage(id: identity(.twitch, channelID, id), connectionID: connection(.twitch, channelID),
            platform: "Twitch", author: name, roles: roles, text: content, timestamp: time ?? receivedAt,
            timestampIsReceiptTime: time == nil, kind: hasEmote ? "Emotes" : "Text", avatarURL: nil)
        return envelope(delivery: .init(message: normalized, route: .init(provider: .twitch, channelID: channelID,
            chatID: channelID, providerMessageID: id, authorID: authorID, roles: roles, timestamp: time ?? receivedAt)))
    }
}
