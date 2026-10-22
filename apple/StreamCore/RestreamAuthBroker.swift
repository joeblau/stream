import CryptoKit
import Foundation

/// Native-side public client. Provider refresh tokens and the confidential app
/// secret are intentionally absent from this contract and its stored grant.
public struct RestreamBrokerGrant: Codable, Equatable, Sendable {
    public let origin: URL
    public let session: String
    public let credential: String
    public let access: String
    public let scopes: [String]
    public let expiresAt: Date
}
public struct RestreamBrokerAttempt: Sendable {
    public let id: String
    public let verifier: String
    public let state: String
    public let authorizationURL: URL
}
public struct RestreamAuthBroker: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    public let origin: URL
    private let send: Transport
    public init(origin: URL, send: @escaping Transport = RestreamBrokerHTTP.send) throws {
        guard let c = URLComponents(url: origin, resolvingAgainstBaseURL: false), c.scheme == "https", c.host != nil,
              c.user == nil, c.password == nil, c.port == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/" else { throw ProviderFailure(.invalidRequest) }
        self.origin = URL(string: "https://\(c.host!)")!; self.send = send
    }
    private static func identifier(_ value: Any?) -> String? {
        guard let s = value as? String, s.utf8.count == 43,
              s.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        return s
    }
    private func request(_ path: String, body: [String: String], credential: String? = nil) async throws -> [String: Any] {
        try Task.checkCancellation()
        var request = URLRequest(url: origin.appendingPathComponent(path)); request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let credential { request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await send(request)
        try Task.checkCancellation()
        guard data.count <= 65_536 else { throw ProviderFailure(.invalidResponse) }
        if response.statusCode == 429 { throw ProviderFailure(.rateLimited, retryAfter: 60) }
        guard response.statusCode == 200 else { throw ProviderFailure(response.statusCode == 401 ? .authorization : .unavailable) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["refresh_token"] == nil, object["client_secret"] == nil else { throw ProviderFailure(.invalidResponse) }
        return object
    }
    public func begin() async throws -> RestreamBrokerAttempt {
        let verifier = try ProviderOAuth.randomURLSafe(), state = try ProviderOAuth.randomURLSafe()
        let object = try await request("v1/attempts", body: ["challenge": ProviderOAuth.challenge(verifier), "state": state])
        guard let id = Self.identifier(object["attempt"]), let raw = object["authorization_url"] as? String,
              raw.utf8.count <= 8192, let url = URL(string: raw), let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "https", c.host == "api.restream.io", c.path == "/login", c.port == nil,
              c.user == nil, c.password == nil, c.fragment == nil else { throw ProviderFailure(.invalidResponse) }
        let items = c.queryItems ?? []
        guard Set(items.map(\.name)) == Set(["response_type", "client_id", "redirect_uri", "state"]), items.count == 4,
              items.first(where: { $0.name == "response_type" })?.value == "code",
              items.first(where: { $0.name == "client_id" })?.value?.isEmpty == false,
              items.first(where: { $0.name == "redirect_uri" })?.value == origin.appendingPathComponent("oauth/callback").absoluteString,
              let providerState = items.first(where: { $0.name == "state" })?.value,
              providerState.hasPrefix(id + "."), Self.identifier(String(providerState.dropFirst(44))) != nil else { throw ProviderFailure(.invalidResponse) }
        return .init(id: id, verifier: verifier, state: state, authorizationURL: url)
    }
    public func complete(_ attempt: RestreamBrokerAttempt, callback: URL) async throws -> RestreamBrokerGrant {
        guard let c = URLComponents(url: callback, resolvingAgainstBaseURL: false), c.scheme == "streamchat", c.host == "oauth",
              c.path.isEmpty, c.user == nil, c.password == nil, c.port == nil, c.fragment == nil,
              let items = c.queryItems, items.count == 2, Set(items.map(\.name)) == Set(["attempt", "state"]),
              items.first(where: { $0.name == "attempt" })?.value == attempt.id,
              items.first(where: { $0.name == "state" })?.value == attempt.state else { throw ProviderFailure(.authorization) }
        let object = try await request("v1/sessions/\(attempt.id)/complete", body: ["verifier": attempt.verifier])
        guard object["session"] as? String == attempt.id, let credential = Self.identifier(object["credential"]) else { throw ProviderFailure(.invalidResponse) }
        return try grant(object, session: attempt.id, credential: credential)
    }
    public func refresh(_ previous: RestreamBrokerGrant) async throws -> RestreamBrokerGrant {
        guard previous.origin == origin, Self.identifier(previous.session) != nil, Self.identifier(previous.credential) != nil else { throw ProviderFailure(.authorization) }
        let object = try await request("v1/sessions/\(previous.session)/refresh",
            body: ["known_access": ProviderOAuth.base64URL(Data(SHA256.hash(data: Data(previous.access.utf8))))], credential: previous.credential)
        return try grant(object, session: previous.session, credential: previous.credential)
    }
    public func forget(_ previous: RestreamBrokerGrant) async throws {
        guard previous.origin == origin, Self.identifier(previous.session) != nil, Self.identifier(previous.credential) != nil else { throw ProviderFailure(.authorization) }
        _ = try await request("v1/sessions/\(previous.session)/forget", body: [:], credential: previous.credential)
    }
    private func grant(_ object: [String: Any], session: String, credential: String) throws -> RestreamBrokerGrant {
        guard let access = object["access_token"] as? String, !access.isEmpty, access.utf8.count <= 16_384,
              access.unicodeScalars.allSatisfy({ (0x21...0x7e).contains($0.value) }),
              let scopes = object["scope"] as? [String], scopes.count <= 100,
              scopes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
              let seconds = object["expires_in"] as? Double, seconds.isFinite, seconds > 0, seconds <= 86_400 else { throw ProviderFailure(.invalidResponse) }
        return .init(origin: origin, session: session, credential: credential, access: access, scopes: scopes, expiresAt: Date().addingTimeInterval(seconds))
    }
}
/// No redirects, cookies or cache; bounded broker responses on both platforms.
public final class RestreamBrokerHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private static let shared = RestreamBrokerHTTP()
    private let lock = NSLock()
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral; c.httpShouldSetCookies = false; c.httpCookieAcceptPolicy = .never; c.urlCache = nil
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()
    private func client() -> URLSession { lock.lock(); defer { lock.unlock() }; return session }
    public static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let (bytes, response) = try await shared.client().bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderFailure(.invalidResponse) }
        var data = Data(); for try await byte in bytes { guard data.count < 65_536 else { throw ProviderFailure(.invalidResponse) }; data.append(byte) }
        return (data, http)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Separate nonsecret retirement intent is written before touching Keychain.
/// A failed deletion therefore cannot silently reactivate a stored grant on a
/// fresh process. All closures are injected for owned storage-failure fixtures.
@MainActor public final class RestreamBrokerGrantStore {
    private let readGrant: () -> String?
    private let writeGrant: (String?) -> Bool
    private let isRetired: () -> Bool
    private let setRetired: (Bool) -> Bool
    public init(readGrant: @escaping () -> String?, writeGrant: @escaping (String?) -> Bool,
                isRetired: @escaping () -> Bool, setRetired: @escaping (Bool) -> Bool) {
        self.readGrant = readGrant; self.writeGrant = writeGrant; self.isRetired = isRetired; self.setRetired = setRetired
    }
    public func load() -> RestreamBrokerGrant? {
        guard !isRetired(), let raw = readGrant(), raw.utf8.count <= 65_536 else { return nil }
        return try? JSONDecoder().decode(RestreamBrokerGrant.self, from: Data(raw.utf8))
    }
    public func save(_ value: RestreamBrokerGrant?) -> Bool {
        if let value {
            guard let data = try? JSONEncoder().encode(value), data.count <= 65_536,
                  let raw = String(data: data, encoding: .utf8), setRetired(true), writeGrant(raw) else { return false }
            return setRetired(false)
        }
        let retired = setRetired(true), removed = writeGrant(nil)
        return retired && removed
    }
}

/// Process-local ownership of the one machine Restream account, shared across
/// workspace runtimes. No credential or lease enters project metadata.
@MainActor public final class RestreamBrokerAuthority {
    public static let shared = RestreamBrokerAuthority()
    private var revision = UUID(), initialized = false
    private var identity: String?
    public init() {}
    private func key(_ grant: RestreamBrokerGrant) -> String {
        ProviderOAuth.base64URL(Data(SHA256.hash(data: Data((grant.origin.absoluteString + "\n" + grant.session + "\n" + grant.credential).utf8))))
    }
    fileprivate func adopt(_ grant: RestreamBrokerGrant?) -> UUID? {
        guard let grant else { return nil }
        if !initialized { initialized = true; identity = key(grant) }
        return identity == key(grant) ? revision : nil
    }
    fileprivate func begin() -> UUID { initialized = true; identity = nil; revision = UUID(); return revision }
    fileprivate func current(_ expected: UUID?) -> Bool { expected == revision }
    fileprivate func authorizes(_ grant: RestreamBrokerGrant?, expected: UUID?) -> Bool {
        guard let grant, current(expected) else { return false }; return identity == key(grant)
    }
    fileprivate func accept(_ grant: RestreamBrokerGrant, expected: UUID?) -> Bool {
        guard current(expected) else { return false }; identity = key(grant); return true
    }
}

/// Attempt and refresh ownership shared by the shipping native controller and
/// fixtures. Persistence succeeds before a new grant becomes usable in memory.
@MainActor public final class RestreamBrokerSession {
    public private(set) var grant: RestreamBrokerGrant?
    public var authorizedGrant: RestreamBrokerGrant? { authority.authorizes(grant, expected: credentialRevision) ? grant : nil }
    private let client: RestreamAuthBroker
    private let authority: RestreamBrokerAuthority
    private var credentialRevision: UUID?
    private let persist: @MainActor (RestreamBrokerGrant?) -> Bool
    private var generation = UUID()
    private var forgetJob: Task<Void, Never>?
    private var pending: String?
    private var refreshJob: (id: UUID, task: Task<RestreamBrokerGrant, Error>)?
    public init(client: RestreamAuthBroker, grant: RestreamBrokerGrant? = nil,
                authority: RestreamBrokerAuthority = .shared, persist: @escaping @MainActor (RestreamBrokerGrant?) -> Bool) {
        self.client = client; self.persist = persist; self.authority = authority
        if let grant, grant.origin == client.origin, grant.session.utf8.count == 43, grant.credential.utf8.count == 43,
           !grant.access.isEmpty, grant.access.utf8.count <= 16384,
           grant.access.unicodeScalars.allSatisfy({ (0x21...0x7e).contains($0.value) }),
           grant.scopes.count <= 100, grant.scopes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) {
            self.grant = grant; credentialRevision = authority.adopt(grant)
        }
    }
    public func cancel() {
        generation = UUID(); pending = nil; refreshJob?.task.cancel(); refreshJob = nil
    }
    public func retireAuthorization() {
        cancel()
        if authority.current(credentialRevision) { credentialRevision = authority.begin() }
    }
    @discardableResult public func forget() -> Bool {
        let previous = grant, client = client
        cancel(); grant = nil
        var saved = true
        if authority.current(credentialRevision) { credentialRevision = authority.begin(); saved = persist(nil) }
        if let previous { forgetJob = Task { try? await client.forget(previous) } }
        return saved
    }
    public func begin() async throws -> RestreamBrokerAttempt {
        cancel(); credentialRevision = authority.begin(); let expected = generation, credential = credentialRevision
        let attempt = try await client.begin()
        guard generation == expected, authority.current(credential), !Task.isCancelled else { throw CancellationError() }
        pending = attempt.id; return attempt
    }
    public func complete(_ attempt: RestreamBrokerAttempt, callback: URL) async throws -> RestreamBrokerGrant {
        try Task.checkCancellation()
        guard pending == attempt.id, authority.current(credentialRevision) else { throw ProviderFailure(.authorization) }
        pending = nil; let expected = generation, credential = credentialRevision
        let value = try await client.complete(attempt, callback: callback)
        guard generation == expected, authority.current(credential), !Task.isCancelled else { throw CancellationError() }
        guard persist(value) else { throw ProviderFailure(.unavailable) }
        guard authority.accept(value, expected: credential) else { throw CancellationError() }
        grant = value; return value
    }
    public func refresh() async throws -> RestreamBrokerGrant {
        try Task.checkCancellation()
        if let refreshJob { return try await refreshJob.task.value }
        guard let previous = authorizedGrant else { throw ProviderFailure(.authorization) }
        let expected = generation, credential = credentialRevision, id = UUID(), client = client
        let task = Task { [weak self] in
            guard let self, self.generation == expected, self.authority.current(credential), !Task.isCancelled else { throw CancellationError() }
            let value = try await client.refresh(previous)
            guard self.generation == expected, self.authority.current(credential), !Task.isCancelled else { throw CancellationError() }
            guard self.persist(value) else { throw ProviderFailure(.unavailable) }
            self.grant = value; return value
        }
        refreshJob = (id, task)
        defer { if refreshJob?.id == id { refreshJob = nil } }
        return try await task.value
    }
}
