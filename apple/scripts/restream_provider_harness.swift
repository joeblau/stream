import Foundation
import StreamCore

@MainActor enum DesktopStorage { static let projectDirectory = URL(fileURLWithPath: "/unused-restream-fixture") }
@MainActor struct DesktopSettingsStore {
    func connectionSecrets(for _: StreamProtocol) -> (url: String, key: String) { ("", "") }
}
private struct EmptyProviderCredentials: ProviderCredentialStore {
    func string(for _: KeychainStore.Item) -> String? { nil }
    func set(_: String, for _: KeychainStore.Item) -> Bool { false }
    func remove(_: KeychainStore.Item) {}
}
@MainActor private final class RestreamFixture: ProviderRestreamBoundary {
    var hasProviderAuthorization = true
    var providerAuthorizationGeneration: UUID? = UUID()
    var providerGrantedScopes: Set<String>? = ["channels.read", "stream.read"]
    var calls: [String] = []
    var holdPath: String?, entered = false
    var gate: CheckedContinuation<Void, Never>?
    var foreign = false, changedSelection = false, badKey = false
    var error: ProviderFailure?
    var unsafeCover = false
    func signOut() { hasProviderAuthorization = false; providerAuthorizationGeneration = UUID() }
    func release() { gate?.resume(); gate = nil; holdPath = nil }
    func authorizedProviderRequest(_ request: URLRequest) async throws -> Data {
        precondition(request.httpMethod == "GET" && request.httpBody == nil && request.value(forHTTPHeaderField: "Authorization") == nil)
        let path = request.url!.path; calls.append(path)
        if path == holdPath { entered = true; await withCheckedContinuation { gate = $0 } }
        if let error { throw error }
        switch path {
        case "/v2/user/channels": return Data((foreign ? #"{"channels":[{"id":99}]}"# : #"{"channels":[{"id":42,"displayName":"Relay channel"}]}"#).utf8)
        case "/v2/user/ingest":
            let id = changedSelection && calls.filter { $0 == path }.count > 1 ? 9 : 8
            return Data("{\"ingestId\":\(id)}".utf8)
        case "/v2/user/streamKey": return Data((badKey ? #"{"streamKey":"bad\nkey"}"# : #"{"streamKey":"owned-fixture-relay-key","srtUrl":null}"#).utf8)
        case "/v2/user/events/upcoming":
            return try JSONSerialization.data(withJSONObject: [["id": "event-1", "title": "Owned title", "description": "Owned description", "status": "upcoming", "scheduledFor": 1_800_000_000,
                "coverUrl": unsafeCover ? "https://cdn.example/cover.png?token=PRIVATE" : "https://cdn.example/cover.png"]])
        default: preconditionFailure("Unexpected private route")
        }
    }
}
private actor RestreamPublicFixture {
    var calls = 0, duplicate = false, badURL = false
    func configure(duplicate: Bool = false, badURL: Bool = false) { self.duplicate = duplicate; self.badURL = badURL }
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        precondition(request.url!.absoluteString == "https://api.restream.io/v2/server/all")
        precondition(request.httpMethod == "GET" && request.httpBody == nil && request.value(forHTTPHeaderField: "Authorization") == nil)
        calls += 1
        let row: [String: Any] = ["id": 8, "name": "Autodetect", "rtmpUrl": badURL ? "rtmp://foreign.example/live" : "rtmp://live.restream.io/live"]
        return (try JSONSerialization.data(withJSONObject: duplicate ? [row, row] : [row]),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@main private struct RestreamProviderHarness {
    static func require(_ result: Bool, _ message: String) { precondition(result, message) }
    @MainActor static func account(_ boundary: RestreamFixture, _ publicAPI: RestreamPublicFixture) -> ProviderAccountSession {
        ProviderAccountSession(restream: boundary,
            vault: ProviderTokenVault(keychain: EmptyProviderCredentials(), transport: { _ in throw ProviderFailure(.unavailable) }),
            transport: { try await publicAPI.send($0) })
    }
    @MainActor static func until(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
        preconditionFailure("Owned asynchronous boundary did not enter")
    }
    @MainActor static func failure(_ expected: ProviderFailure.Kind? = nil, _ operation: () async throws -> Void) async {
        do { try await operation(); preconditionFailure("Unexpected successful import") }
        catch {
            if let expected { precondition((error as? ProviderFailure)?.kind == expected) }
            precondition(!error.localizedDescription.contains("owned-fixture-relay-key"))
        }
    }
    @MainActor static func main() async throws {
        let channel = ProviderChannel(id: "42", provider: .restream, title: "Owned relay")
        let wire = RestreamPublicFixture(), boundary = RestreamFixture(), session = account(boundary, wire)
        let connection = try await session.importConnection(provider: .restream, channel: channel, event: nil, endpoint: "")
        require(connection.endpoint == "rtmp://live.restream.io/live" && connection.streamKey == "owned-fixture-relay-key", "Actual discovery must retain the service-issued endpoint/key")
        require(boundary.calls == ["/v2/user/channels", "/v2/user/ingest", "/v2/user/streamKey", "/v2/user/ingest"], "Secret must follow fresh channel/selected-ingest discovery and selection recheck")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stream-restream-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("destinations.json"); try Data("[]".utf8).write(to: file)
        let destinations = DestinationSession(fileURL: file, settings: .default, legacyStore: DesktopSettingsStore())
        destinations.createRestreamRelay(connection: connection)
        let draft = destinations.draft[0]
        require(!draft.isEnabled && draft.providerBinding == nil && draft.providerTemplateID == "restream" && draft.transport == .rtmp, "Relay import must remain a disabled manual relay, without inferred event binding")
        require(destinations.credentials[draft.id] == connection, "Credentials belong only to the in-memory draft")
        let metadata = try JSONEncoder().encode(destinations.draft)
        require(!String(decoding: metadata, as: UTF8.self).contains(connection.streamKey), "Portable destination metadata must exclude keys")
        require(try Data(contentsOf: file) == Data("[]".utf8), "Discovery cannot apply or persist a destination")
        session.refresh(.restream); try await until { !session.snapshot(.restream).isWorking }
        let event = session.snapshot(.restream).events[0]
        require(event.title == "Owned title" && event.description == "Owned description" && event.coverURL?.host == "cdn.example" && event.state == .upcoming && event.scheduledAt != nil, "Supported Restream metadata must reach the actual native session")
        let pending = try JSONEncoder().encode(ProviderPendingRecord(event))
        require(!String(decoding: pending, as: UTF8.self).contains("cdn.example"), "Public cover discovery is excluded from repair persistence")
        boundary.unsafeCover = true
        session.refresh(.restream); try await until { !session.snapshot(.restream).isWorking }
        require(session.snapshot(.restream).events[0].coverURL == nil && session.snapshot(.restream).events[0].state == .upcoming, "Unsafe optional cover cannot invalidate lifecycle metadata")
        session.shutdown()
        for missing in [Set<String>(), ["channels.read"]] {
            let b = RestreamFixture(); b.providerGrantedScopes = missing
            let s = account(b, RestreamPublicFixture())
            await failure(.permission) { _ = try await s.importConnection(provider: .restream, channel: channel, event: nil, endpoint: "") }
            require(b.calls.isEmpty, "Missing scopes cannot issue secret/API discovery"); s.shutdown()
        }
        let unknown = RestreamFixture(); unknown.providerGrantedScopes = nil
        let unknownSession = account(unknown, RestreamPublicFixture())
        await failure(.permission) { _ = try await unknownSession.importConnection(provider: .restream, channel: channel, event: nil, endpoint: "") }
        require(unknown.calls.isEmpty, "Legacy unknown grants require explicit reauthorization"); unknownSession.shutdown()
        for variant in 0..<5 {
            let b = RestreamFixture(), w = RestreamPublicFixture(), s = account(b, w)
            b.foreign = variant == 0; b.changedSelection = variant == 1; b.badKey = variant == 2
            await w.configure(duplicate: variant == 3, badURL: variant == 4)
            await failure { _ = try await s.importConnection(provider: .restream, channel: channel, event: nil, endpoint: "") }
            if [0, 3, 4].contains(variant) { require(!b.calls.contains("/v2/user/streamKey"), "Invalid owner/server metadata cannot retrieve a key") }
            s.shutdown()
        }
        for mode in 0..<4 {
            let b = RestreamFixture(), w = RestreamPublicFixture(), s = account(b, w)
            b.holdPath = mode == 3 ? "/v2/user/streamKey" : "/v2/user/channels"
            let task = Task { try await s.importConnection(provider: .restream, channel: channel, event: nil, endpoint: "") }
            try await until { b.entered }
            if mode == 0 || mode == 3 { b.providerAuthorizationGeneration = UUID() }
            if mode == 1 { s.shutdown() }
            if mode == 2 { task.cancel() }
            let count = b.calls.count; b.release()
            await failure { _ = try await task.value }
            require(b.calls.count == count, "Retired/cancelled account cannot continue discovery or return a held key"); s.shutdown()
        }
        for path in ["/v2/user/channels", "/v2/user/streamKey"] {
            let b = RestreamFixture(), s = account(b, RestreamPublicFixture())
            b.holdPath = path
            let task = Task { try await s.importConnection(provider: .restream, channel: channel, event: nil, endpoint: "") }
            try await until { b.entered }
            task.cancel(); b.error = .init(.rateLimited, retryAfter: 30); b.release()
            await failure { _ = try await task.value }
            require(s.snapshot(.restream).failure == nil && s.canRequest(.restream), "A canceled late refusal cannot install account failure or cooldown")
            s.shutdown()
        }
        let quota = RestreamFixture(), quotaSession = account(quota, RestreamPublicFixture())
        quota.error = .init(.rateLimited, retryAfter: 30)
        await failure(.rateLimited) { _ = try await quotaSession.importConnection(provider: .restream, channel: channel, event: nil, endpoint: "") }
        require(!quotaSession.canRequest(.restream), "Rate refusal must block repeated discovery")
        let count = quota.calls.count
        await failure(.rateLimited) { _ = try await quotaSession.importConnection(provider: .restream, channel: channel, event: nil, endpoint: "") }
        require(quota.calls.count == count, "Cooldown must suppress repeated GETs"); quotaSession.shutdown()
        print("PASS: actual Restream AccountSession/API selected relay discovery, secret-last/rechecked ownership, scope/unknown-grant gates, public no-bearer servers, metadata/cover and persistence exclusion, disabled manual draft, malformed/foreign/changed metadata refusal, replacement/cancel/shutdown/late-key fences and rate cooldown; no live auth, provider writes or Keychain access")
    }
}
