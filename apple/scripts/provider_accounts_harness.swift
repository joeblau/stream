import Foundation
@preconcurrency import Network
import StreamCore

/// Exercises shipping vault, loopback receiver and native session with injected
/// HTTP/credential/browser boundaries. No real provider account is contacted.
final class MemoryProviderCredentials: ProviderCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private func key(_ item: KeychainStore.Item) -> String { String(reflecting: item) }
    func string(for item: KeychainStore.Item) -> String? { lock.lock(); defer { lock.unlock() }; return values[key(item)] }
    func set(_ value: String, for item: KeychainStore.Item) -> Bool { lock.lock(); defer { lock.unlock() }; values[key(item)] = value; return true }
    func remove(_ item: KeychainStore.Item) { lock.lock(); defer { lock.unlock() }; values[key(item)] = nil }
}
actor ProviderHTTPFixture {
    var requests: [URLRequest] = []
    var holdRefresh = false
    var refreshGate: CheckedContinuation<Void, Never>?
    var refreshEntered = false
    var apiStatus = 200
    var tokenStatus = 200
    var apiOnce401 = false
    var devicePending = false
    func configure(hold: Bool = false, status: Int = 200, once401: Bool = false, tokenStatus: Int = 200) {
        holdRefresh = hold; apiStatus = status; apiOnce401 = once401; self.tokenStatus = tokenStatus
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let host = request.url!.host!, path = request.url!.path
        var status = 200, body: String
        if host == "oauth2.googleapis.com" || (host == "id.twitch.tv" && path == "/oauth2/token") {
            if holdRefresh { refreshEntered = true; await withCheckedContinuation { refreshGate = $0 } }
            body = #"{"access_token":"fresh-access","refresh_token":"fresh-refresh","expires_in":3600,"scope":["https://www.googleapis.com/auth/youtube","channel:read:stream_key","channel:manage:broadcast"]}"#
        } else if path == "/oauth2/validate" {
            body = #"{"client_id":"client","user_id":"42","scopes":["channel:read:stream_key","channel:manage:broadcast"],"expires_in":3600}"#
        } else if path == "/oauth2/device" {
            body = #"{"device_code":"device","user_code":"ABCD","verification_uri":"https://www.twitch.tv/activate","expires_in":60,"interval":1}"#
        } else if path == "/youtube/v3/channels" {
            body = #"{"items":[{"id":"UC1","snippet":{"title":"Actual fixture channel"}}]}"#
        } else if path == "/youtube/v3/liveBroadcasts", request.httpMethod == "POST" {
            body = #"{"id":"acknowledged-id","snippet":{"channelId":"UC1","title":"Created"},"status":{"lifeCycleStatus":"created","privacyStatus":"private"}}"#
        } else if path == "/youtube/v3/liveBroadcasts" {
            body = #"{"items":[{"id":"event1","snippet":{"channelId":"UC1","title":"Scheduled"},"status":{"lifeCycleStatus":"ready"}}]}"#
        } else if path == "/helix/users" {
            body = #"{"data":[{"id":"42","display_name":"Operator","login":"operator"}]}"#
        } else { body = #"{"data":[]}"# }
        if host == "oauth2.googleapis.com" || (host == "id.twitch.tv" && path == "/oauth2/token") {
            status = tokenStatus
            if status == 400 { body = #"{"error":"invalid_grant","error_description":"SECRET_FIXTURE"}"# }
        }
        if host == "www.googleapis.com" || host == "api.twitch.tv" {
            status = apiStatus
            if apiOnce401 { apiOnce401 = false; status = 401 }
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func release() { holdRefresh = false; refreshGate?.resume(); refreshGate = nil }
    func count(host: String) -> Int { requests.filter { $0.url?.host == host }.count }
    func allRequests() -> [URLRequest] { requests }
}
/// Local HTTP is used only to exercise URLSession redirect/size behavior. The
/// production vault itself accepts only its documented HTTPS API hosts.
final class ProviderHTTPServerFixture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "stream.providers.http-fixture")
    private var listener: NWListener?
    private var requests = 0
    private var ready = false
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: .any)
                    let listener = try NWListener(using: parameters, on: .any)
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self] value in
                        guard let self else { return }
                        if case .ready = value, !self.ready {
                            self.ready = true
                            continuation.resume(returning: URL(string: "http://127.0.0.1:\(self.listener!.port!.rawValue)")!)
                        }
                        if case .failed = value, !self.ready { self.ready = true; continuation.resume(throwing: ProviderFailure(.unavailable)) }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        guard let self else { connection.cancel(); return }
                        connection.start(queue: self.queue)
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
                            guard let self, let data else { connection.cancel(); return }
                            self.requests += 1
                            let oversized = String(decoding: data, as: UTF8.self).hasPrefix("GET /large ")
                            let body = oversized ? Data(repeating: 120, count: 2_097_153) : Data()
                            let status = oversized ? "200 OK" : "302 Found"
                            let header = "HTTP/1.1 \(status)\r\nLocation: /redirect-target\r\nConnection: close\r\nContent-Length: \(body.count)\r\n\r\n"
                            connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
                        }
                    }
                    listener.start(queue: queue)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func count() async -> Int { await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.requests) } } }
    func stop() { queue.async { self.listener?.cancel(); self.listener = nil } }
}
@MainActor final class FixtureRestream: ProviderRestreamBoundary {
    var hasProviderAuthorization = false
    func signOut() { hasProviderAuthorization = false }
    func authorizedProviderRequest(_ request: URLRequest) async throws -> Data { throw ProviderFailure(.authorization) }
}
@main struct ProviderAccountsHarness {
    @MainActor static func main() async throws {
        try await loopback()
        try await httpBoundary()
        try await vaultLifecycle()
        try await nativeSession()
        print("Provider accounts: loopback/state/cancel, refresh coalescing/rotation/late response, safe GET retry, native OAuth/discovery/event receipt/shutdown PASS")
    }
    static func check(_ value: Bool, _ message: String = "Provider lifecycle assertion") { precondition(value, message) }
    static func settle(_ predicate: @Sendable () async -> Bool) async {
        for _ in 0..<1_000 { if await predicate() { return }; try? await Task.sleep(for: .milliseconds(5)) }
        preconditionFailure("Timed out waiting for a tested lifecycle boundary")
    }
    static func loopback() async throws {
        let receiver = OAuthLoopbackReceiver(), state = String(repeating: "s", count: 43)
        let redirect = try await receiver.start(state: state)
        precondition(redirect.host == "127.0.0.1" && redirect.port != nil)
        let (_, wrong) = try await URLSession.shared.data(from: URL(string: "\(redirect)?state=wrong&code=bad")!)
        precondition((wrong as? HTTPURLResponse)?.statusCode == 404)
        let responseTask = Task { try await receiver.response() }
        let (data, good) = try await URLSession.shared.data(from: URL(string: "\(redirect)?state=\(state)&code=code%2B%26")!)
        precondition((good as? HTTPURLResponse)?.statusCode == 200 && !String(decoding: data, as: UTF8.self).contains("code+&"))
        let code = try ProviderOAuth.googleCode(await responseTask.value, redirect: redirect, state: state)
        precondition(code == "code+&")
        let cancelled = OAuthLoopbackReceiver()
        _ = try await cancelled.start(state: state)
        let waiting = Task { try await cancelled.response() }
        waiting.cancel()
        do { _ = try await waiting.value; preconditionFailure("Cancellation accepted an OAuth callback") } catch is CancellationError {}
        let preCancelled = OAuthLoopbackReceiver(); preCancelled.cancel()
        do { _ = try await preCancelled.start(state: state); preconditionFailure("Cancelled receiver opened a listener") } catch is CancellationError {}
    }
    static func httpBoundary() async throws {
        let server = ProviderHTTPServerFixture(), base = try await server.start()
        defer { server.stop() }
        var request = URLRequest(url: base.appendingPathComponent("redirect"))
        request.setValue("Bearer FIXTURE", forHTTPHeaderField: "Authorization")
        let (_, response) = try await ProviderHTTP.shared.send(request)
        precondition(response.statusCode == 302)
        check(await server.count() == 1, "Authorized HTTP followed a redirect")
        request.url = base.appendingPathComponent("large")
        do { _ = try await ProviderHTTP.shared.send(request); preconditionFailure("HTTP accepted an oversized body") }
        catch let failure as ProviderFailure { precondition(failure.kind == .invalidResponse) }
    }
    static func vaultLifecycle() async throws {
        let memory = MemoryProviderCredentials(), http = ProviderHTTPFixture()
        let vault = ProviderTokenVault(keychain: memory, transport: { try await http.send($0) })
        let generation = try await vault.configure(.youtube, clientID: "client")
        try await vault.accept(.init(access: "expired", refresh: "refresh+&", expiresAt: .distantPast), provider: .youtube, generation: generation)
        await http.configure(hold: true)
        let request = try ProviderAPI.request(.youtube, path: "/youtube/v3/channels", query: ["mine": "true"])
        let first = Task { try await vault.send(.youtube, request: request) }
        await settle { await http.refreshEntered }
        let second = Task { try await vault.send(.youtube, request: request) }
        try await Task.sleep(for: .milliseconds(20))
        check(await http.count(host: "oauth2.googleapis.com") == 1, "Concurrent refreshes must use a single refresh token exchange")
        await http.release()
        _ = try await first.value; _ = try await second.value
        let requests = await http.allRequests()
        let form = String(decoding: requests.first!.httpBody!, as: UTF8.self)
        precondition(form.contains("refresh_token=refresh%2B%26") && !form.contains("client_secret"))
        precondition(requests.filter { $0.url?.host == "www.googleapis.com" }.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-access" })
        let stored = memory.string(for: .provider(.youtube, field: .tokens))!
        precondition(stored.contains("fresh-refresh"), "Rotated refresh token must be persisted")
        // A revoked/disconnected generation cannot resurrect credentials.
        let old = try await vault.configure(.twitch, clientID: "client")
        try await vault.accept(.init(access: "expired", refresh: "old", expiresAt: .distantPast), provider: .twitch, generation: old)
        await http.configure(hold: true)
        let late = Task { try await vault.send(.twitch, request: ProviderAPI.request(.twitch, path: "/helix/users")) }
        await settle { await http.refreshGate != nil }
        await vault.disconnect(.twitch); await http.release()
        do { _ = try await late.value; preconditionFailure("Late refresh was accepted") } catch is CancellationError {}
        check(await !vault.hasToken(.twitch))
        // A GET retries once after 401, while a mutation never repeats.
        await http.configure(once401: true)
        let before = await http.count(host: "www.googleapis.com")
        _ = try await vault.send(.youtube, request: request)
        check(await http.count(host: "www.googleapis.com") == before + 2)
        await http.configure(status: 401)
        var mutation = request; mutation.httpMethod = "POST"
        let count = await http.count(host: "www.googleapis.com")
        do { _ = try await vault.send(.youtube, request: mutation); preconditionFailure("Expected authorization failure") } catch let error as ProviderFailure { precondition(error.kind == .authorization) }
        check(await http.count(host: "www.googleapis.com") == count + 1)
        var hostile = request; hostile.url = URL(string: "https://evil.invalid/youtube/v3/channels")!
        do { _ = try await vault.send(.youtube, request: hostile); preconditionFailure("Token left provider allowlist") } catch let error as ProviderFailure { precondition(error.kind == .invalidRequest) }
        // Revoked refresh grants fail closed and cannot retain a usable credential.
        let revoked = try await vault.configure(.twitch, clientID: "client")
        try await vault.accept(.init(access: "expired", refresh: "revoked", expiresAt: .distantPast), provider: .twitch, generation: revoked)
        await http.configure(tokenStatus: 400)
        do { _ = try await vault.send(.twitch, request: ProviderAPI.request(.twitch, path: "/helix/users")); preconditionFailure("Revoked refresh grant accepted") }
        catch let failure as ProviderFailure { precondition(failure.kind == .authorization && !failure.localizedDescription.contains("SECRET_FIXTURE")) }
        check(await !vault.hasToken(.twitch))

    }
    @MainActor static func nativeSession() async throws {
        let http = ProviderHTTPFixture(), vault = ProviderTokenVault(keychain: MemoryProviderCredentials(), transport: { try await http.send($0) })
        var opened: URL?
        let session = ProviderAccountSession(restream: FixtureRestream(), vault: vault, transport: { try await http.send($0) }, openBrowser: { url in
            opened = url
            if url.host == "accounts.google.com" {
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                let redirect = items.first { $0.name == "redirect_uri" }!.value!, state = items.first { $0.name == "state" }!.value!
                Task { _ = try? await URLSession.shared.data(from: URL(string: "\(redirect)?code=fixture-code&state=\(state)")!) }
            }
            return true
        })
        session.authorize(.youtube, clientID: "client")
        await settle { await MainActor.run { session.snapshot(.youtube).channels.count == 1 && !session.snapshot(.youtube).isWorking } }
        precondition(opened?.host == "accounts.google.com")
        precondition(session.snapshot(.youtube).channels.first?.id == "UC1" && session.snapshot(.youtube).events.first?.id == "event1")
        let tokenRequest = await http.allRequests().first { $0.url?.host == "oauth2.googleapis.com" }!
        let fields = URLComponents(string: "https://fixture.invalid/?" + String(decoding: tokenRequest.httpBody!, as: UTF8.self))!.queryItems!
        let verifier = fields.first { $0.name == "code_verifier" }!.value!
        let auth = URLComponents(url: opened!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(ProviderOAuth.challenge(verifier) == auth.first { $0.name == "code_challenge" }!.value)
        session.createYouTube(.init(title: "Created"))
        await settle { await MainActor.run { session.snapshot(.youtube).events.contains { $0.id == "acknowledged-id" } } }
        precondition(session.snapshot(.youtube).events.filter { $0.id == "acknowledged-id" }.count == 1)
        session.refresh(.youtube)
        await settle { await MainActor.run { !session.snapshot(.youtube).isWorking } }
        precondition(session.snapshot(.youtube).events.contains { $0.id == "acknowledged-id" && $0.state == .unknown }, "An eventual-consistency refresh erased the acknowledged event ID")
        session.authorize(.twitch, clientID: "client")
        await settle { await MainActor.run { session.snapshot(.twitch).channels.first?.id == "42" && !session.snapshot(.twitch).isWorking } }
        precondition(session.snapshot(.twitch).scopes.contains("channel:read:stream_key"))
        // A provider failure/cooldown cannot alter the healthy peer account.
        await http.configure(status: 429)
        session.refresh(.youtube)
        await settle { await MainActor.run { !session.snapshot(.youtube).isWorking } }
        precondition(session.snapshot(.youtube).failure?.kind == .rateLimited && !session.canRequest(.youtube))
        precondition(session.snapshot(.twitch).verifiedAt != nil && session.snapshot(.twitch).failure == nil)
        let calls = await http.count(host: "www.googleapis.com")
        session.refresh(.youtube)
        check(await http.count(host: "www.googleapis.com") == calls, "Cooldown must suppress repeated API reads")
        session.shutdown()
        precondition(!session.snapshot(.youtube).isWorking && !session.snapshot(.twitch).isWorking)
        check(await vault.hasToken(.youtube), "Workspace shutdown must preserve reusable machine credentials")
        // The actual native session must discard a late OAuth token after a
        // workspace shutdown, even when the injected server ignores cancellation.
        let lateHTTP = ProviderHTTPFixture()
        await lateHTTP.configure(hold: true)
        let lateVault = ProviderTokenVault(keychain: MemoryProviderCredentials(), transport: { try await lateHTTP.send($0) })
        let lateSession = ProviderAccountSession(restream: FixtureRestream(), vault: lateVault, transport: { try await lateHTTP.send($0) }, openBrowser: { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let redirect = items.first { $0.name == "redirect_uri" }!.value!, state = items.first { $0.name == "state" }!.value!
            Task { _ = try? await URLSession.shared.data(from: URL(string: "\(redirect)?code=late&state=\(state)")!) }
            return true
        })
        lateSession.authorize(.youtube, clientID: "client")
        await settle { await lateHTTP.refreshEntered }
        lateSession.shutdown(); await lateHTTP.release()
        try await Task.sleep(for: .milliseconds(30))
        precondition(lateSession.snapshot(.youtube).channels.isEmpty && !lateSession.snapshot(.youtube).isWorking)
        check(await !lateVault.hasToken(.youtube), "A closed workspace accepted a late OAuth grant")

    }
}
