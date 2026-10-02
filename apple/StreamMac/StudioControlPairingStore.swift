import Combine
import Foundation
import Security

struct StudioControlClient: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var pairedAt = Date()
}
struct StudioControlPairing: Identifiable {
    let client: StudioControlClient
    let token: String
    var id: UUID { client.id }
}
@MainActor protocol StudioControlCredentials {
    func read(_ id: UUID) -> String?
    func write(_ token: String, for id: UUID) -> OSStatus
    func delete(_ id: UUID) -> OSStatus
}
@MainActor private struct StudioControlKeychainCredentials: StudioControlCredentials {
    private let service = "com.joeblau.StreamMac.local-control.v1"
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }
    func read(_ id: UUID) -> String? {
        var query = query(id)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    func write(_ token: String, for id: UUID) -> OSStatus {
        var query = query(id)
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil)
    }
    func delete(_ id: UUID) -> OSStatus { SecItemDelete(query(id) as CFDictionary) }
}
@MainActor final class StudioControlPairingStore: ObservableObject {
    @Published private(set) var clients: [StudioControlClient] = []
    @Published var pairing: StudioControlPairing?
    @Published private(set) var lastError: String?
    private let url: URL
    private let credentials: any StudioControlCredentials
    private var persistenceBlocked = false
    private struct Document: Codable { var version = 1; var clients: [StudioControlClient] }
    init(url: URL? = nil, credentials: (any StudioControlCredentials)? = nil) {
        self.credentials = credentials ?? StudioControlKeychainCredentials()
        self.url = url ?? DesktopStorage.machineDirectory.appendingPathComponent("local-control.clients.v1.json")
        if FileManager.default.fileExists(atPath: self.url.path) {
            do {
                let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: self.url))
                guard document.version == 1, document.clients.count <= 16,
                      Set(document.clients.map(\.id)).count == document.clients.count else {
                    persistenceBlocked = true; lastError = "The pairing file is unsupported and has been left unchanged."; return
                }
                clients = document.clients
            } catch { persistenceBlocked = true; lastError = "Could not read paired-client metadata." }
        }
    }
    func token(for id: UUID) -> String? {
        guard clients.contains(where: { $0.id == id }) else { return nil }
        return credentials.read(id)
    }
    func pair(name: String) {
        guard !persistenceBlocked else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 128, clients.count < 16 else { lastError = "Use a name of 1–128 characters and at most 16 paired clients."; return }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { lastError = "Could not generate a pairing credential."; return }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let client = StudioControlClient(name: name)
        let result = credentials.write(token, for: client.id)
        guard result == errSecSuccess else { lastError = "Could not save the pairing credential in Keychain (error \(result))."; return }
        do {
            try save(clients + [client])
            clients.append(client); pairing = StudioControlPairing(client: client, token: token); lastError = nil
        } catch { _ = credentials.delete(client.id); lastError = "Could not save client metadata." }
    }
    @discardableResult func revoke(_ id: UUID) -> Bool {
        guard !persistenceBlocked else { return false }
        let result = credentials.delete(id)
        guard result == errSecSuccess || result == errSecItemNotFound else { lastError = "Could not revoke this client's Keychain credential (error \(result))."; return false }
        clients.removeAll { $0.id == id }
        if pairing?.id == id { pairing = nil }
        do { try save(clients); lastError = nil } catch { lastError = "Credential revoked, but client metadata could not be saved." }
        return true
    }
    private func save(_ clients: [StudioControlClient]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Document(clients: clients)).write(to: url, options: .atomic)
    }
}
