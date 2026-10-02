import Foundation
import Security

/// Stores the sensitive connection secrets (RTMP/RTMPS URL + stream key) in the
/// Keychain instead of `UserDefaults`, so they survive relaunches without the user
/// re-typing them and are never persisted in plaintext.
///
/// Items are written as generic passwords. No explicit `kSecAttrAccessGroup` is
/// passed: the access group defaults to the FIRST entry of each target's
/// `keychain-access-groups` entitlement, preserving access to credentials stored
/// by earlier versions. On the Simulator it falls back to the default test group.
///
/// `kSecAttrAccessibleAfterFirstUnlock` keeps secrets available during a
/// background capture after the device has been unlocked once.
public enum DestinationCredentialField: String, CaseIterable, Sendable {
    case endpoint, streamKey, srtStreamID, srtPassphrase
}

public struct KeychainStore: Sendable {

    /// The secrets this store manages, keyed per transport protocol so each of
    /// RTMP/RTMPS/SRT/WHIP keeps its own URL + key.
    public enum Item: Sendable {
        case url(StreamProtocol)
        case key(StreamProtocol)
        /// Pre-multiprotocol single slots, kept only for one-time migration.
        case destination(UUID, field: DestinationCredentialField)
        case legacyURL
        case legacyKey

        var account: String {
            switch self {
            case .url(let proto): return "stream.connection.\(proto.rawValue).url"
            case .key(let proto): return "stream.connection.\(proto.rawValue).key"
            case .destination(let id, let field): return "stream.destination.\(id.uuidString.lowercased()).\(field.rawValue)"
            case .legacyURL: return "stream.connection.url"
            case .legacyKey: return "stream.connection.key"
            }
        }
    }

    private let service: String

    public init(service: String = AppGroup.keychainService) {
        self.service = service
    }

    /// Saves (or, for an empty value, removes) a secret.
    @discardableResult
    public func set(_ value: String, for item: Item) -> Bool {
        let base = baseQuery(for: item)
        SecItemDelete(base as CFDictionary)

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return true   // empty => treated as "cleared"
        }

        var attributes = base
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// Reads a secret, or nil if it has never been saved.
    public func string(for item: Item) -> String? {
        var query = baseQuery(for: item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// Removes a secret.
    public func remove(_ item: Item) {
        SecItemDelete(baseQuery(for: item) as CFDictionary)
    }

    private func baseQuery(for item: Item) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.account
        ]
    }
}
