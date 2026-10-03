import AVFoundation
import CoreMedia
import Foundation
import StreamCore

extension CMSampleBuffer: @retroactive @unchecked Sendable {}

private final class EndingMemoryCredentials: ProviderCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var hold = false
    private var entered = false
    private let release = DispatchSemaphore(value: 0)
    private func key(_ item: KeychainStore.Item) -> String { String(describing: item) }
    func string(for item: KeychainStore.Item) -> String? {
        let (value, wait) = lock.withLock { () -> (String?, Bool) in
            let wait = hold && key(item) == key(.provider(.youtube, field: .tokens))
            if wait { hold = false; entered = true }
            return (values[key(item)], wait)
        }
        if wait { precondition(release.wait(timeout: .now() + 5) == .success, "Held vault fixture was not released") }
        return value
    }
    func set(_ value: String, for item: KeychainStore.Item) -> Bool { lock.withLock { values[key(item)] = value }; return true }
    func remove(_ item: KeychainStore.Item) { _ = lock.withLock { values.removeValue(forKey: key(item)) } }
    func holdNextRead() { lock.withLock { hold = true; entered = false } }
    var isHeld: Bool { lock.withLock { entered } }
    func resume() { release.signal() }
    var storedToken: String? { lock.withLock { values[key(.provider(.youtube, field: .tokens))] } }
}
private final class EndingAuthorityGate: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    func revoke() { lock.withLock { valid = false } }
    func allows() -> Bool { lock.withLock { valid } }
}
private actor OwnedEndingHTTP {
    private let beforeCompletion: (@Sendable () -> Void)?
    init(beforeCompletion: (@Sendable () -> Void)? = nil) { self.beforeCompletion = beforeCompletion }
    var requests: [URLRequest] = []
    var owner = "owner"
    var lifecycle = "live"
    var status = 200
    var postStatus = 200
    var heldPath: String?
    var entered = false
    var waiter: CheckedContinuation<Void, Never>?
    var refreshReadonly = false
    func configure(owner: String = "owner", lifecycle: String = "live", status: Int = 200, postStatus: Int = 200) {
        self.owner = owner; self.lifecycle = lifecycle; self.status = status; self.postStatus = postStatus
    }
    func hold(_ path: String) { heldPath = path; entered = false }
    func release() { heldPath = nil; waiter?.resume(); waiter = nil }
    func readonlyRefresh() { refreshReadonly = true }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url!.path
        if heldPath == path {
            entered = true
            // Deliberately ignores task cancellation to prove the caller's fence.
            await withCheckedContinuation { waiter = $0 }
        }
        let object: [String: Any], code: Int
        if request.url!.host == "oauth2.googleapis.com" {
            code = 200
            object = ["access_token": "refreshed-fixture", "expires_in": 3_600,
                      "scope": refreshReadonly ? "https://www.googleapis.com/auth/youtube.readonly" : "https://www.googleapis.com/auth/youtube"]
        } else if path == "/youtube/v3/channels" {
            code = status; object = ["items": [["id": owner]]]
        } else {
            let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "id" }!.value!
            let post = request.httpMethod == "POST"
            if !post && path == "/youtube/v3/liveBroadcasts" { beforeCompletion?() }
            code = post ? postStatus : status
            let row: [String: Any] = ["id": id, "snippet": ["channelId": "owner"], "status": ["lifeCycleStatus": post ? "complete" : lifecycle]]
            object = post ? row : ["items": [row]]
        }
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
    var posts: Int { requests.filter { $0.url!.host == "www.googleapis.com" && $0.httpMethod == "POST" }.count }
    var apiRequests: Int { requests.filter { $0.url!.host == "www.googleapis.com" }.count }
    var refreshRequests: Int { requests.filter { $0.url!.host == "oauth2.googleapis.com" }.count }
}
@MainActor private final class OwnedEndingRestream: ProviderRestreamBoundary {
    var hasProviderAuthorization = false
    func signOut() {}
    func authorizedProviderRequest(_ request: URLRequest) async throws -> Data { throw ProviderFailure(.authorization) }
}
private actor OwnedEndingPublisher: Publisher {
    nonisolated let events: AsyncStream<PublisherEvent>
    private let continuation: AsyncStream<PublisherEvent>.Continuation
    var videoCount = 0
    var stops = 0
    init() { (events, continuation) = AsyncStream.makeStream(of: PublisherEvent.self) }
    func start(_ settings: StreamSettings) async throws { continuation.yield(.published) }
    func stop() async { stops += 1; continuation.yield(.stopped) }
    func pause() async {}
    func resume() async {}
    func setOutputSize(_ size: CGSize, nativeShortEdge: Int) async {}
    func appendVideo(_ sample: CMSampleBuffer) async { videoCount += 1 }
    nonisolated func enqueueMic(_ sample: CMSampleBuffer) {}
    nonisolated func enqueueApp(_ sample: CMSampleBuffer) {}
    nonisolated func enqueueProgram(_ sample: CMSampleBuffer) {}
    func setMicVolume(_ value: Double) async {}
    func setThermalCeiling(bitRateScale: Double, frameRateCap: Int) async {}
    func statsSnapshot() async -> LiveStats? { nil }
}
@main private struct OwnedEndingHarness {
    static let binding = ProviderDestinationBinding(provider: .youtube, channelID: "owner", eventID: "event")
    static let writeScope = "https://www.googleapis.com/auth/youtube"
    static let readScope = "https://www.googleapis.com/auth/youtube.readonly"
    static func check(_ value: Bool, _ reason: String) { precondition(value, reason) }
    static func until(_ predicate: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        check(await predicate(), "Owned-ending fixture deadline")
    }
    static func vault(_ http: OwnedEndingHTTP, scopes: [String] = [writeScope], expired: Bool = false,
                      memory: EndingMemoryCredentials = EndingMemoryCredentials()) async throws -> ProviderTokenVault {
        let value = ProviderTokenVault(keychain: memory, transport: { try await http.send($0) })
        let generation = try await value.configure(.youtube, clientID: "fixture")
        try await value.accept(.init(access: "fixture-only", refresh: "fixture-refresh",
                                    expiresAt: expired ? .distantPast : Date().addingTimeInterval(3_600), scopes: scopes), provider: .youtube, generation: generation)
        return value
    }
    @MainActor static func session(_ value: ProviderTokenVault) -> ProviderAccountSession {
        ProviderAccountSession(restream: OwnedEndingRestream(), vault: value,
            transport: { _ in throw ProviderFailure(.unavailable) }, openBrowser: { _ in preconditionFailure("Fixture opened browser") },
            pendingDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ending-catalog-\(UUID())"))
    }
    @MainActor static func main() async throws {
        try await ownedAuthority()
        try await interruptedReads()
        try await sessionIntentAtVaultAdmission()
        try await vaultEntryAndRefresh()
        try await continuingMedia()
        print("Owned ending: fresh mine/exact owner, one explicit POST, scope/401 no replay, intent/credential/actor-entry/late fences, healthy outputs and decoded independent recording PASS")
    }
    @MainActor static func ownedAuthority() async throws {
        let foreign = OwnedEndingHTTP(); await foreign.configure(owner: "foreign")
        let foreignSession = session(try await vault(foreign))
        let result = await foreignSession.endRemote(binding)
        check(result.disposition == .blocked && result.failure?.kind == .permission, "Foreign account was authorized by public metadata")
        check(await foreign.apiRequests == 1, "Foreign account sent event lookup"); check(await foreign.posts == 0, "Foreign account sent POST")
        foreignSession.shutdown()
        let read = OwnedEndingHTTP(), readSession = session(try await vault(read, scopes: [readScope]))
        check(await readSession.endRemote(binding).failure?.kind == .permission, "Read-only grant sent ending")
        check(await read.apiRequests == 0, "Missing write grant reached API")
        check(await readSession.endRemote(binding, reviewOnly: true).disposition == .observed, "Owned read-only review failed")
        check(await read.posts == 0, "Review-only sent POST"); readSession.shutdown()
        for status in [401, 403, 503] {
            let http = OwnedEndingHTTP(); await http.configure(status: status)
            let value = session(try await vault(http))
            check(await value.endRemote(binding).disposition == .blocked, "Failed ownership read attempted ending")
            check(await http.apiRequests == 1, "Fresh review replayed after error"); check(await http.posts == 0, "Failed read sent POST"); check(await http.refreshRequests == 0, "Fresh review refreshed after rejection")
            value.shutdown()
        }
        let http = OwnedEndingHTTP(); await http.configure(postStatus: 401)
        let value = session(try await vault(http))
        check(await value.endRemote(binding).disposition == .unconfirmed, "Rejected POST fabricated completion")
        check(await http.posts == 1, "Destructive request retried"); check(await http.refreshRequests == 0, "Destructive request refreshed")
        value.shutdown()
        let ended = OwnedEndingHTTP(); await ended.configure(lifecycle: "complete")
        let endedSession = session(try await vault(ended))
        check(await endedSession.endRemote(binding).disposition == .alreadyEnded, "Fresh ended event was not recognized")
        check(await ended.posts == 0, "Already-ended event sent POST"); endedSession.shutdown()
        print("PASS current-owner/scope/error/already-ended receipts send no unauthorized or repeated completion")
    }
    @MainActor static func interruptedReads() async throws {
        for action in ["authorize", "forget", "shutdown", "replacement", "cancel"] {
            let http = OwnedEndingHTTP(); await http.hold("/youtube/v3/liveBroadcasts")
            let value = try await vault(http), account = session(value)
            let before = await value.generation(.youtube)
            let job = Task { await account.endRemote(binding) }
            try await until { await http.entered }
            switch action {
            case "authorize": account.authorize(.youtube, clientID: "") // invalid client: intent changes, token does not
            case "forget": account.forget(.youtube)
            case "shutdown": account.shutdown() // intent only; machine credential stays reusable
            case "replacement":
                try await value.accept(.init(access: "replacement-fixture", expiresAt: Date().addingTimeInterval(3_600), scopes: [writeScope]), provider: .youtube, generation: before)
            default: job.cancel()
            }
            if ["authorize", "shutdown"].contains(action) {
                check(await value.generation(.youtube) == before, "Intent-only fixture accidentally changed credential")
            }
            await http.release()
            let receipt = await job.value
            check(!receipt.confirmsEnd && receipt.event == nil, "Late noncooperative read accepted after \(action)")
            check(await http.posts == 0, "Late read sent POST after \(action)")
            if action == "shutdown" {
                let count = await http.apiRequests
                check(await account.endRemote(binding).disposition == .blocked, "Closed account allowed end")
                check(await http.apiRequests == count, "Closed account reached API")
            }
            account.shutdown()
        }
        let sent = OwnedEndingHTTP(); await sent.hold("/youtube/v3/liveBroadcasts/transition")
        let sentAccount = session(try await vault(sent))
        let sentJob = Task { await sentAccount.endRemote(binding) }
        try await until { await sent.entered }
        sentAccount.shutdown(); await sent.release()
        let sentReceipt = await sentJob.value
        check(sentReceipt.disposition == .unconfirmed && !sentReceipt.confirmsEnd && sentReceipt.event == nil,
              "Already-sent uncooperative response survived account shutdown")
        check(await sent.posts == 1, "Unconfirmed sent request was replayed")
        print("PASS replacement/forget/closed/intent-only authorization and cancellation reject held late reads with zero POST")
    }
    static func vaultEntryAndRefresh() async throws {
        let memory = EndingMemoryCredentials(), http = OwnedEndingHTTP(), gate = EndingAuthorityGate()
        let value = try await vault(http, memory: memory), captured = await value.generation(.youtube)
        var draft = try ProviderAPI.request(.youtube, path: "/youtube/v3/liveBroadcasts/transition", query: ["id": "event", "broadcastStatus": "complete"])
        draft.httpMethod = "POST"
        let post = draft
        memory.holdNextRead()
        let occupied = Task { await value.scopes(.youtube) }
        try await until { memory.isHeld }
        let queued = Task { try await value.send(.youtube, request: post, expectedGeneration: captured,
                                                retryAuthorizedGET: false, authorizationIsCurrent: gate.allows) }
        gate.revoke(); memory.resume(); _ = await occupied.value
        do { _ = try await queued.value; preconditionFailure("Queued revoked intent reached transport") } catch {}
        check(await http.posts == 0, "Actor-entry gate allowed POST"); check(await value.generation(.youtube) == captured, "Actor-entry fixture changed credential")
        try await value.accept(.init(access: "replacement-fixture", expiresAt: Date().addingTimeInterval(3_600), scopes: [writeScope]), provider: .youtube, generation: captured)
        do { _ = try await value.send(.youtube, request: post, expectedGeneration: captured, retryAuthorizedGET: false); preconditionFailure("Stale captured credential entered HTTP under replacement token") }
        catch let failure as ProviderFailure { check(failure.kind == .authorization, "Stale actor-entry generation did not reject authorization") }
        check(await http.posts == 0, "Stale credential generation sent POST")
        let refresh = OwnedEndingHTTP(); await refresh.hold("/token")
        let refreshValue = try await vault(refresh, expired: true), refreshedGate = EndingAuthorityGate()
        let refreshGeneration = await refreshValue.generation(.youtube)
        let refreshing = Task { try await refreshValue.send(.youtube, request: post, expectedGeneration: refreshGeneration,
            retryAuthorizedGET: false, authorizationIsCurrent: refreshedGate.allows, requiredAnyScope: [writeScope]) }
        try await until { await refresh.entered }; refreshedGate.revoke(); await refresh.release()
        do { _ = try await refreshing.value; preconditionFailure("Refresh completed into revoked intent") } catch {}
        check(await refresh.apiRequests == 0, "Revoked intent sent API request after refresh")
        let scoped = OwnedEndingHTTP(); await scoped.readonlyRefresh()
        let scopedValue = try await vault(scoped, expired: true)
        do { _ = try await scopedValue.send(.youtube, request: post, retryAuthorizedGET: false, requiredAnyScope: [writeScope]); preconditionFailure("Refresh lost write grant but sent POST") }
        catch let failure as ProviderFailure { check(failure.kind == .permission, "Lost scope did not fail permission") }
        check(await scoped.posts == 0, "Read-only refreshed token sent POST")
        print("PASS unchanged-token intent revocation at queued vault entry and after refresh; refreshed readonly grant sends zero POST")
    }
    @MainActor static func sessionIntentAtVaultAdmission() async throws {
        for action in ["authorize", "forget", "shutdown"] {
            let memory = EndingMemoryCredentials()
            let http = OwnedEndingHTTP(beforeCompletion: { memory.holdNextRead() })
            let value = try await vault(http, memory: memory), account = session(value)
            try await until { await MainActor.run { account.snapshot(.youtube).clientID == "fixture" && account.snapshot(.youtube).hasCredential } }
            let unchanged = memory.storedToken
            let job = Task { await account.endRemote(binding) }
            // Both fresh GETs finished. The actual vault has begun admitting
            // the completion but its synchronous credential read is held.
            try await until { memory.isHeld }
            switch action {
            case "authorize": account.authorize(.youtube, clientID: "")
            case "forget": account.forget(.youtube)
            default: account.shutdown()
            }
            check(memory.storedToken == unchanged, "Intent-only admission fixture changed token before lease invalidation")
            memory.resume()
            let receipt = await job.value
            check(!receipt.confirmsEnd && receipt.event == nil, "Intent invalidation during actual vault admission accepted completion")
            check(await http.posts == 0, "Actual Session intent invalidation at vault admission sent POST for \(action)")
            account.shutdown()
        }
        print("PASS actual Session authorize/forget/shutdown intent invalidates admitted-but-held completion while stored token is unchanged; zero POST")
    }
    @MainActor static func continuingMedia() async throws {
        let http = OwnedEndingHTTP(), account = session(try await vault(http))
        let first = OwnedEndingPublisher(), healthy = OwnedEndingPublisher()
        var pool = [first, healthy]
        let outputs = DestinationOutputController(factory: { _ in pool.removeFirst() })
        let a = StreamDestination(name: "Explicit end", providerBinding: binding), b = StreamDestination(name: "Healthy peer")
        outputs.start(a, settings: StreamSettings()); outputs.start(b, settings: StreamSettings())
        try await until { await MainActor.run { outputs.liveCount == 2 } }
        let healthyToken = outputs.sessionToken(b.id)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("owned-ending-media-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var config = ProgramRecordingSession.Configuration(); config.frameRate = 60
        // Retain this bounded one-second workload during cold codec startup;
        // this fixture qualifies ending isolation rather than encoder cadence.
        config.videoCapacity = 60
        let recording = ProgramRecordingSession(outputURL: folder.appendingPathComponent("program.mp4"), configuration: config)
        for frame in 0..<60 {
            if frame == 20 {
                let receipt = await account.endRemote(binding)
                check(receipt.disposition == .ended && receipt.confirmsEnd, "Explicit same-owner end was not acknowledged")
                check(outputs.liveCount == 2 && outputs.sessionToken(b.id) == healthyToken, "Remote ending touched live publisher state")
            }
            if frame == 40 {
                let stopped = await outputs.stopIfCurrent(a.id, token: outputs.sessionToken(a.id)!)
                check(stopped == .stopped && outputs.states[b.id] == .live, "Independent local stop touched healthy peer")
            }
            let sample = try ProgramRecordingFixtures.video(at: Double(frame) / 60)
            outputs.fanout.enqueueVideo(sample); recording.appendVideo(sample)
            if frame % 3 == 0 {
                for chunk in 0..<5 { recording.appendAudio(try ProgramRecordingFixtures.audio(at: Double(frame) / 60 + Double(chunk) / 100)) }
            }
            try await Task.sleep(for: .milliseconds(17))
        }
        let result = await withCheckedContinuation { continuation in recording.finish { continuation.resume(returning: $0) } }
        check(result.completed && result.progress.videoSamples == 60 && result.progress.audioSamples == 100, "Ending interrupted actual recording writer: \(result.progress)")
        try await ProgramRecordingFixtures.inspect(result.url, expectedDuration: 1, checkSync: true)
        check(await http.posts == 1, "Explicit ending sent more than one mutation")
        check(await first.stops == 1, "Independent stop missing"); check(await healthy.stops == 0, "Ending stopped healthy publisher")
        try await until { await healthy.videoCount == 60 }
        outputs.stopAll(); account.shutdown()
        print("PASS one explicit owned completion; healthy peer receives all 60 frames with no stop; actual recording accepts 60 video/100 audio inputs and its one-second H264/AAC file decodes across both actions")
    }
}
