import Foundation
import StreamCore

/// Desktop state has its own container; iOS continues to own the App Group settings.
@MainActor
enum DesktopStorage {
    static let machineDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("StreamStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var projectDirectory: URL = machineDirectory.appendingPathComponent("Projects/Default", isDirectory: true)

    static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        projectDirectory = directory
    }
}

/// Versioned desktop persistence with a separate Keychain service. The shared
/// StreamSettings value remains the adapter input to the existing publishers.
@MainActor
struct DesktopSettingsStore {
    private let url: URL
    private let keychain: KeychainStore
    private struct Document: Codable {
        var version = 1
        var settings: StreamSettings
    }

    init(directory: URL = DesktopStorage.projectDirectory) {
        url = directory.appendingPathComponent("desktop.settings.v1.json")
        keychain = KeychainStore(service: "com.joeblau.StreamMac.connection.\(directory.lastPathComponent)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func load() -> StreamSettings {
        var settings = StreamSettings.default
        if let data = try? Data(contentsOf: url),
           let document = try? JSONDecoder().decode(Document.self, from: data), document.version == 1 {
            settings = document.settings
        }
        let credentials = connectionSecrets(for: settings.selectedProtocol)
        settings.rtmpURL = credentials.url
        settings.streamKey = credentials.key
        return settings
    }

    func save(_ settings: StreamSettings) {
        saveConnectionSecrets(url: settings.rtmpURL, key: settings.streamKey, for: settings.selectedProtocol)
        saveNonSecret(settings)
    }

    func saveNonSecret(_ settings: StreamSettings) {
        // Never overwrite an unreadable or future settings document.
        if let existing = try? Data(contentsOf: url) {
            guard let document = try? JSONDecoder().decode(Document.self, from: existing), document.version == 1 else { return }
        }
        var redacted = settings
        redacted.rtmpURL = ""
        redacted.streamKey = ""
        guard let data = try? JSONEncoder().encode(Document(settings: redacted)) else { return }
        try? ProjectDocumentHistory.write(data, to: url)
    }

    func connectionSecrets(for proto: StreamProtocol) -> (url: String, key: String) {
        (keychain.string(for: .url(proto)) ?? "", keychain.string(for: .key(proto)) ?? "")
    }

    func saveConnectionSecrets(url: String, key: String, for proto: StreamProtocol) {
        keychain.set(url, for: .url(proto))
        keychain.set(key, for: .key(proto))
    }

    /// Copies the old desktop snapshot once without deleting or mutating iOS state.
    func migrateLegacyIfNeeded() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        var legacy = StreamSettings.default
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier),
           let data = try? Data(contentsOf: group.appendingPathComponent("\(AppGroup.settingsKey).json")),
           let decoded = try? JSONDecoder().decode(StreamSettings.self, from: data) { legacy = decoded }
        saveNonSecret(legacy)
        for proto in StreamProtocol.allCases {
            let credentials = SettingsStore().connectionSecrets(for: proto)
            saveConnectionSecrets(url: credentials.url, key: credentials.key, for: proto)
        }
    }
}
