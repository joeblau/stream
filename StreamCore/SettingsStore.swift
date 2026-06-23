import Foundation

/// Value-semantics helper that round-trips StreamSettings as JSON into the
/// shared App Group UserDefaults suite. Safe to use from both the app and the
/// broadcast extension (separate processes, same suite).
///
/// `@unchecked Sendable`: the only stored property is a `UserDefaults`, which is
/// documented thread-safe; Swift can't prove that, so we vouch for it.
public struct SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let keychain: KeychainStore

    /// Uses the shared App Group suite. Falls back to .standard only if the
    /// suite cannot be created (misconfigured entitlement) so calls never crash.
    public init(defaults: UserDefaults? = UserDefaults(suiteName: AppGroup.identifier),
                keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults ?? .standard
        self.keychain = keychain
    }

    /// Loads the non-sensitive settings from the App Group suite and overlays the
    /// connection URL + stream key from the Keychain. A legacy build that stored
    /// the secrets inside the UserDefaults blob still works: those values survive
    /// in the decoded struct and are promoted to the Keychain on the next `save`.
    public func load() -> StreamSettings {
        var settings = StreamSettings.default
        if let data = defaults.data(forKey: AppGroup.settingsKey),
           let decoded = try? JSONDecoder().decode(StreamSettings.self, from: data) {
            settings = decoded
        }
        if let url = keychain.string(for: .rtmpURL) { settings.rtmpURL = url }
        if let key = keychain.string(for: .streamKey) { settings.streamKey = key }
        return settings
    }

    /// Writes the connection URL + stream key to the Keychain (shared with the
    /// broadcast extension) and the remaining settings to the App Group suite with
    /// the secrets blanked, so they are never persisted in plaintext.
    public func save(_ settings: StreamSettings) {
        keychain.set(settings.rtmpURL, for: .rtmpURL)
        keychain.set(settings.streamKey, for: .streamKey)

        var redacted = settings
        redacted.rtmpURL = ""
        redacted.streamKey = ""
        guard let data = try? JSONEncoder().encode(redacted) else { return }
        defaults.set(data, forKey: AppGroup.settingsKey)
    }
}
