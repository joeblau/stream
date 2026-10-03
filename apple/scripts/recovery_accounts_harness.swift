import Foundation
import StreamCore

private final class ReviewCredentials: ProviderCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(for item: KeychainStore.Item) -> String? { lock.withLock { values[String(reflecting: item)] } }
    func set(_ value: String, for item: KeychainStore.Item) -> Bool { lock.withLock { values[String(reflecting: item)] = value }; return true }
    func remove(_ item: KeychainStore.Item) { _ = lock.withLock { values.removeValue(forKey: String(reflecting: item)) } }
}
@MainActor private final class ReviewRestream: ProviderRestreamBoundary {
    var hasProviderAuthorization = false
    func signOut() {}
    func authorizedProviderRequest(_ request: URLRequest) async throws -> Data { throw ProviderFailure(.unavailable) }
}
private actor ReviewAccountHTTP {
    var calls: [URLRequest] = []
    var owned = true
    var eventOwner = "owner"
    var lifecycle = "live"
    var status = 200
    var hold = false
    var entered = false
    var gate: CheckedContinuation<Void, Never>?
    func configure(owned: Bool = true, eventOwner: String = "owner", lifecycle: String = "live", status: Int = 200, hold: Bool = false) {
        self.owned = owned; self.eventOwner = eventOwner; self.lifecycle = lifecycle
        self.status = status; self.hold = hold; entered = false
    }
    func release() { hold = false; gate?.resume(); gate = nil }
    func count() -> Int { calls.count }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        precondition(request.httpMethod == "GET" && request.httpBody == nil)
        precondition(request.cachePolicy == .reloadIgnoringLocalCacheData && request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
        precondition(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer FIXTURE") == true)
        calls.append(request)
        let object: [String: Any]
        if request.url!.path == "/youtube/v3/channels" {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            precondition(query.contains { $0.name == "mine" && $0.value == "true" })
            object = ["items": [["id": owned ? "owner" : "foreign", "snippet": ["title": "Fixture"]]]]
        } else if request.url!.path == "/youtube/v3/liveBroadcasts" {
            if hold { entered = true; await withCheckedContinuation { gate = $0 } }
            object = ["items": [["id": "event", "snippet": ["channelId": eventOwner], "status": ["lifeCycleStatus": lifecycle]]]]
        } else if request.url!.path == "/youtube/v3/liveStreams" { object = ["items": []] }
        else { preconditionFailure("Recovery reached a non-read resource") }
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@main struct RecoveryAccountHarness {
    @MainActor static func check(_ value: Bool, _ message: String = "Recovery account assertion failed") { precondition(value, message) }
    @MainActor static func until(_ predicate: () async -> Bool) async {
        for _ in 0..<1_000 { if await predicate() { return }; try? await Task.sleep(for: .milliseconds(2)) }
        preconditionFailure("Recovery account fixture did not settle")
    }
    @MainActor static func expectFailure(_ operation: () async throws -> Void) async {
        do { try await operation(); preconditionFailure("Unsafe request was accepted") } catch {}
    }
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stream-recovery-accounts-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let http = ReviewAccountHTTP(), vault = ProviderTokenVault(keychain: ReviewCredentials(), transport: { try await http.send($0) })
        let credential = try await vault.configure(.youtube, clientID: "fixture-public")
        try await vault.accept(.init(access: "FIXTURE_ACCESS", refresh: "FIXTURE_REFRESH", expiresAt: Date().addingTimeInterval(3600),
            scopes: ["https://www.googleapis.com/auth/youtube.readonly"]), provider: .youtube, generation: credential)
        let accounts = ProviderAccountSession(restream: ReviewRestream(), vault: vault, pendingDirectory: directory)
        await until { accounts.snapshot(.youtube).hasCredential }
        let output = UUID(), session = UUID(), project = UUID(), profile = UUID()
        var snapshot = SessionRecoverySnapshot(projectID: project, profileID: profile)
        snapshot.remoteEvents = [.init(outputID: output, eventID: "event", provider: .youtube, channelID: "owner", publisherSessionID: session, capturedAt: Date())]
        let coordinator = RecoveryEventReviewCoordinator()
        coordinator.load(snapshot, context: .init(projectID: project, profileID: profile, generation: UUID()))
        coordinator.bindAccounts(accounts)
        check(await http.count() == 0, "Binding or journal load made an API request")
        coordinator.verify(output); await until { !coordinator.verifying.contains(output) }
        precondition(coordinator.review(output).state == .reconnectable)
        check(await http.count() == 2)
        let generation = await accounts.recoveryAuthorizationGeneration()!
        check(await accounts.recoveryAuthorizationGeneration() == generation)
        var mutation = try ProviderAPI.request(.youtube, path: "/youtube/v3/liveBroadcasts/transition")
        mutation.httpMethod = "POST"
        await expectFailure { _ = try await accounts.managedReadRequest(mutation, expectedGeneration: generation) }
        var body = try ProviderAPI.request(.youtube, path: "/youtube/v3/liveBroadcasts")
        body.httpBody = Data("secret".utf8)
        await expectFailure { _ = try await accounts.managedReadRequest(body, expectedGeneration: generation) }
        let token = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        await expectFailure { _ = try await accounts.managedReadRequest(token, expectedGeneration: generation) }
        check(await http.count() == 2, "A forbidden request crossed the vault boundary")
        _ = try await accounts.managedReadRequest(ProviderAPI.request(.youtube, path: "/youtube/v3/liveStreams"), expectedGeneration: generation)
        await http.configure(lifecycle: "complete")
        coordinator.verify(output); await until { !coordinator.verifying.contains(output) }
        precondition(coordinator.review(output).state == .ended)
        await http.configure(owned: false)
        let beforeForeign = await http.count()
        coordinator.verify(output); await until { !coordinator.verifying.contains(output) }
        precondition(coordinator.review(output).reason == .foreignOwnership)
        check(await http.count() == beforeForeign + 1)
        await http.configure(eventOwner: "foreign")
        coordinator.verify(output); await until { !coordinator.verifying.contains(output) }
        precondition(coordinator.review(output).reason == .foreignOwnership)
        await http.configure(status: 403)
        coordinator.verify(output); await until { !coordinator.verifying.contains(output) }
        precondition(coordinator.review(output).reason == .permissionDenied)
        await http.configure(status: 503)
        coordinator.verify(output); await until { !coordinator.verifying.contains(output) }
        precondition(coordinator.review(output).reason == .unavailable)
        // The fixture's transport rejects OAuth POSTs. A 401 must end this
        // explicit review after one GET even though a refresh token exists.
        await http.configure(status: 401)
        let beforeUnauthorized = await http.count()
        coordinator.verify(output); await until { !coordinator.verifying.contains(output) }
        precondition(coordinator.review(output).reason == .authorizationNeeded)
        check(await http.count() == beforeUnauthorized + 1, "Explicit review replayed after 401")

        // Vault replacement is detectable even before cached UI facts change.
        await http.configure(hold: true)
        coordinator.verify(output); await until { await http.entered }
        let current = await vault.generation(.youtube)
        try await vault.accept(.init(access: "FIXTURE_REPLACED", expiresAt: Date().addingTimeInterval(3600),
            scopes: ["https://www.googleapis.com/auth/youtube.readonly"]), provider: .youtube, generation: current)
        await http.release(); await until { !coordinator.verifying.contains(output) }
        precondition(coordinator.review(output).reason == .accountChanged)
        check(await accounts.recoveryAuthorizationGeneration() != generation)
        let newGeneration = await accounts.recoveryAuthorizationGeneration()!
        await expectFailure {
            _ = try await accounts.managedReadRequest(ProviderAPI.request(.youtube, path: "/youtube/v3/channels"), expectedGeneration: generation)
        }
        // Actor-entry guard refuses an old captured credential generation even
        // when a newer token has already replaced it before send executes.
        let beforeStaleVault = await http.count()
        await expectFailure {
            _ = try await vault.send(.youtube, request: ProviderAPI.request(.youtube, path: "/youtube/v3/channels"),
                expectedGeneration: current, retryAuthorizedGET: false)
        }
        check(await http.count() == beforeStaleVault)
        await http.configure(hold: true)
        coordinator.verify(output); await until { await http.entered }
        coordinator.load(snapshot, context: .init(projectID: project, profileID: profile, generation: UUID()))
        await http.release(); try? await Task.sleep(for: .milliseconds(20))
        precondition(coordinator.review(output).state == .unknown && coordinator.review(output).checkedAt == nil)
        await http.configure(hold: true)
        coordinator.verify(output); await until { await http.entered }
        accounts.forget(.youtube)
        precondition(coordinator.review(output).state == .unknown && !coordinator.verifying.contains(output))
        await until { !accounts.snapshot(.youtube).hasCredential }
        await http.release(); try? await Task.sleep(for: .milliseconds(20))
        precondition(coordinator.review(output).state == .unknown)
        check(await accounts.recoveryAuthorizationGeneration() == nil)
        await expectFailure {
            _ = try await accounts.managedReadRequest(ProviderAPI.request(.youtube, path: "/youtube/v3/channels"), expectedGeneration: newGeneration)
        }
        let requestsBeforeClosure = await http.count()
        accounts.shutdown(); coordinator.shutdown()
        check(await accounts.recoveryAuthorizationGeneration() == nil)
        await expectFailure { _ = try await accounts.verifyRecoveryEvent(snapshot.remoteEvents[0].reviewIdentity!) }
        check(await http.count() == requestsBeforeClosure)

        // A token without actual granted read permission cannot invoke GETs.
        let noScopeGeneration = await vault.generation(.youtube)
        try await vault.accept(.init(access: "FIXTURE_NO_SCOPE", expiresAt: Date().addingTimeInterval(3600), scopes: []),
            provider: .youtube, generation: noScopeGeneration)
        let denied = ProviderAccountSession(restream: ReviewRestream(), vault: vault, pendingDirectory: directory.appendingPathComponent("denied"))
        await until { denied.snapshot(.youtube).hasCredential }
        check(await denied.recoveryAuthorizationGeneration() == nil)
        await expectFailure { _ = try await denied.verifyRecoveryEvent(snapshot.remoteEvents[0].reviewIdentity!) }
        denied.shutdown()
        check(await http.count() == requestsBeforeClosure)
        let publicJSON = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        precondition(!publicJSON.contains("FIXTURE") && !publicJSON.contains("Authorization") && !publicJSON.contains("endpoint"))
        print("PASS: actual account/vault + review binding performs no startup reads; granted readonly GET ownership chain; live/ended/foreign/permission/offline; POST/body/token path rejection; 401 never replays or refreshes")
        print("PASS: opaque generation fences both Session authorization intent and vault replacement; forget/profile/runtime change and closed Session reject late replies; missing scopes disable reads; no secret journal fields or real network/mutation")
        print("Environment: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }
}
