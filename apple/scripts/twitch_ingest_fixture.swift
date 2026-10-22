import Foundation
import StreamCore

private actor TwitchPublicHTTP {
    var count = 0, hold = false, entered = false
    var status = 200, malformed = false
    var gate: CheckedContinuation<Void, Never>?
    func configure(hold: Bool = false, status: Int = 200, malformed: Bool = false) { self.hold = hold; self.status = status; self.malformed = malformed; entered = false }
    func release() { hold = false; gate?.resume(); gate = nil }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        precondition(request.url!.absoluteString == "https://ingest.twitch.tv/ingests" && request.httpMethod == "GET")
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Client-ID") == nil && request.httpBody == nil)
        count += 1
        let name = count == 1 ? "First endpoint" : "Replacement endpoint", status = self.status
        let body = malformed ? "not JSON" : "{\"ingests\":[{\"_id\":0,\"name\":\"\(name)\",\"url_template\":\"rtmp://atl.contribute.video.net/app/{stream_key}\",\"default\":false,\"priority\":99}]}"
        if hold { entered = true; await withCheckedContinuation { gate = $0 } }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "30"])!)
    }
}
private final class TwitchMemoryCredentials: ProviderCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(for item: KeychainStore.Item) -> String? { lock.withLock { values[String(reflecting: item)] } }
    func set(_ value: String, for item: KeychainStore.Item) -> Bool { lock.withLock { values[String(reflecting: item)] = value }; return true }
    func remove(_ item: KeychainStore.Item) { _ = lock.withLock { values.removeValue(forKey: String(reflecting: item)) } }
}
private actor TwitchPrivateHTTP {
    var paths: [String] = [], holdPath: String?, entered = false
    var refusalPath: String?
    var revokeKey = false
    var gate: CheckedContinuation<Void, Never>?
    func hold(_ path: String) { holdPath = path; entered = false }
    func refuse(_ path: String) { refusalPath = path }
    func revoke() { revokeKey = true }
    func release() { holdPath = nil; gate?.resume(); gate = nil }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path; paths.append(path)
        if path == "/oauth2/token" {
            precondition(request.url!.host == "id.twitch.tv" && request.httpMethod == "POST")
            return (Data(#"{"error":"invalid_grant"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
        }
        precondition(request.httpMethod == "GET" && request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        precondition(request.httpBody == nil)
        if path.hasPrefix("/helix/") {
            precondition(request.url!.host == "api.twitch.tv" && request.value(forHTTPHeaderField: "Client-ID") == "fixture")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            if path == "/helix/streams/key" { precondition(query.count == 1 && query[0].name == "broadcaster_id" && query[0].value == "42") }
            else { precondition(query.isEmpty) }
        }
        if path == holdPath { entered = true; await withCheckedContinuation { gate = $0 } }
        let body: String
        switch path {
        case "/oauth2/validate": body = #"{"client_id":"fixture","user_id":"42","scopes":["channel:read:stream_key"],"expires_in":3600}"#
        case "/helix/users": body = #"{"data":[{"id":"42","display_name":"Owned Twitch","login":"owned"}]}"#
        case "/helix/streams/key": body = #"{"data":[{"stream_key":"owned-fixture-twitch-key"}]}"#
        default: preconditionFailure("Unexpected authenticated Twitch route")
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: revokeKey && path == "/helix/streams/key" ? 401 : (path == refusalPath ? 429 : 200), httpVersion: nil, headerFields: ["Retry-After": "30"])!)
    }
}
enum TwitchProviderFixture {
    @MainActor private static func until(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 { if await condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
        preconditionFailure("Owned Twitch boundary did not enter")
    }
    @MainActor static func run(root: URL) async throws {
        let http = TwitchPublicHTTP(), discovery = TwitchIngestDiscovery(transport: { try await http.send($0) })
        precondition(discovery.endpoint(id: 0, for: "A") == nil)
        discovery.load(for: "A"); try await until { !discovery.isWorking }
        precondition(discovery.failure == nil && discovery.endpoints.count == 1)
        precondition(discovery.endpoint(id: 0, for: "A") == "rtmp://atl.contribute.video.net/app")
        precondition(discovery.endpoint(id: 0, for: "other") == nil && discovery.endpoint(id: 99, for: "A") == nil)
        await http.configure(hold: true); discovery.load(for: "A"); try await until { await http.entered }
        await http.configure(); discovery.load(for: "B"); try await until { !discovery.isWorking }
        await http.release(); try await Task.sleep(for: .milliseconds(10))
        precondition(discovery.endpoints.first?.name == "Replacement endpoint" && discovery.endpoint(id: 0, for: "A") == nil)
        for status in [200, 429, 503] {
            let wire = TwitchPublicHTTP(), model = TwitchIngestDiscovery(transport: { try await wire.send($0) })
            await wire.configure(hold: true, status: status); model.load(for: "old"); try await until { await wire.entered }
            model.cancel(); await wire.release(); try await Task.sleep(for: .milliseconds(10))
            precondition(model.endpoints.isEmpty && model.failure == nil && model.retryUntil == nil && !model.isWorking)
        }
        for (status, malformed, expected) in [(429, false, ProviderFailure.Kind.rateLimited), (503, false, .unavailable), (200, true, .invalidResponse)] {
            let wire = TwitchPublicHTTP(), model = TwitchIngestDiscovery(transport: { try await wire.send($0) })
            await wire.configure(status: status, malformed: malformed); model.load(for: "A"); try await until { !model.isWorking }
            precondition(model.failure?.kind == expected && model.endpoints.isEmpty)
            if status == 429 { model.load(for: "B"); let count = await wire.count; precondition(count == 1 && model.retryUntil != nil) }
            model.cancel()
        }
        let valid: [String: Any] = ["_id": 0, "name": "Official fixture", "url_template": "rtmp://atl.contribute.video.net/app/{stream_key}"]
        let global = try TwitchIngestEndpoint.parse(JSONSerialization.data(withJSONObject: ["ingests": [["_id": 99, "name": "Global automatic routing", "url_template": "rtmp://ingest.global-contribute.live-video.net/app/{stream_key}"]]]))
        precondition(global.first?.endpoint == "rtmp://ingest.global-contribute.live-video.net/app")
        for rows in [
            [valid, valid],
            [["_id": true, "name": "Bad", "url_template": "rtmp://atl.contribute.video.net/app/{stream_key}"]],
            [["_id": 1, "name": "Bad", "url_template": "rtmp://foreign.example/app/{stream_key}"]],
            [["_id": 1, "name": "Bad", "url_template": "rtmp://atl.contribute.video.net/app/private-key"]],
            [["_id": 1, "name": "Bad", "url_template": "rtmp://atl.contribute.video.net/app/{stream_key}?token=PRIVATE"]]
        ] {
            do { _ = try TwitchIngestEndpoint.parse(JSONSerialization.data(withJSONObject: ["ingests": rows])); preconditionFailure("Malformed/unsafe Twitch endpoint accepted") }
            catch {}
        }
        let channel = ProviderChannel(id: "42", provider: .twitch, title: "Owned")
        for mode in 0..<4 {
            let wire = TwitchPrivateHTTP(), vault = ProviderTokenVault(keychain: TwitchMemoryCredentials(), transport: { try await wire.send($0) })
            let generation = try await vault.configure(.twitch, clientID: "fixture")
            try await vault.accept(.init(access: "fixture-token", refresh: "fixture-refresh", expiresAt: Date().addingTimeInterval(3600), scopes: ["channel:read:stream_key"]), provider: .twitch, generation: generation)
            let session = ProviderAccountSession(restream: TwitchNoRestream(), vault: vault)
            if mode > 0 { await wire.hold(mode == 3 ? "/helix/streams/key" : "/helix/users") }
            let operation = Task { try await session.importConnection(provider: .twitch, channel: channel, event: nil, endpoint: "rtmp://atl.contribute.video.net/app") }
            if mode > 0 {
                try await until { await wire.entered }
                if mode == 1 || mode == 3 { _ = try await vault.configure(.twitch, clientID: "replacement") }
                else { operation.cancel() }
                let count = await wire.paths.filter { $0.hasPrefix("/helix/") }.count
                await wire.release()
                do { _ = try await operation.value; preconditionFailure("Retired Twitch account returned a key") } catch {}
                let after = await wire.paths.filter { $0.hasPrefix("/helix/") }.count; precondition(after == count)
            } else {
                let connection = try await operation.value
                precondition(connection.streamKey == "owned-fixture-twitch-key")
                let keyCount = await wire.paths.filter { $0 == "/helix/streams/key" }.count
                do {
                    _ = try await session.importConnection(provider: .twitch, channel: .init(id: "99", provider: .twitch, title: "Foreign"), event: nil, endpoint: "rtmp://atl.contribute.video.net/app")
                    preconditionFailure("Foreign selected channel retrieved a Twitch key")
                } catch {}
                let finalKeyCount = await wire.paths.filter { $0 == "/helix/streams/key" }.count
                precondition(finalKeyCount == keyCount)
                let file = root.appendingPathComponent("twitch-destinations.json"); try Data("[]".utf8).write(to: file)
                let destinations = DestinationSession(fileURL: file, settings: .default, legacyStore: DesktopSettingsStore())
                destinations.createManaged(provider: .twitch, channel: channel, connection: connection)
                precondition(destinations.draft.count == 1 && !destinations.draft[0].isEnabled && destinations.draft[0].providerBinding == nil)
            }
            session.shutdown()
        }
        for path in ["/helix/users", "/helix/streams/key"] {
            for mode in 0..<3 {
                let wire = TwitchPrivateHTTP(), vault = ProviderTokenVault(keychain: TwitchMemoryCredentials(), transport: { try await wire.send($0) })
                let generation = try await vault.configure(.twitch, clientID: "fixture")
                try await vault.accept(.init(access: "fixture-token", expiresAt: Date().addingTimeInterval(3600), scopes: ["channel:read:stream_key"]), provider: .twitch, generation: generation)
                let session = ProviderAccountSession(restream: TwitchNoRestream(), vault: vault)
                await wire.refuse(path)
                if mode > 0 { await wire.hold(path) }
                let operation = Task { try await session.importConnection(provider: .twitch, channel: channel, event: nil, endpoint: "rtmp://atl.contribute.video.net/app") }
                if mode > 0 {
                    try await until { await wire.entered }
                    if mode == 1 { operation.cancel() }
                    else { _ = try await vault.configure(.twitch, clientID: "replacement") }
                    await wire.release()
                }
                do { _ = try await operation.value; preconditionFailure("Twitch rate refusal returned credentials") } catch {}
                if mode == 0 {
                    precondition(session.snapshot(.twitch).failure?.kind == .rateLimited && !session.canRequest(.twitch))
                    let before = await wire.paths.filter { $0.hasPrefix("/helix/") }.count
                    do { _ = try await session.importConnection(provider: .twitch, channel: channel, event: nil, endpoint: "rtmp://atl.contribute.video.net/app"); preconditionFailure("Cooldown ignored") } catch {}
                    let after = await wire.paths.filter { $0.hasPrefix("/helix/") }.count; precondition(before == after)
                } else {
                    precondition(session.snapshot(.twitch).failure == nil && session.canRequest(.twitch), "Canceled/replaced refusal cannot poison a healthy current account")
                }
                session.shutdown()
            }
        }
        let revokedWire = TwitchPrivateHTTP(), revokedVault = ProviderTokenVault(keychain: TwitchMemoryCredentials(), transport: { try await revokedWire.send($0) })
        let authorization = try await revokedVault.configure(.twitch, clientID: "fixture")
        let revokedAccount = ProviderAccountSession(restream: TwitchNoRestream(), vault: revokedVault)
        // Finish empty boot before installing this owned token, so an unrelated
        // startup validation cannot satisfy the import's repair assertions.
        try await until { revokedAccount.snapshot(.twitch).clientID == "fixture" }
        try await revokedVault.accept(.init(access: "owned-old-token", refresh: "owned-old-refresh", expiresAt: Date().addingTimeInterval(3600), scopes: ["channel:read:stream_key"]), provider: .twitch, generation: authorization)
        await revokedWire.revoke()
        do {
            _ = try await revokedAccount.importConnection(provider: .twitch, channel: channel, event: nil, endpoint: "rtmp://atl.contribute.video.net/app")
            preconditionFailure("Revoked grant returned a key")
        } catch {
            precondition((error as? ProviderFailure)?.kind == .authorization, "Current revoked grant must retain reauthorization repair rather than masquerade as cancellation")
        }
        let tokenPresent = await revokedVault.hasToken(.twitch)
        precondition(!tokenPresent && revokedAccount.snapshot(.twitch).failure?.kind == .authorization && !revokedAccount.snapshot(.twitch).hasCredential && revokedAccount.snapshot(.twitch).verifiedAt == nil && revokedAccount.snapshot(.twitch).scopes.isEmpty)
        revokedAccount.shutdown()
        discovery.cancel()
        print("PASS: actual public Twitch client no-bearer GET/explicit exact-target selection, reserved-field independence, malformed/foreign/template/duplicate refusal, HTTP and rate cooldown, canceled success/error and replaced-target replies; fresh owned-channel/credential-fenced key import stays disabled/manual with no live auth or provider writes")
    }
}
@MainActor private final class TwitchNoRestream: ProviderRestreamBoundary {
    var hasProviderAuthorization = false
    func signOut() {}
    func authorizedProviderRequest(_ request: URLRequest) async throws -> Data { throw ProviderFailure(.unavailable) }
}
