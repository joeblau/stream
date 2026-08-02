import Foundation

/// Value-semantics helper that persists `StreamSettings` in the app's container.
///
/// Non-secret settings are stored as a JSON file inside the shared App Group
/// **container**, NOT the App Group `UserDefaults` **suite**. Reading a
/// shared-container preferences domain makes `cfprefsd` log a noisy
/// "Using kCFPreferencesAnyUser with a container is only allowed for System
/// Containers, detaching from cfprefsd" warning whenever the domain is set up.
/// A plain file in the container bypasses `cfprefsd` entirely, so that warning
/// never fires. The sensitive URL + stream key continue to live in the Keychain.
///
/// `Sendable`: the only stored property is a `Sendable` `KeychainStore`; all file
/// access goes through the thread-safe `FileManager.default`.
public struct SettingsStore: Sendable {
    private let keychain: KeychainStore

    public init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    /// Loads the non-sensitive settings from the container file and overlays the
    /// connection URL + stream key from the Keychain.
    ///
    /// On the first run after upgrading from the previous UserDefaults-backed
    /// store, the old non-secret blob is migrated forward ONCE and written to the
    /// file; the suite is never read again afterwards, so the `cfprefsd` warning
    /// stops recurring.
    public func load() -> StreamSettings {
        var settings = StreamSettings.default

        if let url = settingsFileURL(),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(StreamSettings.self, from: data) {
            settings = decoded
        } else {
            // No file yet: migrate from the legacy suite (once), then persist so
            // the suite is never touched again.
            settings = migrateLegacySettings() ?? .default
            persistNonSecret(settings)
        }

        // One-time migration of the old single connection secret into its
        // per-protocol slot; on that first upgrade it also selects the protocol the
        // existing URL belongs to, so the user's saved values stay visible.
        if let migratedProtocol = migrateConnectionSecretsIfNeeded() {
            settings.selectedProtocol = migratedProtocol
        }

        settings.rtmpURL = keychain.string(for: .url(settings.selectedProtocol)) ?? ""
        settings.streamKey = keychain.string(for: .key(settings.selectedProtocol)) ?? ""
        // A local video backup requires a second real-time encoder. Keep the
        // persisted field for compatibility, but do not let stale opt-ins trade
        // streaming stability for a feature that is currently unavailable.
        settings.backupEnabled = false
        return settings
    }

    /// Writes the connection URL + stream key to the Keychain and the remaining
    /// settings to the container file with the secrets blanked, so they are never
    /// persisted in plaintext.
    public func save(_ settings: StreamSettings) {
        saveConnection(settings)
        saveNonSecret(settings)
    }

    /// Writes only the selected protocol's sensitive fields. UI persistence can
    /// skip this Security.framework round-trip for video/audio/PiP-only edits.
    public func saveConnection(_ settings: StreamSettings) {
        keychain.set(settings.rtmpURL, for: .url(settings.selectedProtocol))
        keychain.set(settings.streamKey, for: .key(settings.selectedProtocol))
    }

    /// Writes only the redacted JSON settings snapshot.
    public func saveNonSecret(_ settings: StreamSettings) {
        persistNonSecret(settings)
    }

    /// Saves the currently-shown protocol's credentials, switches, then loads the
    /// target protocol's stored credentials into the active fields (each protocol
    /// keeps its own Keychain slot). Persists the new selection.
    public func switchProtocol(to newProtocol: StreamProtocol, in settings: inout StreamSettings) {
        keychain.set(settings.rtmpURL, for: .url(settings.selectedProtocol))
        keychain.set(settings.streamKey, for: .key(settings.selectedProtocol))
        settings.selectedProtocol = newProtocol
        if !newProtocol.supports(settings.videoCodec) {
            settings.videoCodec = .h264
        }
        settings.rtmpURL = keychain.string(for: .url(newProtocol)) ?? ""
        settings.streamKey = keychain.string(for: .key(newProtocol)) ?? ""
        persistNonSecret(settings)
    }

    /// Moves the pre-multiprotocol single connection secret into its protocol's
    /// slot exactly once and returns that protocol (so the caller can select it on
    /// first upgrade). Returns nil when there is nothing to migrate.
    private func migrateConnectionSecretsIfNeeded() -> StreamProtocol? {
        guard let legacyURL = keychain.string(for: .legacyURL), !legacyURL.isEmpty else {
            return nil
        }
        let legacyKey = keychain.string(for: .legacyKey) ?? ""
        let proto: StreamProtocol =
            URL(string: legacyURL)?.scheme?.lowercased() == "rtmp" ? .rtmp : .rtmps
        // Never clobber a per-protocol slot that already has a value.
        if keychain.string(for: .url(proto)) == nil {
            keychain.set(legacyURL, for: .url(proto))
            keychain.set(legacyKey, for: .key(proto))
        }
        keychain.remove(.legacyURL)
        keychain.remove(.legacyKey)
        return proto
    }

    // MARK: - File storage

    /// `<App Group container>/stream.settings.v1.json`.
    private func settingsFileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
            .appendingPathComponent("\(AppGroup.settingsKey).json")
    }

    /// Atomically writes the settings to the container file with the secrets
    /// redacted (those live only in the Keychain).
    private func persistNonSecret(_ settings: StreamSettings) {
        guard let url = settingsFileURL() else { return }
        var redacted = settings
        redacted.rtmpURL = ""
        redacted.streamKey = ""
        guard let data = try? JSONEncoder().encode(redacted) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - One-time legacy migration

    /// Reads the legacy App Group `UserDefaults` blob exactly once — only when the
    /// container file is absent — and clears the old key. Returns nil on a fresh
    /// install or when there is nothing to migrate. This is the only place the
    /// suite is ever instantiated, so the `cfprefsd` warning appears at most once
    /// (first launch after this update) and never again.
    private func migrateLegacySettings() -> StreamSettings? {
        guard let defaults = UserDefaults(suiteName: AppGroup.identifier),
              let data = defaults.data(forKey: AppGroup.settingsKey),
              let decoded = try? JSONDecoder().decode(StreamSettings.self, from: data) else {
            return nil
        }
        defaults.removeObject(forKey: AppGroup.settingsKey)
        return decoded
    }
}
