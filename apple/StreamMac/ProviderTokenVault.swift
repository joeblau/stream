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

/// Nonsecret retirement intent is separate from Keychain so a failed deletion
/// cannot reactivate a forgotten credential. Revisions also fence held refreshes
/// when a later deliberate authorization makes the provider active again.
struct ProviderCredentialRetirementStore: Sendable {
    struct State: Codable, Equatable, Sendable {
        let revision: UUID
        let retired: Bool
        static let legacy = State(revision: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, retired: false)
        static let unreadable = State(revision: legacy.revision, retired: true)
    }
    let read: @Sendable (ManagedProvider) -> State
    let write: @Sendable (ManagedProvider, State) -> Bool

    static func persistent(suiteName: String? = nil) -> Self {
        Self(read: { provider in
            guard let preferences = preferences(suiteName) else { return .unreadable }
            let key = "providerAccounts.retired.v1." + provider.rawValue
            guard let value = preferences.object(forKey: key) else { return .legacy }
            guard let raw = value as? Data, raw.count <= 1_024,
                  let state = try? JSONDecoder().decode(State.self, from: raw) else { return .unreadable }
            return state
        }, write: { provider, state in
            guard let preferences = preferences(suiteName), let data = try? JSONEncoder().encode(state) else { return false }
            preferences.set(data, forKey: "providerAccounts.retired.v1." + provider.rawValue)
            return preferences.synchronize()
        })
    }
    private static func preferences(_ suiteName: String?) -> UserDefaults? {
        if let suiteName { return UserDefaults(suiteName: suiteName) }
        return .standard
    }
    /// Injected credential boundaries never fall through to operator defaults.
    static func memory() -> Self {
        let memory = Memory()
        return Self(read: { provider in memory.lock.withLock { memory.states[provider] ?? .legacy } },
                    write: { provider, state in memory.lock.withLock { memory.states[provider] = state }; return true })
    }
    private final class Memory: @unchecked Sendable {
        let lock = NSLock()
        var states: [ManagedProvider: State] = [:]
    }
}

/// Local persistence failures must not be described as a provider API outage.
struct ProviderCredentialPersistenceFailure: Error, Sendable {}

actor ProviderTokenVault {
    #if STREAM_NATIVE_VALIDATION
    static let shared = ProviderTokenVault(keychain: NativeValidationProviderCredentials(), transport: { _ in
        throw ProviderFailure(.unavailable)
    })
    #else
    static let shared = ProviderTokenVault(keychain: KeychainStore(service: "com.joeblau.Stream.mac.providerAccounts"),
                                           retirement: .persistent())
    #endif
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let keychain: any ProviderCredentialStore
    private let transport: Transport
    private let retirement: ProviderCredentialRetirementStore
    private var locallyRetired: Set<ManagedProvider> = []
    private var authorizationRetirements: [ManagedProvider: ProviderCredentialRetirementStore.State] = [:]
    private struct Refresh {
        let id: UUID
        let generation: UUID
        let retirement: ProviderCredentialRetirementStore.State
        let task: Task<ProviderOAuthToken, Error>
    }
    private var refreshes: [ManagedProvider: Refresh] = [:]
    private var generations: [ManagedProvider: UUID] = [:]
    private var revokedCredentials: [ManagedProvider: (previous: UUID, empty: UUID)] = [:]
    init(keychain: any ProviderCredentialStore, retirement: ProviderCredentialRetirementStore = .memory(),
         transport: @escaping Transport = ProviderTokenVault.network) {
        self.keychain = keychain; self.retirement = retirement; self.transport = transport
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
            guard disconnect(provider) else { throw ProviderCredentialPersistenceFailure() }
            guard keychain.set(clientID, for: .provider(provider, field: .clientID)) else { throw ProviderCredentialPersistenceFailure() }
        } else {
            // Reauthorization can choose another user under the same client.
            // Fence existing refreshes before capturing the new OAuth grant's
            // acceptance generation; retain the stored token until acceptance.
            generations[provider] = UUID(); revokedCredentials[provider] = nil
            refreshes[provider]?.task.cancel(); refreshes[provider] = nil
        }
        authorizationRetirements[provider] = retirement.read(provider)
        return generation(provider)
    }
    func accept(_ token: ProviderOAuthToken, provider: ManagedProvider, generation expected: UUID) throws {
        try Task.checkCancellation()
        guard generation(provider) == expected,
              authorizationRetirements[provider] == retirement.read(provider) else { throw CancellationError() }
        // Only a deliberate grant may clear retirement. Persist denial before
        // replacement so any failed write/clear leaves old credentials denied.
        locallyRetired.insert(provider)
        let denied = ProviderCredentialRetirementStore.State(revision: UUID(), retired: true)
        guard retirement.write(provider, denied) else { throw ProviderCredentialPersistenceFailure() }
        try persist(token, provider: provider)
        let active = ProviderCredentialRetirementStore.State(revision: UUID(), retired: false)
        guard retirement.write(provider, active) else { throw ProviderCredentialPersistenceFailure() }
        locallyRetired.remove(provider)
        authorizationRetirements[provider] = nil
        // Accepting new OAuth authorization may change the user behind an
        // unchanged client ID. Late requests from the old user must be ignored.
        generations[provider] = UUID(); revokedCredentials[provider] = nil
        refreshes[provider]?.task.cancel(); refreshes[provider] = nil
    }
    @discardableResult func disconnect(_ provider: ManagedProvider) -> Bool {
        // Actor-local denial survives even when both storage writes fail. Only
        // successful marker persistence establishes denial across relaunch.
        locallyRetired.insert(provider)
        revokedCredentials[provider] = nil; authorizationRetirements[provider] = nil
        generations[provider] = UUID(); refreshes[provider]?.task.cancel(); refreshes[provider] = nil
        let retired = retirement.write(provider, .init(revision: UUID(), retired: true))
        let removed = keychain.set("", for: .provider(provider, field: .tokens))
        return retired && removed
    }
    private func isRetired(_ provider: ManagedProvider) -> Bool {
        locallyRetired.contains(provider) || retirement.read(provider).retired
    }
    /// A refresh revocation can change generation without replacing the user.
    /// This actor-local receipt identifies that exact empty successor only.
    func revocationGeneration(_ provider: ManagedProvider, previous: UUID) -> UUID? {
        guard let receipt = revokedCredentials[provider], receipt.previous == previous,
              receipt.empty == generation(provider), !hasToken(provider) else { return nil }
        return receipt.empty
    }
    private func load(_ provider: ManagedProvider) -> ProviderOAuthToken? {
        guard !isRetired(provider), let raw = keychain.string(for: .provider(provider, field: .tokens)), raw.utf8.count <= 65_536 else { return nil }
        return try? JSONDecoder().decode(ProviderOAuthToken.self, from: Data(raw.utf8))
    }
    private func save(_ token: ProviderOAuthToken, provider: ManagedProvider,
                      retirement expected: ProviderCredentialRetirementStore.State) throws {
        guard !isRetired(provider), retirement.read(provider) == expected else { throw CancellationError() }
        try persist(token, provider: provider)
    }
    private func persist(_ token: ProviderOAuthToken, provider: ManagedProvider) throws {
        let data = try JSONEncoder().encode(token)
        guard data.count <= 65_536, keychain.set(String(decoding: data, as: UTF8.self), for: .provider(provider, field: .tokens)) else { throw ProviderCredentialPersistenceFailure() }
    }
    private func current(_ provider: ManagedProvider, forceRefresh: Bool = false) async throws -> ProviderOAuthToken {
        guard let token = load(provider) else { throw ProviderFailure(.authorization) }
        if !forceRefresh && token.expiresAt.timeIntervalSinceNow > 60 { return token }
        let expected = generation(provider), retired = retirement.read(provider)
        if let refresh = refreshes[provider] {
            if refresh.generation == expected, refresh.retirement == retired {
                let value = try await refresh.task.value
                guard generation(provider) == expected else { throw CancellationError() }
                try save(value, provider: provider, retirement: refresh.retirement)
                return value
            }
            // A fresh caller cannot adopt an old context's held task merely
            // because reauthorization has made the marker active again.
            refresh.task.cancel(); refreshes[provider] = nil
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
        let identity = UUID()
        refreshes[provider] = .init(id: identity, generation: expected, retirement: retired, task: task)
        do {
            let value = try await task.value
            guard generation(provider) == expected else { throw CancellationError() }
            try save(value, provider: provider, retirement: retired)
            if refreshes[provider]?.id == identity { refreshes[provider] = nil }
            return value
        } catch {
            if refreshes[provider]?.id == identity { refreshes[provider] = nil }
            if generation(provider) == expected, retirement.read(provider) == retired, !isRetired(provider) {
                if (error as? ProviderFailure)?.kind == .authorization {
                    disconnect(provider)
                    revokedCredentials[provider] = (expected, generation(provider))
                }
            }
            throw error
        }
    }
    func validateTwitch() async throws {
        let expected = generation(.twitch), retired = retirement.read(.twitch)
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let token = try await current(.twitch)
            guard generation(.twitch) == expected, retirement.read(.twitch) == retired, !isRetired(.twitch) else { throw CancellationError() }
            try Task.checkCancellation()
            var request = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/validate")!)
            request.setValue("Bearer \(token.access)", forHTTPHeaderField: "Authorization"); request.timeoutInterval = 30
            let (data, response) = try await transport(request)
            try Task.checkCancellation()
            guard generation(.twitch) == expected, retirement.read(.twitch) == retired, !isRetired(.twitch) else { throw CancellationError() }
            // Refresh preserves the account generation but can rotate both
            // credentials while validation is suspended. Its predecessor's
            // response must neither overwrite nor revoke the refreshed token.
            guard load(.twitch) == token else {
                if attempt == 0 { continue } // Validate the current token once.
                throw CancellationError()
            }
            do { try ProviderFailure.check(data: data, response: response) }
            catch {
                if (error as? ProviderFailure)?.kind == .authorization { disconnect(.twitch) }
                throw error
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["client_id"] as? String == clientID(.twitch), let id = object["user_id"] as? String,
                  ProviderChannel.validID(id), let scopes = object["scopes"] as? [String],
                  let seconds = object["expires_in"] as? Double, seconds.isFinite, seconds > 0 else { throw ProviderFailure(.authorization) }
            var validated = token; validated.scopes = scopes; validated.expiresAt = Date().addingTimeInterval(seconds)
            try save(validated, provider: .twitch, retirement: retired)
            return
        }
    }
    func send(_ provider: ManagedProvider, request: URLRequest, expectedGeneration: UUID? = nil,
              retryAuthorizedGET: Bool = true,
              authorizationIsCurrent: @Sendable () -> Bool = { true }, requiredAnyScope: Set<String> = []) async throws -> Data {
        let expected = generation(provider), retired = retirement.read(provider)
        guard authorizationIsCurrent(), expectedGeneration.map({ $0 == expected }) ?? true else { throw ProviderFailure(.authorization) }
        let allowed = provider == .youtube ? "www.googleapis.com" : (provider == .twitch ? "api.twitch.tv" : "")
        let path = request.url?.path ?? ""
        let regularAPI = path.hasPrefix(provider == .youtube ? "/youtube/v3/" : "/helix/")
        let thumbnailUpload = provider == .youtube && path == "/upload/youtube/v3/thumbnails/set" && request.httpMethod == "POST"
            && ["image/jpeg", "image/png"].contains(request.value(forHTTPHeaderField: "Content-Type") ?? "")
            && (1...2_097_152).contains(request.httpBody?.count ?? 0)
        guard request.url?.scheme == "https", request.url?.host == allowed, request.url?.user == nil, request.url?.password == nil,
              regularAPI || thumbnailUpload else { throw ProviderFailure(.invalidRequest) }
        var token = try await current(provider), authorized = request
        guard authorizationIsCurrent(), generation(provider) == expected, retirement.read(provider) == retired, !isRetired(provider) else { throw ProviderFailure(.authorization) }
        guard requiredAnyScope.isEmpty || !requiredAnyScope.isDisjoint(with: token.scopes) else { throw ProviderFailure(.permission) }
        try Task.checkCancellation()
        authorized.setValue("Bearer \(token.access)", forHTTPHeaderField: "Authorization")
        if provider == .twitch { authorized.setValue(clientID(provider), forHTTPHeaderField: "Client-ID") }
        guard authorizationIsCurrent() else { throw ProviderFailure(.authorization) }
        try Task.checkCancellation()
        var (data, response) = try await transport(authorized)
        // A delayed 401 belongs to the captured credential. It cannot refresh
        // a replacement account or revive work cancelled while HTTP was held.
        guard authorizationIsCurrent(), generation(provider) == expected, retirement.read(provider) == retired, !isRetired(provider) else { throw CancellationError() }
        try Task.checkCancellation()
        // Read-only retries cannot duplicate an event mutation.
        if retryAuthorizedGET && response.statusCode == 401 && (request.httpMethod ?? "GET") == "GET" {
            token = try await current(provider, forceRefresh: true)
            guard authorizationIsCurrent(), generation(provider) == expected, retirement.read(provider) == retired, !isRetired(provider) else { throw ProviderFailure(.authorization) }
            guard requiredAnyScope.isEmpty || !requiredAnyScope.isDisjoint(with: token.scopes) else { throw ProviderFailure(.permission) }
            try Task.checkCancellation()
            authorized.setValue("Bearer \(token.access)", forHTTPHeaderField: "Authorization")
            guard authorizationIsCurrent() else { throw ProviderFailure(.authorization) }
            (data, response) = try await transport(authorized)
        }
        guard authorizationIsCurrent(), generation(provider) == expected, retirement.read(provider) == retired, !isRetired(provider) else { throw CancellationError() }
        try ProviderFailure.check(data: data, response: response)
        return data
    }
}

#if STREAM_NATIVE_VALIDATION
private struct NativeValidationProviderCredentials: ProviderCredentialStore {
    func string(for item: KeychainStore.Item) -> String? { nil }
    func set(_ value: String, for item: KeychainStore.Item) -> Bool { false }
    func remove(_ item: KeychainStore.Item) {}
}
#endif
