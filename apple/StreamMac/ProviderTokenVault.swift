import Foundation
import StreamCore

/// One reusable machine account per provider. No credentials enter project
/// metadata, recovery, URLs or logs. Refreshes coalesce and reject late replies.
protocol ProviderCredentialStore: Sendable {
    func string(for item: KeychainStore.Item) -> String?
    @discardableResult func set(_ value: String, for item: KeychainStore.Item) -> Bool
    func remove(_ item: KeychainStore.Item)
}
extension KeychainStore: ProviderCredentialStore {}

actor ProviderTokenVault {
    static let shared = ProviderTokenVault()
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let keychain: any ProviderCredentialStore
    private let transport: Transport
    private var refreshes: [ManagedProvider: Task<ProviderOAuthToken, Error>] = [:]
    private var generations: [ManagedProvider: UUID] = [:]
    init(keychain: any ProviderCredentialStore = KeychainStore(service: "com.joeblau.Stream.mac.providerAccounts"),
         transport: @escaping Transport = ProviderTokenVault.network) {
        self.keychain = keychain; self.transport = transport
    }
    static func network(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await ProviderHTTP.shared.send(request)
    }
    func clientID(_ provider: ManagedProvider) -> String { keychain.string(for: .provider(provider, field: .clientID)) ?? "" }
    func hasToken(_ provider: ManagedProvider) -> Bool { load(provider) != nil }
    func scopes(_ provider: ManagedProvider) -> [String] { load(provider)?.scopes ?? [] }
    func generation(_ provider: ManagedProvider) -> UUID {
        if let value = generations[provider] { return value }
        let value = UUID(); generations[provider] = value; return value
    }
    func configure(_ provider: ManagedProvider, clientID: String) throws -> UUID {
        guard [.youtube, .twitch].contains(provider), !clientID.isEmpty, clientID.utf8.count <= 500 else { throw ProviderFailure(.invalidRequest) }
        if self.clientID(provider) != clientID {
            disconnect(provider)
            guard keychain.set(clientID, for: .provider(provider, field: .clientID)) else { throw ProviderFailure(.unavailable) }
        }
        return generation(provider)
    }
    func accept(_ token: ProviderOAuthToken, provider: ManagedProvider, generation expected: UUID) throws {
        guard generation(provider) == expected else { throw CancellationError() }
        try save(token, provider: provider)
        // Accepting new OAuth authorization may change the user behind an
        // unchanged client ID. Late requests from the old user must be ignored.
        generations[provider] = UUID(); refreshes[provider]?.cancel(); refreshes[provider] = nil
    }
    func disconnect(_ provider: ManagedProvider) {
        generations[provider] = UUID(); refreshes[provider]?.cancel(); refreshes[provider] = nil
        keychain.remove(.provider(provider, field: .tokens))
    }
    private func load(_ provider: ManagedProvider) -> ProviderOAuthToken? {
        guard let raw = keychain.string(for: .provider(provider, field: .tokens)), raw.utf8.count <= 65_536 else { return nil }
        return try? JSONDecoder().decode(ProviderOAuthToken.self, from: Data(raw.utf8))
    }
    private func save(_ token: ProviderOAuthToken, provider: ManagedProvider) throws {
        let data = try JSONEncoder().encode(token)
        guard data.count <= 65_536, keychain.set(String(decoding: data, as: UTF8.self), for: .provider(provider, field: .tokens)) else { throw ProviderFailure(.unavailable) }
    }
    private func current(_ provider: ManagedProvider, forceRefresh: Bool = false) async throws -> ProviderOAuthToken {
        guard let token = load(provider) else { throw ProviderFailure(.authorization) }
        if !forceRefresh && token.expiresAt.timeIntervalSinceNow > 60 { return token }
        let expected = generation(provider)
        if let task = refreshes[provider] {
            let value = try await task.value
            guard generation(provider) == expected else { throw CancellationError() }
            try save(value, provider: provider)
            return value
        }
        guard let refresh = token.refresh else { throw ProviderFailure(.authorization) }
        let id = clientID(provider), send = transport
        let request = try ProviderOAuth.tokenRequest(provider, fields: ["client_id": id, "refresh_token": refresh, "grant_type": "refresh_token"])
        let task = Task {
            let (data, response) = try await send(request)
            if response.statusCode == 400, data.count <= 65_536,
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               ["invalid_grant", "invalid_token", "invalid_client"].contains(object["error"] as? String ?? "") {
                throw ProviderFailure(.authorization)
            }
            try ProviderFailure.check(data: data, response: response)
            return try ProviderOAuthToken.parse(data, previous: token)
        }
        refreshes[provider] = task
        do {
            let value = try await task.value
            guard generation(provider) == expected else { throw CancellationError() }
            try save(value, provider: provider); refreshes[provider] = nil
            return value
        } catch {
            if generation(provider) == expected {
                refreshes[provider] = nil
                if (error as? ProviderFailure)?.kind == .authorization { disconnect(provider) }
            }
            throw error
        }
    }
    func validateTwitch() async throws {
        let expected = generation(.twitch), token = try await current(.twitch)
        var request = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/validate")!)
        request.setValue("Bearer \(token.access)", forHTTPHeaderField: "Authorization"); request.timeoutInterval = 30
        let (data, response) = try await transport(request)
        do { try ProviderFailure.check(data: data, response: response) }
        catch {
            if (error as? ProviderFailure)?.kind == .authorization, generation(.twitch) == expected { disconnect(.twitch) }
            throw error
        }
        guard generation(.twitch) == expected,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["client_id"] as? String == clientID(.twitch), let id = object["user_id"] as? String,
              ProviderChannel.validID(id), let scopes = object["scopes"] as? [String],
              let seconds = object["expires_in"] as? Double, seconds.isFinite, seconds > 0 else { throw ProviderFailure(.authorization) }
        var validated = token; validated.scopes = scopes; validated.expiresAt = Date().addingTimeInterval(seconds)
        try save(validated, provider: .twitch)
    }
    func send(_ provider: ManagedProvider, request: URLRequest) async throws -> Data {
        let expected = generation(provider)
        let allowed = provider == .youtube ? "www.googleapis.com" : (provider == .twitch ? "api.twitch.tv" : "")
        guard request.url?.scheme == "https", request.url?.host == allowed, request.url?.user == nil, request.url?.password == nil, request.url?.path.hasPrefix(provider == .youtube ? "/youtube/v3/" : "/helix/") == true else { throw ProviderFailure(.invalidRequest) }
        var token = try await current(provider), authorized = request
        authorized.setValue("Bearer \(token.access)", forHTTPHeaderField: "Authorization")
        if provider == .twitch { authorized.setValue(clientID(provider), forHTTPHeaderField: "Client-ID") }
        var (data, response) = try await transport(authorized)
        // Read-only retries cannot duplicate an event mutation.
        if response.statusCode == 401 && (request.httpMethod ?? "GET") == "GET" {
            token = try await current(provider, forceRefresh: true)
            authorized.setValue("Bearer \(token.access)", forHTTPHeaderField: "Authorization")
            (data, response) = try await transport(authorized)
        }
        guard generation(provider) == expected else { throw CancellationError() }
        try ProviderFailure.check(data: data, response: response)
        return data
    }
}
