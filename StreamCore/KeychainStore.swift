import Foundation
import Security

/// Stores the sensitive connection secrets (RTMP/RTMPS URL + stream key) in the
/// Keychain instead of `UserDefaults`, so they survive relaunches without the user
/// re-typing them and are never persisted in plaintext.
///
/// Items are written as generic passwords. No explicit `kSecAttrAccessGroup` is
/// passed: the access group defaults to the FIRST entry of each target's
/// `keychain-access-groups` entitlement — which is the shared
/// `$(AppIdentifierPrefix)com.joeblau.Stream` group on both the app and the
/// broadcast extension — so both processes read/write the same items. On the
/// Simulator (no entitlements) it falls back to the default test group, which
/// still round-trips within the app.
///
/// `kSecAttrAccessibleAfterFirstUnlock` lets the broadcast extension read the
/// secrets while running in the background after the device has been unlocked once.
public struct KeychainStore: Sendable {

    /// The secrets this store manages.
    public enum Item: String, Sendable {
        case rtmpURL = "stream.connection.url"
        case streamKey = "stream.connection.key"
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
            kSecAttrAccount as String: item.rawValue
        ]
    }
}
