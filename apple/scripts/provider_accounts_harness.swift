import Foundation
import Darwin
@preconcurrency import Network
import StreamCore

/// Exercises shipping vault, loopback receiver and native session with injected
/// HTTP/credential/browser boundaries. No real provider account is contacted.
final class MemoryProviderCredentials: ProviderCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var rejectDeletion = false
    private var rejectTokens = false
    func fail(deletion: Bool = false, tokenWrite: Bool = false) {
        lock.withLock { rejectDeletion = deletion; rejectTokens = tokenWrite }
    }
    private func key(_ item: KeychainStore.Item) -> String { String(reflecting: item) }
    func string(for item: KeychainStore.Item) -> String? { lock.lock(); defer { lock.unlock() }; return values[key(item)] }
    func set(_ value: String, for item: KeychainStore.Item) -> Bool {
        lock.withLock {
            if value.isEmpty {
                guard !rejectDeletion else { return false }
                values[key(item)] = nil
            } else {
                if case .provider(_, field: .tokens) = item, rejectTokens { return false }
                values[key(item)] = value
            }
            return true
        }
    }
    func remove(_ item: KeychainStore.Item) { lock.lock(); defer { lock.unlock() }; values[key(item)] = nil }
}
/// Shared owned marker storage models a fresh vault reading persisted intent;
/// no test reads or writes the operator's UserDefaults or Keychain.
final class MemoryProviderRetirement: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [ManagedProvider: ProviderCredentialRetirementStore.State] = [:]
    private var rejectRetirement = false
    private var rejectActivation = false
    func fail(retirement: Bool = false, activation: Bool = false) {
        lock.withLock { rejectRetirement = retirement; rejectActivation = activation }
    }
    var store: ProviderCredentialRetirementStore {
        .init(read: { provider in self.lock.withLock { self.states[provider] ?? .legacy } },
              write: { provider, state in
                  self.lock.withLock {
                      guard !(state.retired ? self.rejectRetirement : self.rejectActivation) else { return false }
                      self.states[provider] = state
                      return true
                  }
              })
    }
}
actor ProviderHTTPFixture {
    var requests: [URLRequest] = []
    var eventLatency = "low"
    var eventThumbnail = "https://i.ytimg.com/vi/event1/high.jpg?sqp=public&rs=public"
    var viewerEventID = "event1"
    var channelID = "UC1"
    func setChannelID(_ id: String) { channelID = id }
    func setViewerEventID(_ id: String) { viewerEventID = id }
    var chatEntered = false
    var chatGate: CheckedContinuation<Void, Never>?
    var heldChatStatus: Int?
    var heldChatFailure: ProviderFailure?
    func holdNextChat(status: Int = 401, failure: ProviderFailure? = nil) {
        chatEntered = false; heldChatStatus = status; heldChatFailure = failure
    }
    func releaseChat() { chatGate?.resume(); chatGate = nil }
    func metadata(latency: String, thumbnail: String) { eventLatency = latency; eventThumbnail = thumbnail }
    var holdThumbnail = false
    var thumbnailEntered = false
    var thumbnailGate: CheckedContinuation<Void, Never>?
    func holdNextThumbnail() { holdThumbnail = true; thumbnailEntered = false }
    func releaseThumbnail() { holdThumbnail = false; thumbnailGate?.resume(); thumbnailGate = nil }
    var holdRefresh = false
    var refreshGate: CheckedContinuation<Void, Never>?
    var refreshEntered = false
    var apiStatus = 200
    var tokenStatus = 200
    var apiOnce401 = false
    var api401Remaining = 0
    func rejectNextAPIReads(_ count: Int) { api401Remaining = count }
    var devicePending = false
    var validationEntered = false
    var validationGate: CheckedContinuation<Void, Never>?
    var heldValidationStatus: Int?
    func holdNextValidation(status: Int) { validationEntered = false; heldValidationStatus = status }
    func releaseValidation() { validationGate?.resume(); validationGate = nil }
    func configure(hold: Bool = false, status: Int = 200, once401: Bool = false, tokenStatus: Int = 200) {
        holdRefresh = hold; apiStatus = status; apiOnce401 = once401; self.tokenStatus = tokenStatus
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let host = request.url!.host!, path = request.url!.path
        if path == "/youtube/v3/liveChat/messages", let status = heldChatStatus {
            chatEntered = true
            await withCheckedContinuation { chatGate = $0 }
            heldChatStatus = nil
            if let failure = heldChatFailure { throw failure }
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        var status = 200, body: String
        if host == "oauth2.googleapis.com" || (host == "id.twitch.tv" && path == "/oauth2/token") {
            if holdRefresh { refreshEntered = true; await withCheckedContinuation { refreshGate = $0 } }
            body = #"{"access_token":"fresh-access","refresh_token":"fresh-refresh","expires_in":3600,"scope":["https://www.googleapis.com/auth/youtube","channel:read:stream_key","channel:manage:broadcast"]}"#
        } else if path == "/oauth2/validate" {
            if let held = heldValidationStatus {
                validationEntered = true
                await withCheckedContinuation { validationGate = $0 }
                heldValidationStatus = nil; status = held
            }
            body = #"{"client_id":"client","user_id":"42","scopes":["channel:read:stream_key","channel:manage:broadcast"],"expires_in":3600}"#
        } else if path == "/oauth2/device" {
            body = #"{"device_code":"device","user_code":"ABCD","verification_uri":"https://www.twitch.tv/activate","expires_in":60,"interval":1}"#
        } else if path == "/upload/youtube/v3/thumbnails/set" {
            if holdThumbnail { thumbnailEntered = true; await withCheckedContinuation { thumbnailGate = $0 } }
            body = #"{"kind":"youtube#thumbnailSetResponse","items":[{"default":{"url":"https://i.ytimg.com/vi/event1/default.jpg","width":120,"height":90}}]}"#
        } else if path == "/youtube/v3/channels" {
            body = String(decoding: try JSONSerialization.data(withJSONObject: ["items": [["id": channelID,
                "snippet": ["title": "Actual fixture channel"]]]]), as: UTF8.self)
        } else if path == "/youtube/v3/liveBroadcasts", request.httpMethod == "POST" {
            body = #"{"id":"acknowledged-id","snippet":{"channelId":"UC1","title":"Created"},"status":{"lifeCycleStatus":"created","privacyStatus":"private"}}"#
        } else if path == "/youtube/v3/liveBroadcasts" {
            let row: [String: Any] = ["id": "event1", "snippet": ["channelId": "UC1", "title": "Scheduled", "thumbnails": [
                "high": ["url": eventThumbnail, "width": 1280, "height": 720],
                "futureSize": ["url": "https://ingest.invalid/live?key=PRIVATE_METADATA_FIXTURE"]]],
                "status": ["lifeCycleStatus": "ready"], "contentDetails": ["latencyPreference": eventLatency,
                "ingestionInfo": ["streamName": "PRIVATE_METADATA_FIXTURE"]]]
            body = String(decoding: try JSONSerialization.data(withJSONObject: ["items": [row]]), as: UTF8.self)
        } else if path == "/youtube/v3/videos" {
            body = "{\"items\":[{\"id\":\"\(viewerEventID)\",\"liveStreamingDetails\":{\"concurrentViewers\":\"23\"}}]}"
        } else if path == "/helix/users" {
            body = #"{"data":[{"id":"42","display_name":"Operator","login":"operator"}]}"#
        } else { body = #"{"data":[]}"# }
        if host == "oauth2.googleapis.com" || (host == "id.twitch.tv" && path == "/oauth2/token") {
            status = tokenStatus
            if status == 400 { body = #"{"error":"invalid_grant","error_description":"SECRET_FIXTURE"}"# }
        }
        if host == "www.googleapis.com" || host == "api.twitch.tv" {
            status = apiStatus
            if api401Remaining > 0 { api401Remaining -= 1; status = 401 }
            else if apiOnce401 { apiOnce401 = false; status = 401 }
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func release() { holdRefresh = false; refreshGate?.resume(); refreshGate = nil }
    func count(host: String) -> Int { requests.filter { $0.url?.host == host }.count }
    func allRequests() -> [URLRequest] { requests }
}
actor ProviderEndingHTTPFixture {
    var calls: [URLRequest] = []
    var completed: Set<String> = []
    var heldRead = false
    var entered = false
    var gate: CheckedContinuation<Void, Never>?
    func hold() { heldRead = true }
    func release() { heldRead = false; gate?.resume(); gate = nil }
    func send(_ call: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls.append(call)
        if call.url!.path == "/youtube/v3/channels" {
            let data = Data(#"{"items":[{"id":"UC1"}]}"#.utf8)
            return (data, HTTPURLResponse(url: call.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let id = URLComponents(url: call.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "id" }!.value!
        let row: [String: Any]
        if call.httpMethod == "POST" {
            completed.insert(id)
            row = ["id": id, "snippet": ["channelId": "UC1"], "status": ["lifeCycleStatus": "complete"]]
        } else {
            if heldRead { entered = true; await withCheckedContinuation { gate = $0 } }
            row = ["id": id, "snippet": ["channelId": "UC1"], "status": ["lifeCycleStatus": completed.contains(id) ? "complete" : "live"]]
        }
        let object: [String: Any]
        if call.httpMethod == "POST" { object = row } else { object = ["items": [row]] }
        let data = try JSONSerialization.data(withJSONObject: object)
        return (data, HTTPURLResponse(url: call.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    var count: Int { calls.count }
    var posts: Int { calls.filter { $0.httpMethod == "POST" }.count }
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
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--owned-retirement-child" {
            try await persistentRetirementChild(suite: CommandLine.arguments[2]); return
        }
        try await persistentRetirement()
        try await loopback()
        try await httpBoundary()
        try await vaultLifecycle()
        try await retirementFailures()
        try await retirementDuringHeldRefresh()
        try await nativeForgetStorageFailure()
        try await sameClientAuthorizationDuringRefresh()
        try await twitchValidationDuringRefresh()
        try await nativeSession()
        try await nativeChatLateReplies()
        try await nativeChatRevocation()
        try await nativeCrossWorkspaceChatAuthority()
        try await nativeEnding()
        print("Provider accounts: loopback/state/cancel, refresh coalescing/rotation/late response, durable retirement/storage failure/canceled acceptance/held-refresh replacement, safe GET retry, exact viewer identity/receipt freshness, twelve stale chat-reply fences/current revocation repair, native OAuth/discovery/public metadata/portable exclusions/event receipt/shutdown PASS")
    }
    static func twitchValidationDuringRefresh() async throws {
        for status in [200, 401] {
            let memory = MemoryProviderCredentials(), http = ProviderHTTPFixture()
            let vault = ProviderTokenVault(keychain: memory, transport: { try await http.send($0) })
            let configuration = try await vault.configure(.twitch, clientID: "client")
            try await vault.accept(.init(access: "old-access", refresh: "old-refresh", expiresAt: Date().addingTimeInterval(3_600),
                scopes: ManagedProvider.twitch.scopes), provider: .twitch, generation: configuration)
            let generation = await vault.generation(.twitch)
            await http.holdNextValidation(status: status)
            let validation = Task { try await vault.validateTwitch() }
            await settle { await http.validationEntered }
            await http.configure(once401: true)
            _ = try await vault.send(.twitch, request: ProviderAPI.request(.twitch, path: "/helix/users"))
            let refreshed = memory.string(for: .provider(.twitch, field: .tokens))!
            precondition(refreshed.contains("fresh-access") && refreshed.contains("fresh-refresh"))
            await http.releaseValidation()
            // A response for the pre-refresh token cannot validate or revoke its successor.
            try await validation.value
            let persisted = try JSONDecoder().decode(ProviderOAuthToken.self,
                from: Data((memory.string(for: .provider(.twitch, field: .tokens)) ?? "").utf8))
            check(persisted.access == "fresh-access" && persisted.refresh == "fresh-refresh",
                "Delayed Twitch validation replaced or revoked the refreshed credential")
            let validations = await http.allRequests().filter { $0.url?.path == "/oauth2/validate" }
            check(validations.count == 2 && validations.last!.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-access",
                "The stale validation did not revalidate the current same-account token")
            check(await vault.generation(.twitch) == generation, "Stale validation retired the same account's refresh")
            _ = try await vault.send(.twitch, request: ProviderAPI.request(.twitch, path: "/helix/users"))
            check(await http.allRequests().last!.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-access")
            // A deliberate new validation still updates current scopes/expiry.
            try await vault.validateTwitch()
            check(await vault.scopes(.twitch) == ["channel:read:stream_key", "channel:manage:broadcast"])
        }
        for status in [200, 401] {
            for replacement in [false, true] {
                let memory = MemoryProviderCredentials(), http = ProviderHTTPFixture()
                let vault = ProviderTokenVault(keychain: memory, transport: { try await http.send($0) })
                let configuration = try await vault.configure(.twitch, clientID: "client")
                try await vault.accept(.init(access: "current-access", refresh: "current-refresh", expiresAt: Date().addingTimeInterval(3_600)),
                    provider: .twitch, generation: configuration)
                await http.holdNextValidation(status: status)
                let validation = Task { try await vault.validateTwitch() }
                await settle { await http.validationEntered }
                if replacement {
                    let newConfiguration = try await vault.configure(.twitch, clientID: "client")
                    try await vault.accept(.init(access: "replacement-access", refresh: "replacement-refresh", expiresAt: Date().addingTimeInterval(3_600)),
                        provider: .twitch, generation: newConfiguration)
                } else { validation.cancel() }
                let stored = memory.string(for: .provider(.twitch, field: .tokens))
                await http.releaseValidation()
                do { try await validation.value; preconditionFailure("Retired validation completed") } catch is CancellationError {}
                check(memory.string(for: .provider(.twitch, field: .tokens)) == stored,
                    "Canceled or replaced Twitch validation mutated current credentials")
                check(await http.allRequests().filter { $0.url?.path == "/oauth2/validate" }.count == 1,
                    "Retired validation sent another request")
            }
        }
        let http = ProviderHTTPFixture(), vault = ProviderTokenVault(keychain: MemoryProviderCredentials(), transport: { try await http.send($0) })
        let configuration = try await vault.configure(.twitch, clientID: "client")
        try await vault.accept(.init(access: "revoked-access", expiresAt: Date().addingTimeInterval(3_600)), provider: .twitch, generation: configuration)
        await http.holdNextValidation(status: 401)
        let rejected = Task { try await vault.validateTwitch() }
        await settle { await http.validationEntered }; await http.releaseValidation()
        do { try await rejected.value; preconditionFailure("Current revoked token passed validation") }
        catch let failure as ProviderFailure { precondition(failure.kind == .authorization) }
        check(await !vault.hasToken(.twitch), "Current validation rejection did not retire the revoked token")
        print("PASS: held Twitch validation 200/401 cannot replace or revoke rotated credentials; current-token retry, canceled/replaced validation fences and real current rejection repair")
    }
    static func sameClientAuthorizationDuringRefresh() async throws {
        for status in [200, 400] {
            let http = ProviderHTTPFixture()
            let vault = ProviderTokenVault(keychain: MemoryProviderCredentials(), transport: { try await http.send($0) })
            let configuration = try await vault.configure(.youtube, clientID: "client")
            try await vault.accept(.init(access: "expired", refresh: "old-refresh", expiresAt: .distantPast, scopes: ManagedProvider.youtube.scopes), provider: .youtube, generation: configuration)
            let previous = await vault.generation(.youtube)
            await http.configure(hold: true, tokenStatus: status)
            let oldRead = Task { try await vault.send(.youtube, request: ProviderAPI.request(.youtube, path: "/youtube/v3/channels")) }
            await settle { await http.refreshEntered }
            let newAuthorization = try await vault.configure(.youtube, clientID: "client")
            check(newAuthorization != previous)
            await http.release()
            do { _ = try await oldRead.value; preconditionFailure("A previous refresh survived same-client reauthorization") }
            catch {}
            check(await vault.hasToken(.youtube), "A previous invalid_grant deleted credentials during new consent")
            check(await vault.generation(.youtube) == newAuthorization, "A previous refresh invalidated new consent's acceptance generation")
            try await vault.accept(.init(access: "new-authorization", expiresAt: Date().addingTimeInterval(3_600), scopes: ManagedProvider.youtube.scopes), provider: .youtube, generation: newAuthorization)
            _ = try await vault.send(.youtube, request: ProviderAPI.request(.youtube, path: "/youtube/v3/channels"))
            let last = await http.allRequests().last!
            precondition(last.value(forHTTPHeaderField: "Authorization") == "Bearer new-authorization")
        }
    }
    @MainActor static func nativeCrossWorkspaceChatAuthority() async throws {
        for replacementClient in ["fixture", "different-client"] {
            let http = ProviderHTTPFixture()
            let vault = ProviderTokenVault(keychain: MemoryProviderCredentials(), transport: { try await http.send($0) })
            let configuration = try await vault.configure(.youtube, clientID: "fixture")
            try await vault.accept(.init(access: "first-account", refresh: "first-refresh", expiresAt: Date().addingTimeInterval(3_600),
                scopes: ManagedProvider.youtube.scopes), provider: .youtube, generation: configuration)
            let first = ProviderAccountSession(restream: FixtureRestream(), vault: vault)
            let second = ProviderAccountSession(restream: FixtureRestream(), vault: vault)
            let unverifiedCount = await http.allRequests().count
            do {
                _ = try await first.chatRequest(.youtube, ProviderAPI.request(.youtube, path: "/youtube/v3/liveChat/messages"))
                preconditionFailure("Chat work bypassed explicit identity verification")
            } catch let failure as ProviderFailure { precondition(failure.kind == .authorization) }
            check(await http.allRequests().count == unverifiedCount)
            check(try await first.chatIdentity(.youtube).channelID == "UC1")
            check(try await second.chatIdentity(.youtube).channelID == "UC1")
            let initialCredential = await vault.generation(.youtube)
            // Ordinary access-token refresh is the same credential generation;
            // both verified readers keep working through the one shared vault.
            await http.configure(hold: true)
            await http.rejectNextAPIReads(2)
            let read = try ProviderAPI.request(.youtube, path: "/youtube/v3/liveChat/messages")
            async let firstRefresh = first.chatRequest(.youtube, read)
            async let secondRefresh = second.chatRequest(.youtube, read)
            await settle {
                let entered = await http.refreshEntered, requests = await http.allRequests()
                return entered && requests.filter { $0.url?.path == "/youtube/v3/liveChat/messages" }.count >= 2
            }
            await http.release()
            _ = try await (firstRefresh, secondRefresh)
            check(await vault.generation(.youtube) == initialCredential)
            check(await http.count(host: "oauth2.googleapis.com") == 1)
            // Simulate another workspace's completed OAuth acceptance using
            // controlled credentials only. No real grant/feed is established.
            let replacement = try await vault.configure(.youtube, clientID: replacementClient)
            try await vault.accept(.init(access: "replacement-account", expiresAt: Date().addingTimeInterval(3_600),
                scopes: ManagedProvider.youtube.scopes), provider: .youtube, generation: replacement)
            await http.setChannelID("UC2")
            check(try await second.chatIdentity(.youtube).channelID == "UC2")
            let before = await http.allRequests().count
            for method in ["GET", "POST", "DELETE"] {
                var stale = read; stale.httpMethod = method
                if method == "POST" { stale.httpBody = Data(#"{"snippet":{"liveChatId":"old-chat"}}"#.utf8) }
                do {
                    _ = try await first.chatRequest(.youtube, stale)
                    preconditionFailure("An old workspace sent future chat work with another account's credential")
                } catch let failure as ProviderFailure { precondition(failure.kind == .authorization) }
            }
            check(await http.allRequests().count == before, "Old reader authority reached the replacement account's HTTP transport")
            precondition(first.snapshot(.youtube).hasCredential && first.snapshot(.youtube).failure == nil,
                         "Retiring old chat authority incorrectly invalidated reusable machine credentials")
            // The healthy peer is unaffected. Explicit identity verification is
            // required before the retired workspace can use the new account.
            _ = try await second.chatRequest(.youtube, read)
            check(try await first.chatIdentity(.youtube).channelID == "UC2")
            _ = try await first.chatRequest(.youtube, read)
            check(await http.allRequests().last?.value(forHTTPHeaderField: "Authorization") == "Bearer replacement-account")
            first.shutdown(); second.shutdown()
        }
        print("PASS: two actual workspace account sessions share one vault; coalesced refresh preserves both verified readers, unverified calls and same/different-client replacement blocks future old GET/POST/DELETE before HTTP until explicit identity verification")
    }
    @MainActor static func nativeChatRevocation() async throws {
        let http = ProviderHTTPFixture()
        let vault = ProviderTokenVault(keychain: MemoryProviderCredentials(), transport: { try await http.send($0) })
        let configuration = try await vault.configure(.youtube, clientID: "fixture")
        try await vault.accept(.init(access: "access", refresh: "revoked-refresh", expiresAt: Date().addingTimeInterval(3_600), scopes: ManagedProvider.youtube.scopes), provider: .youtube, generation: configuration)
        let previous = await vault.generation(.youtube)
        let session = ProviderAccountSession(restream: FixtureRestream(), vault: vault)
        session.refresh(.youtube)
        await settle { await MainActor.run { !session.snapshot(.youtube).isWorking } }
        _ = try await session.chatIdentity(.youtube)
        await http.configure(once401: true, tokenStatus: 400)
        do {
            _ = try await session.chatRequest(.youtube, ProviderAPI.request(.youtube, path: "/youtube/v3/liveChat/messages"))
            preconditionFailure("A revoked refresh grant remained authorized")
        } catch let error as ProviderFailure { precondition(error.kind == .authorization) }
        let failed = session.snapshot(.youtube)
        precondition(!failed.hasCredential && failed.scopes.isEmpty && failed.verifiedAt == nil && failed.failure?.kind == .authorization)
        check(await !vault.hasToken(.youtube))
        check(await vault.revocationGeneration(.youtube, previous: previous) != nil)
        let replacement = try await vault.configure(.youtube, clientID: "fixture")
        try await vault.accept(.init(access: "replacement", expiresAt: Date().addingTimeInterval(3_600), scopes: ManagedProvider.youtube.scopes), provider: .youtube, generation: replacement)
        check(await vault.revocationGeneration(.youtube, previous: previous) == nil)
        session.shutdown()
    }
    @MainActor static func nativeChatLateReplies() async throws {
        for failure in [nil, ProviderFailure(.authorization), ProviderFailure(.rateLimited)] {
            for retirement in ["replacement", "cancellation", "shutdown", "authorization intent"] {
                let http = ProviderHTTPFixture()
                let vault = ProviderTokenVault(keychain: MemoryProviderCredentials(), transport: { try await http.send($0) })
                let initial = try await vault.configure(.youtube, clientID: "fixture")
                try await vault.accept(.init(access: "initial-access", refresh: "initial-refresh", expiresAt: Date().addingTimeInterval(3_600), scopes: ManagedProvider.youtube.scopes), provider: .youtube, generation: initial)
                let authorizedCredential = await vault.generation(.youtube)
                let session = ProviderAccountSession(restream: FixtureRestream(), vault: vault)
                session.refresh(.youtube)
                await settle { await MainActor.run { !session.snapshot(.youtube).isWorking } }
                precondition(session.snapshot(.youtube).hasCredential && session.snapshot(.youtube).failure == nil)
                _ = try await session.chatIdentity(.youtube)
                await http.holdNextChat(failure: failure)
                let oldRead = Task { try await session.chatRequest(.youtube, ProviderAPI.request(.youtube, path: "/youtube/v3/liveChat/messages")) }
                await settle { await http.chatEntered }
                if retirement == "replacement" {
                    let replacement = try await vault.configure(.youtube, clientID: "replacement")
                    try await vault.accept(.init(access: "replacement-access", refresh: "replacement-refresh", expiresAt: Date().addingTimeInterval(3_600), scopes: ManagedProvider.youtube.scopes), provider: .youtube, generation: replacement)
                    session.refresh(.youtube)
                    await settle { await MainActor.run { !session.snapshot(.youtube).isWorking } }
                } else if retirement == "shutdown" { session.shutdown() }
                else if retirement == "authorization intent" {
                    // Invalid new configuration changes session intent without
                    // replacing the actual machine credential generation.
                    session.authorize(.youtube, clientID: "")
                    await settle { await MainActor.run { !session.snapshot(.youtube).isWorking } }
                    check(await vault.generation(.youtube) == authorizedCredential)
                } else { oldRead.cancel() }
                let before = session.snapshot(.youtube), available = session.canRequest(.youtube)
                await http.releaseChat()
                do { _ = try await oldRead.value; preconditionFailure("A retired chat request produced a current receipt") }
                catch is CancellationError {}
                let after = session.snapshot(.youtube)
                precondition(after.hasCredential == before.hasCredential && after.failure == before.failure)
                precondition(after.scopes == before.scopes && after.retryUntil == before.retryUntil && session.canRequest(.youtube) == available)
                check(await http.count(host: "oauth2.googleapis.com") == 0, "An old or cancelled 401 refreshed current credentials")
                session.shutdown()
            }
        }
    }
    @MainActor static func nativeEnding() async throws {
        let http = ProviderEndingHTTPFixture()
        let vault = ProviderTokenVault(keychain: MemoryProviderCredentials(), transport: { try await http.send($0) })
        let generation = try await vault.configure(.youtube, clientID: "fixture")
        try await vault.accept(.init(access: "fixture-access", expiresAt: Date().addingTimeInterval(3_600), scopes: ManagedProvider.youtube.scopes), provider: .youtube, generation: generation)
        let session = ProviderAccountSession(restream: FixtureRestream(), vault: vault)
        let binding = ProviderDestinationBinding(provider: .youtube, channelID: "UC1", eventID: "ending-event")
        let ended = await session.endRemote(binding)
        precondition(ended.confirmsEnd && session.snapshot(.youtube).events.contains { $0.id == "ending-event" && $0.state == .ended })
        let count = await http.count
        let unsupported = await session.endRemote(.init(provider: .twitch, channelID: "42"))
        precondition(unsupported.disposition == .unsupported)
        check(await http.count == count, "Unsupported provider ending reached an API")
        let reviewed = await session.endRemote(binding, reviewOnly: true)
        precondition(reviewed.confirmsEnd && reviewed.disposition == .observed)
        check(await http.posts == 1, "Review retried a remote mutation")
        session.shutdown()
        let readHTTP = ProviderEndingHTTPFixture()
        let readVault = ProviderTokenVault(keychain: MemoryProviderCredentials(), transport: { try await readHTTP.send($0) })
        let readGeneration = try await readVault.configure(.youtube, clientID: "fixture")
        try await readVault.accept(.init(access: "read-only", expiresAt: Date().addingTimeInterval(3_600), scopes: ["https://www.googleapis.com/auth/youtube.readonly"]), provider: .youtube, generation: readGeneration)
        let readSession = ProviderAccountSession(restream: FixtureRestream(), vault: readVault)
        let readReceipt = await readSession.endRemote(binding, reviewOnly: true)
        precondition(readReceipt.disposition == .observed && readReceipt.event?.state == .live)
        let deniedEnd = await readSession.endRemote(binding)
        precondition(deniedEnd.disposition == .blocked && deniedEnd.failure?.kind == .permission)
        check(await readHTTP.posts == 0, "Read-only authorization sent a completion")
        readSession.shutdown()
        let lateHTTP = ProviderEndingHTTPFixture(); await lateHTTP.hold()
        let lateVault = ProviderTokenVault(keychain: MemoryProviderCredentials(), transport: { try await lateHTTP.send($0) })
        let lateGeneration = try await lateVault.configure(.youtube, clientID: "fixture")
        try await lateVault.accept(.init(access: "old-account", expiresAt: Date().addingTimeInterval(3_600), scopes: ManagedProvider.youtube.scopes), provider: .youtube, generation: lateGeneration)
        let lateSession = ProviderAccountSession(restream: FixtureRestream(), vault: lateVault)
        let oldEnd = Task { await lateSession.endRemote(binding) }
        await settle { await lateHTTP.entered }
        lateSession.forget(.youtube)
        await settle { await !lateVault.hasToken(.youtube) }
        await lateHTTP.release()
        let oldResult = await oldEnd.value
        precondition(!oldResult.confirmsEnd && lateSession.snapshot(.youtube).events.isEmpty)
        check(await lateHTTP.posts == 0, "Old-account read was followed by a mutation after logout")
        lateSession.shutdown()
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
    static func persistentRetirementChild(suite: String) async throws {
        precondition(suite.hasPrefix("com.joeblau.Stream.validation.provider-retirement."))
        let credentials = MemoryProviderCredentials()
        let token = ProviderOAuthToken(access: "owned-child-old", expiresAt: .distantFuture)
        let raw = String(decoding: try JSONEncoder().encode(token), as: UTF8.self)
        precondition(credentials.set(raw, for: .provider(.youtube, field: .tokens)))
        let vault = ProviderTokenVault(keychain: credentials, retirement: .persistent(suiteName: suite))
        check(await !vault.hasToken(.youtube), "Fresh process must read the owned durable retirement marker")
        print("Owned retirement marker child-process deny PASS")
    }
    static func persistentRetirement() async throws {
        let suite = "com.joeblau.Stream.validation.provider-retirement." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite); _ = preferences.synchronize() }
        let credentials = MemoryProviderCredentials(), store = ProviderCredentialRetirementStore.persistent(suiteName: suite)
        let vault = ProviderTokenVault(keychain: credentials, retirement: store)
        let initial = try await vault.configure(.youtube, clientID: "owned-client")
        try await vault.accept(.init(access: "owned-persistent-old", expiresAt: .distantFuture), provider: .youtube, generation: initial)
        credentials.fail(deletion: true)
        check(await !vault.disconnect(.youtube))
        check(store.read(.youtube).retired)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = ["--owned-retirement-child", suite]
        try child.run()
        defer {
            if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while child.isRunning, clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        if child.isRunning {
            _ = kill(child.processIdentifier, SIGKILL); child.waitUntilExit()
            preconditionFailure("Owned retirement child exceeded its 10-second deadline")
        }
        child.waitUntilExit()
        precondition(child.terminationReason == .exit && child.terminationStatus == 0)
        // Corrupt metadata fails closed without inspecting any personal secret.
        preferences.set(Data("invalid-owned-marker".utf8), forKey: "providerAccounts.retired.v1.twitch")
        _ = preferences.synchronize()
        precondition(store.read(.twitch).retired)
    }
    static func retirementFailures() async throws {
        for provider in [ManagedProvider.youtube, .twitch] {
            let credentials = MemoryProviderCredentials(), markers = MemoryProviderRetirement(), http = ProviderHTTPFixture()
            let vault = ProviderTokenVault(keychain: credentials, retirement: markers.store, transport: { try await http.send($0) })
            let generation = try await vault.configure(provider, clientID: "client")
            let old = ProviderOAuthToken(access: "old-retirement-fixture", refresh: "refresh", expiresAt: .distantFuture, scopes: ["read"])
            try await vault.accept(old, provider: provider, generation: generation)
            let raw = credentials.string(for: .provider(provider, field: .tokens))
            credentials.fail(deletion: true)
            check(await !vault.disconnect(provider), "Deletion failure must be reported")
            precondition(credentials.string(for: .provider(provider, field: .tokens)) == raw)
            let forgottenScopes = await vault.scopes(provider)
            check(await !vault.hasToken(provider) && forgottenScopes.isEmpty)
            let restarted = ProviderTokenVault(keychain: credentials, retirement: markers.store, transport: { try await http.send($0) })
            check(await !restarted.hasToken(provider), "Persisted retirement must deny retained Keychain tokens in a fresh vault")
            let request = try ProviderAPI.request(provider, path: provider == .youtube ? "/youtube/v3/channels" : "/helix/users")
            do { _ = try await restarted.send(provider, request: request); preconditionFailure("Forgotten token was sent") }
            catch let failure as ProviderFailure { precondition(failure.kind == .authorization) }
            check(await http.allRequests().isEmpty, "Retired authorization cannot issue provider requests")

            // Writing a new grant but failing to clear retirement must never
            // reopen the retained OLD grant in another vault.
            credentials.fail(); markers.fail(activation: true)
            let reconnect = try await vault.configure(provider, clientID: "client")
            do {
                try await vault.accept(.init(access: "new-retirement-fixture", refresh: "new", expiresAt: .distantFuture), provider: provider, generation: reconnect)
                preconditionFailure("Failed marker clear was accepted")
            } catch is ProviderCredentialPersistenceFailure {}
            check(await !vault.hasToken(provider))
            let afterFailedClear = ProviderTokenVault(keychain: credentials, retirement: markers.store)
            check(await !afterFailedClear.hasToken(provider))
            precondition(credentials.string(for: .provider(provider, field: .tokens))?.contains("new-retirement-fixture") == true)
            markers.fail()
            let repaired = try await vault.configure(provider, clientID: "client")
            try await vault.accept(old, provider: provider, generation: repaired)
            let markerBeforeCancel = markers.store.read(provider)
            let canceledGeneration = try await vault.configure(provider, clientID: "client")
            let canceled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await vault.accept(.init(access: "canceled", expiresAt: .distantFuture), provider: provider, generation: canceledGeneration)
            }
            do { try await canceled.value; preconditionFailure("Canceled grant was accepted") } catch is CancellationError {}
            precondition(markers.store.read(provider) == markerBeforeCancel)
            check(await vault.hasToken(provider), "Canceled same-client consent must preserve the existing grant")
            precondition(credentials.string(for: .provider(provider, field: .tokens))?.contains("old-retirement-fixture") == true)

            // Failure to persist the new token leaves the old raw value behind,
            // but the durable deny marker still prevents its reuse.
            credentials.fail(tokenWrite: true)
            let deniedWrite = try await vault.configure(provider, clientID: "client")
            do { try await vault.accept(old, provider: provider, generation: deniedWrite); preconditionFailure("Failed token write accepted") }
            catch is ProviderCredentialPersistenceFailure {}
            check(await !vault.hasToken(provider))
            let afterFailedWrite = ProviderTokenVault(keychain: credentials, retirement: markers.store)
            check(await !afterFailedWrite.hasToken(provider))
            credentials.fail()
            let repair = try await vault.configure(provider, clientID: "client")
            try await vault.accept(old, provider: provider, generation: repair)

            // If ALL storage writes fail, only this running vault can guarantee
            // denial. The returned failure must not claim durable sign-out.
            credentials.fail(deletion: true); markers.fail(retirement: true)
            check(await !vault.disconnect(provider))
            check(await !vault.hasToken(provider))
            let undurable = ProviderTokenVault(keychain: credentials, retirement: markers.store)
            check(await undurable.hasToken(provider), "All-write failure cannot manufacture a durable marker")
            credentials.fail(); markers.fail()
            check(await vault.disconnect(provider))
            let cleaned = ProviderTokenVault(keychain: credentials, retirement: markers.store)
            check(await !cleaned.hasToken(provider))
        }
    }
    static func retirementDuringHeldRefresh() async throws {
        let credentials = MemoryProviderCredentials(), markers = MemoryProviderRetirement(), http = ProviderHTTPFixture()
        let owner = ProviderTokenVault(keychain: credentials, retirement: markers.store, transport: { try await http.send($0) })
        let initial = try await owner.configure(.youtube, clientID: "client")
        try await owner.accept(.init(access: "expired", refresh: "held-old", expiresAt: .distantPast), provider: .youtube, generation: initial)
        let oldContext = ProviderTokenVault(keychain: credentials, retirement: markers.store, transport: { try await http.send($0) })
        await http.configure(hold: true)
        let oldRequest = Task { try await oldContext.send(.youtube, request: ProviderAPI.request(.youtube, path: "/youtube/v3/channels")) }
        await settle { await http.refreshEntered }
        credentials.fail(deletion: true)
        check(await !owner.disconnect(.youtube))
        credentials.fail()
        let next = try await owner.configure(.youtube, clientID: "client")
        try await owner.accept(.init(access: "replacement-after-forget", refresh: "replacement", expiresAt: .distantPast), provider: .youtube, generation: next)
        // Another caller in the old context must create a new refresh using
        // the replacement, rather than joining its old held task under a new
        // marker revision. The old task's eventual cleanup cannot remove it.
        await http.configure(hold: false)
        _ = try await oldContext.send(.youtube, request: ProviderAPI.request(.youtube, path: "/youtube/v3/channels"))
        let refreshRequests = await http.allRequests().filter { $0.url?.host == "oauth2.googleapis.com" }
        precondition(refreshRequests.count == 2)
        precondition(String(decoding: refreshRequests[1].httpBody!, as: UTF8.self).contains("refresh_token=replacement"))
        let replacement = credentials.string(for: .provider(.youtube, field: .tokens))
        await http.release()
        do { _ = try await oldRequest.value; preconditionFailure("Held old refresh restored retired authority") } catch is CancellationError {}
        precondition(credentials.string(for: .provider(.youtube, field: .tokens)) == replacement)
        check(await owner.hasToken(.youtube))
    }
    @MainActor static func nativeForgetStorageFailure() async throws {
        let credentials = MemoryProviderCredentials(), markers = MemoryProviderRetirement(), http = ProviderHTTPFixture()
        let vault = ProviderTokenVault(keychain: credentials, retirement: markers.store, transport: { try await http.send($0) })
        let initial = try await vault.configure(.youtube, clientID: "client")
        try await vault.accept(.init(access: "forget-ui", refresh: "refresh", expiresAt: .distantFuture, scopes: ["read"]), provider: .youtube, generation: initial)
        let session = ProviderAccountSession(restream: FixtureRestream(), vault: vault, transport: { try await http.send($0) })
        defer { session.shutdown() }
        await settle { @MainActor in session.snapshot(.youtube).hasCredential }
        credentials.fail(deletion: true)
        session.forget(.youtube)
        await settle { @MainActor in !session.snapshot(.youtube).isWorking }
        let failed = session.snapshot(.youtube)
        precondition(!failed.hasCredential && failed.scopes.isEmpty && failed.channels.isEmpty && failed.events.isEmpty && failed.verifiedAt == nil)
        precondition(failed.localCredentialFailure?.contains("durable cleanup was not confirmed") == true)
        precondition(!session.canRequest(.youtube))
        credentials.fail()
        session.forget(.youtube)
        await settle { @MainActor in !session.snapshot(.youtube).isWorking }
        precondition(session.snapshot(.youtube).localCredentialFailure == nil && session.canRequest(.youtube))
        check(await !vault.hasToken(.youtube))

        // Cancel stops waiting, not the already-requested local retirement.
        // It must not leave verified channels/grants visible in the panel.
        let reconnected = try await vault.configure(.youtube, clientID: "client")
        try await vault.accept(.init(access: "cancel-forget", refresh: "refresh", expiresAt: .distantFuture, scopes: ["read"]), provider: .youtube, generation: reconnected)
        session.refresh(.youtube)
        await settle { @MainActor in session.snapshot(.youtube).verifiedAt != nil }
        session.forget(.youtube); session.cancel(.youtube)
        let canceled = session.snapshot(.youtube)
        precondition(!canceled.hasCredential && canceled.scopes.isEmpty && canceled.channels.isEmpty && canceled.events.isEmpty && canceled.verifiedAt == nil)
        precondition(canceled.localCredentialFailure?.contains("not been confirmed") == true)
        await settle { await !vault.hasToken(.youtube) }
        session.forget(.youtube)
        await settle { @MainActor in !session.snapshot(.youtube).isWorking }
        precondition(session.snapshot(.youtube).localCredentialFailure == nil)
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
        let discovered = session.snapshot(.youtube).events.first!
        precondition(discovered.latencyPreference == .low && discovered.thumbnails?.count == 1)
        precondition(discovered.thumbnails?.first?.width == 1280 && discovered.thumbnails?.first?.height == 720)
        let metadataBytes = try JSONEncoder().encode(discovered)
        let metadataRoundTrip = try JSONDecoder().decode(ProviderEvent.self, from: metadataBytes)
        precondition(metadataRoundTrip == discovered)
        precondition(!String(decoding: metadataBytes, as: UTF8.self).contains("PRIVATE_METADATA_FIXTURE"))
        // Actual pending disk persistence and portable routing retain repair
        // identities only, even when discovery has public image metadata.
        let pendingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("provider-metadata-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pendingDirectory) }
        let pending = ProviderPendingCatalog(directory: pendingDirectory)
        precondition(pending.retain([ProviderPendingRecord(discovered)]))
        let saved = String(decoding: try Data(contentsOf: pendingDirectory.appendingPathComponent("provider-pending.json")), as: UTF8.self)
        precondition(!saved.contains("ytimg") && !saved.contains("thumbnails") && !saved.contains("latencyPreference") && !saved.contains("PRIVATE_METADATA_FIXTURE"))
        let restored = ProviderPendingCatalog(directory: pendingDirectory).document.records.first!.cachedEvent
        precondition(restored.latencyPreference == nil && restored.thumbnails == nil && restored.state == .unknown)
        let portable = StreamDestination(name: "Discovered", providerBinding: .init(provider: .youtube, channelID: "UC1", eventID: discovered.id))
        let portableBytes = try JSONEncoder().encode(portable), portableText = String(decoding: portableBytes, as: UTF8.self)
        precondition(!portableText.contains("ytimg") && !portableText.contains("thumbnails") && !portableText.contains("PRIVATE_METADATA_FIXTURE"))
        let portableRoundTrip = try JSONDecoder().decode(StreamDestination.self, from: portableBytes)
        precondition(portableRoundTrip.providerBinding?.eventID == "event1")
        check(await http.allRequests().allSatisfy { $0.url?.host != "i.ytimg.com" }, "Discovery downloaded a thumbnail")
        let tokenRequest = await http.allRequests().first { $0.url?.host == "oauth2.googleapis.com" }!
        let fields = URLComponents(string: "https://fixture.invalid/?" + String(decoding: tokenRequest.httpBody!, as: UTF8.self))!.queryItems!
        let verifier = fields.first { $0.name == "code_verifier" }!.value!
        let auth = URLComponents(url: opened!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(ProviderOAuth.challenge(verifier) == auth.first { $0.name == "code_challenge" }!.value)
        session.createYouTube(.init(title: "Created"))
        await settle { await MainActor.run { session.snapshot(.youtube).events.contains { $0.id == "acknowledged-id" } } }
        precondition(session.snapshot(.youtube).events.filter { $0.id == "acknowledged-id" }.count == 1)
        await http.metadata(latency: "ultraLow", thumbnail: "https://i.ytimg.com/vi/event1/refreshed.jpg")
        session.refresh(.youtube)
        await settle { await MainActor.run { !session.snapshot(.youtube).isWorking } }
        precondition(session.snapshot(.youtube).events.contains { $0.id == "acknowledged-id" && $0.state == .unknown }, "An eventual-consistency refresh erased the acknowledged event ID")
        let refreshed = session.snapshot(.youtube).events.first { $0.id == "event1" }!
        precondition(refreshed.latencyPreference == .ultraLow && refreshed.thumbnails?.first?.url.lastPathComponent == "refreshed.jpg")
        await http.metadata(latency: "futureLatency", thumbnail: "https://i.ytimg.com/vi/event1/high.jpg?access_token=PRIVATE_METADATA_FIXTURE")
        session.refresh(.youtube)
        await settle { await MainActor.run { !session.snapshot(.youtube).isWorking } }
        let unsupported = session.snapshot(.youtube).events.first { $0.id == "event1" }!
        precondition(unsupported.latencyPreference == .unknown && unsupported.thumbnails == [] && unsupported.state == .upcoming && session.snapshot(.youtube).failure == nil)
        let observedBinding = ProviderDestinationBinding(provider: .youtube, channelID: "UC1", eventID: "event1")
        session.refreshLive(observedBinding)
        await settle { await MainActor.run { !session.snapshot(.youtube).isWorking } }
        precondition(session.viewerCount(observedBinding) == 23)
        let receipt = session.event(observedBinding)!
        precondition(receipt.isFresh(at: receipt.verifiedAt))
        precondition(session.event(observedBinding, at: receipt.verifiedAt.addingTimeInterval(61)) == nil)
        precondition(session.event(observedBinding, at: receipt.verifiedAt.addingTimeInterval(-1)) == nil)
        precondition(session.eventReceipt(observedBinding)?.publicURL == receipt.publicURL)
        precondition(session.eventReceipt(.init(provider: .youtube, channelID: "foreign-channel", eventID: "event1")) == nil)
        precondition(session.viewerCount(observedBinding, at: receipt.verifiedAt.addingTimeInterval(61)) == nil)
        precondition(!receipt.isFresh(at: receipt.verifiedAt.addingTimeInterval(61)))
        precondition(session.viewerCount(observedBinding, at: receipt.verifiedAt.addingTimeInterval(-1)) == nil)
        // A count returned for another event must invalidate the native receipt.
        await http.setViewerEventID("foreign-event")
        session.refreshLive(observedBinding)
        await settle { await MainActor.run { !session.snapshot(.youtube).isWorking } }
        precondition(session.viewerCount(observedBinding) == nil)
        precondition(session.snapshot(.youtube).verifiedAt == nil && session.snapshot(.youtube).failure?.kind == .invalidResponse)
        await http.setViewerEventID("event1")
        let image = Data([137,80,78,71,13,10,26,10,0])
        session.uploadYouTubeThumbnail(eventID: "event1", channelID: "UC1", image: image, mimeType: "image/png")
        await settle { await MainActor.run { !session.snapshot(.youtube).isWorking } }
        precondition(session.lastThumbnailReceipt?.eventID == "event1" && session.snapshot(.youtube).failure == nil)
        let uploads = await http.allRequests().filter { $0.url?.path == "/upload/youtube/v3/thumbnails/set" }
        precondition(uploads.count == 1 && uploads[0].httpBody == image && uploads[0].value(forHTTPHeaderField: "Authorization") != nil)
        await http.holdNextThumbnail()
        session.uploadYouTubeThumbnail(eventID: "event1", channelID: "UC1", image: image, mimeType: "image/png")
        await settle { await http.thumbnailEntered }
        session.cancel(.youtube)
        await http.releaseThumbnail()
        try await Task.sleep(for: .milliseconds(30))
        precondition(session.lastThumbnailReceipt == nil && !session.snapshot(.youtube).isWorking, "Late upload result revived a cancelled session")
        check(await http.allRequests().filter { $0.url?.path == "/upload/youtube/v3/thumbnails/set" }.count == 2, "Cancelled media upload was replayed")
        var denied = try ProviderAPI.request(.youtube, path: "/upload/youtube/v3/videos")
        denied.httpMethod = "POST"; denied.httpBody = image; denied.setValue("image/png", forHTTPHeaderField: "Content-Type")
        let before = await http.allRequests().count
        do { _ = try await vault.send(.youtube, request: denied); preconditionFailure("Unrelated media upload accepted") }
        catch let failure as ProviderFailure { precondition(failure.kind == .invalidRequest) }
        check(await http.allRequests().count == before)
        session.authorize(.twitch, clientID: "client")
        await settle { await MainActor.run { session.snapshot(.twitch).channels.first?.id == "42" && !session.snapshot(.twitch).isWorking } }
        precondition(session.snapshot(.twitch).scopes.contains("channel:read:stream_key"))
        // A provider failure/cooldown cannot alter the healthy peer account.
        await http.configure(status: 429)
        session.refresh(.youtube)
        await settle { await MainActor.run { !session.snapshot(.youtube).isWorking } }
        precondition(session.snapshot(.youtube).failure?.kind == .rateLimited && !session.canRequest(.youtube))
        precondition(session.snapshot(.twitch).verifiedAt != nil && session.snapshot(.twitch).failure == nil)
        let beforeChatCooldown = await http.count(host: "www.googleapis.com")
        do {
            _ = try await session.chatRequest(.youtube, ProviderAPI.request(.youtube, path: "/youtube/v3/liveChat/messages"))
            preconditionFailure("A chat GET ignored the account cooldown")
        } catch let failure as ProviderFailure {
            precondition(failure.kind == .rateLimited && (failure.retryAfter ?? 0) > 0)
        }
        let afterChatCooldown = await http.count(host: "www.googleapis.com")
        precondition(afterChatCooldown == beforeChatCooldown)
        let calls = await http.count(host: "www.googleapis.com")
        session.refresh(.youtube)
        check(await http.count(host: "www.googleapis.com") == calls, "Cooldown must suppress repeated API reads")
        session.shutdown()
        precondition(session.lastThumbnailReceipt == nil)
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
