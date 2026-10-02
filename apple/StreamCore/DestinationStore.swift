import Foundation

/// JSON holds only destination metadata. Each credential field has a stable-ID
/// Keychain account, so rename/reorder/transport changes cannot move a secret.
public struct DestinationStore: Sendable {
    public enum StoreError: Error, LocalizedError {
        case keychainWrite, duplicateIDs
        public var errorDescription: String? {
            switch self {
            case .keychainWrite: return "Keychain could not save the destination credentials. Your changes have not been applied."
            case .duplicateIDs: return "Destination IDs must be unique."
            }
        }
    }
    private let fileURL: URL
    private let keychain: KeychainStore

    public init(fileURL: URL, keychain: KeychainStore = KeychainStore(service: "com.joeblau.StreamMac.destinations")) {
        self.fileURL = fileURL
        self.keychain = keychain
    }

    public func load() throws -> [StreamDestination] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let destinations = try JSONDecoder().decode([StreamDestination].self, from: Data(contentsOf: fileURL))
        guard Set(destinations.map(\.id)).count == destinations.count else { throw StoreError.duplicateIDs }
        return destinations
    }

    public func save(_ destinations: [StreamDestination], credentials: [UUID: DestinationCredentials]) throws {
        guard Set(destinations.map(\.id)).count == destinations.count else { throw StoreError.duplicateIDs }
        let previous = try load()
        // Check all credential writes before committing the new metadata.
        let previousSecrets = Dictionary(uniqueKeysWithValues: destinations.map { ($0.id, self.credentials(for: $0.id)) })
        do {
            for destination in destinations {
                if let secret = credentials[destination.id] { try write(secret, for: destination.id) }
            }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(destinations).write(to: fileURL, options: .atomic)
        } catch {
            for (id, secret) in previousSecrets { try? write(secret, for: id) }
            throw error
        }
        for removed in previous where !destinations.contains(where: { $0.id == removed.id }) {
            removeCredentials(for: removed.id)
        }
    }

    public func credentials(for id: UUID) -> DestinationCredentials {
        DestinationCredentials(endpoint: keychain.string(for: .destination(id, field: .endpoint)) ?? "",
                               streamKey: keychain.string(for: .destination(id, field: .streamKey)) ?? "",
                               srtStreamID: keychain.string(for: .destination(id, field: .srtStreamID)) ?? "",
                               srtPassphrase: keychain.string(for: .destination(id, field: .srtPassphrase)) ?? "")
    }

    private func write(_ credentials: DestinationCredentials, for id: UUID) throws {
        for (field, value) in [(DestinationCredentialField.endpoint, credentials.endpoint),
                               (.streamKey, credentials.streamKey), (.srtStreamID, credentials.srtStreamID),
                               (.srtPassphrase, credentials.srtPassphrase)] {
            guard keychain.set(value, for: .destination(id, field: field)) else { throw StoreError.keychainWrite }
        }
    }

    private func removeCredentials(for id: UUID) {
        for field in DestinationCredentialField.allCases { keychain.remove(.destination(id, field: field)) }
    }

    /// Called only while the project has no destination metadata. Legacy slots
    /// remain intact for the iOS client; a saved empty list is an intentional removal.
    public func migrateLegacyIfNeeded(settings: StreamSettings,
                                      connection: (StreamProtocol) -> (url: String, key: String)) throws -> [StreamDestination] {
        if FileManager.default.fileExists(atPath: fileURL.path) { return try load() }
        var destinations: [StreamDestination] = []
        var secrets: [UUID: DestinationCredentials] = [:]
        for transport in StreamProtocol.allCases {
            let old = connection(transport)
            guard !old.url.isEmpty || !old.key.isEmpty else { continue }
            let destination = StreamDestination(name: transport.displayName, transport: transport,
                isEnabled: transport == settings.selectedProtocol, outputProfile: settings.outputProfile,
                videoCodec: transport.supports(settings.videoCodec) ? settings.videoCodec : .h264,
                videoBitrate: settings.videoBitrate, audioBitrate: settings.audioBitrate)
            destinations.append(destination)
            secrets[destination.id] = DestinationCredentials(endpoint: old.url, streamKey: old.key)
        }
        try save(destinations, credentials: secrets)
        return destinations
    }
}
