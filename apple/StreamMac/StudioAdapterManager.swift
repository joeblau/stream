import Combine
import Foundation

@MainActor final class StudioAdapterManager: ObservableObject {
    @Published private(set) var document = StudioAdapterDocument()
    @Published private(set) var persistenceError: String?
    private let url: URL
    private var writable = true
    private weak var server: StudioLocalControlServer?
    init(directory: URL = DesktopStorage.machineDirectory) {
        url = directory.appendingPathComponent("studio.adapters.v1.json")
        if let data = try? Data(contentsOf: url) {
            guard let saved = try? JSONDecoder().decode(StudioAdapterDocument.self, from: data), saved.validationError == nil else {
                writable = false; persistenceError = "The adapter registry is unreadable or from another version. Preserve it before repairing the registry."; return
            }
            document = saved
        }
    }
    func bind(to server: StudioLocalControlServer) {
        self.server = server
        server.clientAuthorization = { [weak self] clientID, commandID in
            guard let self, self.writable else { return .init(code: "adapterRegistryUnavailable", message: "Repair the adapter registry in the studio before connecting controllers.") }
            return self.document.authorizationError(clientID: clientID, commandID: commandID)
        }
    }
    func register(_ manifest: StudioAdapterManifest, clientID: UUID) throws {
        if let error = manifest.hostCompatibilityError { throw StudioAdapterManagerError(message: error) }
        guard server?.pairingStore.clients.contains(where: { $0.id == clientID }) == true else { throw StudioAdapterManagerError(message: "Pair a dedicated client in Local Control before registering this adapter.") }
        guard !document.adapters.contains(where: { $0.id == manifest.id || $0.clientID == clientID }) else { throw StudioAdapterManagerError(message: "This adapter or client is already registered. Remove its existing registration before replacing it.") }
        var next = document
        next.adapters.append(.init(manifest: manifest, clientID: clientID, enabled: false))
        try save(next)
        server?.disconnectClient(clientID)
    }
    func setEnabled(_ id: String, _ enabled: Bool) throws {
        var next = document
        guard let index = next.adapters.firstIndex(where: { $0.id == id }) else { throw StudioAdapterManagerError(message: "The adapter no longer exists.") }
        next.adapters[index].enabled = enabled
        try save(next)
        if !enabled { server?.disconnectClient(next.adapters[index].clientID) }
    }
    /// Removing registration also revokes the credential: it must not turn a
    /// restricted adapter into an unrestricted generic paired controller.
    func remove(_ id: String) throws {
        guard let adapter = document.adapters.first(where: { $0.id == id }) else { return }
        var disabled = document
        if let index = disabled.adapters.firstIndex(where: { $0.id == id }) { disabled.adapters[index].enabled = false }
        try save(disabled); server?.disconnectClient(adapter.clientID)
        guard let server, server.pairingStore.revoke(adapter.clientID) else {
            throw StudioAdapterManagerError(message: "The adapter stays disabled because its credential could not be revoked. Repair Keychain access before removing it.")
        }
        var next = document; next.adapters.removeAll { $0.id == id }
        try save(next)
    }
    func status(_ adapter: StudioAdapterRegistration, server: StudioLocalControlServer) -> String {
        if !adapter.enabled { return "Disabled" }
        if !server.pairingStore.clients.contains(where: { $0.id == adapter.clientID }) { return "Pairing revoked" }
        if !server.enabled { return "Local Control disabled" }
        if server.authenticatedClientIDs.contains(adapter.clientID) { return "Connected" }
        return server.listeningPort == nil ? server.status : "Waiting for external adapter"
    }
    private func save(_ next: StudioAdapterDocument) throws {
        guard writable else { throw StudioAdapterManagerError(message: persistenceError ?? "The adapter registry cannot be changed.") }
        if let error = next.validationError { throw StudioAdapterManagerError(message: error) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(next).write(to: url, options: .atomic)
            document = next; persistenceError = nil
        } catch { persistenceError = "The adapter registry could not be saved."; throw StudioAdapterManagerError(message: persistenceError!) }
    }
}
struct StudioAdapterManagerError: Error, LocalizedError { var message: String; var errorDescription: String? { message } }
