import AVFoundation
import Foundation
import Network
import Security
import StreamCore

private final class StartMemoryTokens: ProviderCredentialStore, @unchecked Sendable {
    private let lock = NSLock(); private var values: [String: String] = [:]
    func string(for item: KeychainStore.Item) -> String? { lock.lock(); defer { lock.unlock() }; return values[String(reflecting: item)] }
    func set(_ value: String, for item: KeychainStore.Item) -> Bool { lock.lock(); defer { lock.unlock() }; values[String(reflecting: item)] = value; return true }
    func remove(_ item: KeychainStore.Item) { lock.lock(); defer { lock.unlock() }; values[String(reflecting: item)] = nil }
}
@MainActor private final class StartNoRestream: ProviderRestreamBoundary {
    var hasProviderAuthorization: Bool { false }
    func signOut() {}
    func authorizedProviderRequest(_ request: URLRequest) async throws -> Data { throw ProviderFailure(.unavailable) }
}
private actor StartWireProvider {
    var count = 0; var heldAt: Int?; var entered = false
    var gate: CheckedContinuation<Void, Never>?
    var holdStreams = false
    var gates: [CheckedContinuation<Void, Never>] = []
    var activeHeld = 0; var maximumHeld = 0
    func holdNextStream() { heldAt = count + 3; entered = false }
    func release() { gate?.resume(); gate = nil; heldAt = nil }
    func holdAllStreams() { holdStreams = true; maximumHeld = 0 }
    func releaseAll() {
        holdStreams = false
        let pending = gates; gates.removeAll()
        for continuation in pending { continuation.resume() }
    }
    func occupancy() -> (active: Int, maximum: Int) { (activeHeld, maximumHeld) }
    func isHeld() -> Bool { entered }
    func calls() -> Int { count }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        guard request.httpMethod == "GET", request.url?.host == "www.googleapis.com", request.timeoutInterval == 10 else { throw ProviderFailure(.invalidRequest) }
        if count == heldAt { entered = true; await withCheckedContinuation { gate = $0 } }
        if holdStreams && request.url?.path == "/youtube/v3/liveStreams" {
            activeHeld += 1; maximumHeld = max(maximumHeld, activeHeld)
            // Intentionally ignores cancellation to prove actual transport
            // occupancy rather than only the visible review-entry count.
            await withCheckedContinuation { gates.append($0) }
            activeHeld -= 1
        }
        let row: [String: Any]
        switch request.url?.path {
        case "/youtube/v3/channels": row = ["id": "owner"]
        case "/youtube/v3/liveBroadcasts":
            row = ["id": "event", "snippet": ["channelId": "owner", "title": "Future private event", "scheduledStartTime": "2030-10-03T12:00:00Z"],
                "status": ["lifeCycleStatus": "ready", "privacyStatus": "private"],
                "contentDetails": ["boundStreamId": "stream", "enableAutoStart": true, "enableAutoStop": false]]
        case "/youtube/v3/liveStreams":
            row = ["id": "stream", "snippet": ["channelId": "owner"], "status": ["streamStatus": "ready"],
                "cdn": ["ingestionType": "rtmp", "resolution": "variable", "frameRate": "variable",
                    "ingestionInfo": ["rtmpsIngestionAddress": "rtmps://a.rtmps.youtube.com/live2", "streamName": "FRESH_PRIVATE_FIXTURE_KEY"]]]
        default: throw ProviderFailure(.invalidRequest)
        }
        return (try JSONSerialization.data(withJSONObject: ["items": [row]]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
    }
}
private actor StartPublisherProbe: Publisher {
    nonisolated let events: AsyncStream<PublisherEvent>
    private nonisolated let continuation: AsyncStream<PublisherEvent>.Continuation
    private(set) var receivedFreshKey = false
    init() { (events, continuation) = AsyncStream.makeStream(of: PublisherEvent.self) }
    func start(_ settings: StreamSettings) async throws { receivedFreshKey = settings.streamKey == "FRESH_PRIVATE_FIXTURE_KEY"; continuation.yield(.connecting) }
    func stop() async { continuation.yield(.stopped) }
    func pause() async {}; func resume() async {}
    func setOutputSize(_ size: CGSize, nativeShortEdge: Int) async {}
    func appendVideo(_ sb: CMSampleBuffer) async {}
    nonisolated func enqueueMic(_ sb: CMSampleBuffer) {}; nonisolated func enqueueApp(_ sb: CMSampleBuffer) {}; nonisolated func enqueueProgram(_ sb: CMSampleBuffer) {}
    func setMicVolume(_ volume: Double) async {}
    func setThermalCeiling(bitRateScale: Double, frameRateCap: Int) async {}
    func statsSnapshot() async -> LiveStats? { nil }
}
@MainActor private final class StartMemoryPairing: StudioControlCredentials {
    var tokens: [UUID: String] = [:]
    func read(_ id: UUID) -> String? { tokens[id] }
    func write(_ token: String, for id: UUID) -> OSStatus { tokens[id] = token; return errSecSuccess }
    func delete(_ id: UUID) -> OSStatus { tokens[id] = nil; return errSecSuccess }
}
@MainActor private final class StartLocalClient {
    let connection: NWConnection
    var buffer = StudioControlFrameBuffer(); var frames: [StudioControlResponse] = []
    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: .global())
    }
    func request(_ request: StudioControlRequest) async throws -> StudioControlResponse {
        var bytes = try JSONEncoder().encode(request); bytes.append(10)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
        while true {
            while frames.isEmpty {
                let data: Data = try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let data, !data.isEmpty { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: ProviderFailure(.unavailable)) }
                    }
                }
                frames += try buffer.append(data).map { try JSONDecoder().decode(StudioControlResponse.self, from: $0) }
            }
            let response = frames.removeFirst(); if response.id == request.id { return response }
        }
    }
}
@main @MainActor struct ManagedStartControllerHarness {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw NSError(domain: "ManagedStartControllerHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<1500 { if ready() { return }; try await Task.sleep(for: .milliseconds(2)) }
        try check(false, "Fixture state timed out")
    }
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stream-managed-controller-\(UUID())")
        try DesktopStorage.prepare(folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let scene = Scene(name: "No capture sources", layers: [], background: .solid(colorHex: "#174A69"))
        try JSONEncoder().encode(SceneDocument(sources: [], scenes: [scene], selectedID: scene.id)).write(to: folder.appendingPathComponent("stream.scenes.v2.json"))
        let destination = StreamDestination(name: "Managed YouTube", providerBinding: .init(provider: .youtube, channelID: "owner", eventID: "event"))
        try JSONEncoder().encode([destination]).write(to: folder.appendingPathComponent("destinations.json"))
        var settings = StreamSettings.default; settings.outputProfile = .init(canvasWidth: 320, canvasHeight: 180, frameRate: 30); settings.micVolume = 0; settings.audioInputs = []
        DesktopSettingsStore().saveNonSecret(settings)
        let tokens = StartMemoryTokens(), provider = StartWireProvider()
        let vault = ProviderTokenVault(keychain: tokens, transport: { try await provider.send($0) })
        let credential = try await vault.configure(.youtube, clientID: "fixture-client")
        try await vault.accept(.init(access: "MEMORY_ONLY_TOKEN", expiresAt: Date().addingTimeInterval(3600), scopes: ["https://www.googleapis.com/auth/youtube.readonly"]), provider: .youtube, generation: credential)
        let accounts = ProviderAccountSession(restream: StartNoRestream(), vault: vault, transport: { try await provider.send($0) }, openBrowser: { _ in false }, pendingDirectory: folder)
        let scenes = SceneStore(), preview = PreviewProgramModel(selected: scenes.selected)
        var allocations: [StartPublisherProbe] = []
        let controller = StreamController(sceneStore: scenes, previewProgram: preview, permissions: PermissionsManager(), publisherFactory: { _ in
            let probe = StartPublisherProbe(); allocations.append(probe); return probe
        })
        let suite = "stream.managed-controller.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); accounts.shutdown(); controller.shutdownManagedStart(); controller.stopStream(); controller.stopPreview(); scenes.flushPendingWrites() }
        let recorder = RecordingController(defaults: defaults, defaultDirectory: folder.appendingPathComponent("recordings"))
        let session = SettingsSession(controller: controller)
        let dispatcher = StudioCommandDispatcher(controller: controller, sceneStore: scenes, session: session, recorder: recorder, previewProgram: preview)
        controller.bindManagedStart(accounts: accounts)
        let coordinator = controller.managedStart!
        func reviewed() async throws { try await wait { coordinator.entries.first?.phase == .review } }
        func noAllocation(_ message: String) throws { try check(allocations.isEmpty && controller.activePublishingEncoderCount == 0 && !controller.streamState.isLive, message) }

        // Shipping toolbar, per-target, retry, palette and typed adapter action.
        controller.goLive(); try await reviewed(); try noAllocation("Toolbar allocated before review")
        controller.stopDestination(destination.id); try check(!controller.managedStartHasEntries, "Per-target stop did not cancel review")
        controller.startDestination(destination.id); try await reviewed(); try noAllocation("Per-target bypass")
        controller.stopStream(); controller.retryDestination(destination.id); try await reviewed(); try noAllocation("Retry bypass")
        controller.stopStream()
        let palette = dispatcher.catalogueActions().first { $0.id == "output.stream.start" }!
        try check(dispatcher.execute(palette.command!).error == nil, "Palette start rejected")
        try await reviewed(); try noAllocation("Palette bypass")
        controller.stopStream()
        let target = dispatcher.controllerTargets().first { $0.id == "output.stream.start" }!
        try check(target.execute(nil) == nil, "Typed adapter command rejected")
        try await reviewed(); try noAllocation("Typed adapter bypass")
        controller.stopStream()

        // The actual loopback server routes an authenticated controller command
        // through the production dispatcher/controller, never a studio double.
        let pairing = StudioControlPairingStore(url: folder.appendingPathComponent("pairs.json"), credentials: StartMemoryPairing())
        pairing.pair(name: "Managed-start fixture adapter")
        let pair = pairing.pairing!
        let server = StudioLocalControlServer(defaults: defaults, pairingStore: pairing, port: 0)
        server.bind(to: dispatcher); server.setEnabled(true)
        defer { server.shutdown() }
        try await wait { server.listeningPort != nil }
        let client = StartLocalClient(port: server.listeningPort!)
        defer { client.connection.cancel() }
        let auth = try await client.request(.init(type: .authenticate, id: UUID(), clientID: pair.id, token: pair.token))
        let response = try await client.request(.init(type: .command, id: UUID(), sessionID: auth.sessionID!, commandID: "output.stream.start"))
        try check(response.result?.succeeded == true, "Actual paired adapter command rejected")
        try await reviewed(); try noAllocation("Authenticated adapter allocated before native review")
        controller.stopStream()

        // Full current settings and destination identities are captured. A
        // review cannot silently adapt to subsequent edits at confirmation.
        for edit in 0..<2 {
            controller.startDestination(destination.id); try await reviewed()
            if edit == 0 {
                var changed = settings; changed.micVolume = 0.5; DesktopSettingsStore().saveNonSecret(changed)
            } else {
                controller.destinations.draft[0].name = "Renamed while reviewing"
                try check(controller.destinations.apply(), "Fixture destination edit")
            }
            coordinator.confirm(destination.id, consent: .init(reviewedPublicEffect: true, startBeforeScheduledTime: true))
            try await wait { coordinator.entries.first?.phase == .blocked }; try noAllocation("Stale settings/destination bypass")
            controller.stopStream(); DesktopSettingsStore().saveNonSecret(settings)
        }
        // Actual rehearsal ownership cancels the pending review before the
        // countdown/writer can yield; direct and dispatcher starts stay blocked.
        controller.startDestination(destination.id); try await reviewed()
        recorder.preferences.countdownSeconds = 60
        controller.beginLocalRehearsal(recorder: recorder)
        try check(controller.isRehearsing && coordinator.entries.isEmpty, "Rehearsal did not cancel managed review")
        controller.startDestination(destination.id)
        try check(dispatcher.execute(.startStream).error != nil, "Rehearsal dispatcher gate bypass")
        try noAllocation("Rehearsal allocated publisher")
        controller.endLocalRehearsal(recorder: recorder); try await wait { !controller.isRehearsing }

        // Reservation changes after a review are evaluated at the actual
        // synchronous factory entry, with freshly validated ephemeral keys.
        controller.startDestination(destination.id); try await reviewed()
        controller.maximumPublishingEncoders = { 0 }
        coordinator.confirm(destination.id, consent: .init(reviewedPublicEffect: true, startBeforeScheduledTime: true))
        try await wait { coordinator.entries.first?.phase == .blocked }; try noAllocation("Recording budget change allocated a publisher")
        try check(controller.errorMessage?.contains("budget reserved") == true, "Actual budget refusal missing")
        controller.stopStream(); controller.maximumPublishingEncoders = { nil }
        controller.startDestination(destination.id); try await reviewed()
        let reservation = UUID()
        try check(controller.reserveRecordingEncoders(reservation, count: 4, canvas: .program) == nil, "Aggregate reservation fixture")
        coordinator.confirm(destination.id, consent: .init(reviewedPublicEffect: true, startBeforeScheduledTime: true))
        try await wait { coordinator.entries.first?.phase == .blocked }; try noAllocation("Aggregate ledger bypass")
        controller.releaseRecordingEncoders(reservation); controller.stopStream()

        // Cancelling UI entries must not free reservations for transport reads
        // that ignore cancellation. Repeated starts cannot enter an 11th read.
        try await wait { coordinator.occupiedAttemptCount == 0 }
        await provider.holdAllStreams()
        for expected in 1...10 {
            controller.startDestination(destination.id)
            for _ in 0..<500 { if await provider.occupancy().active == expected { break }; try await Task.sleep(for: .milliseconds(2)) }
            let occupancy = await provider.occupancy()
            try check(occupancy.active == expected && coordinator.occupiedAttemptCount == expected, "Cancelled reads released an occupied reservation")
            controller.stopStream()
        }
        let beforeSaturation = await provider.calls()
        controller.startDestination(destination.id)
        try check(coordinator.entries.first?.phase == .blocked && coordinator.entries.first?.message?.contains("still finishing") == true, "Saturation did not explain retained provider reads")
        for _ in 0..<5 { coordinator.reviewAgain(destination.id) }
        // A new coordinator also observes occupied reads in retired graphs.
        let blockedContext = ManagedYouTubeStartContext(destination: controller.destinations.saved[0], settings: settings)
        let replacement = ManagedYouTubeStartCoordinator(generation: { await accounts.recoveryAuthorizationGeneration() },
            read: { try await accounts.managedReadRequest($0, expectedGeneration: $1) }, current: { _ in blockedContext },
            publish: { _, _ in allocations.append(StartPublisherProbe()); return true })
        replacement.request(blockedContext)
        try check(replacement.entries.first?.phase == .blocked, "Another runtime bypassed the global occupied-read limit")
        replacement.shutdown()
        try await Task.sleep(for: .milliseconds(30))
        let saturatedCalls = await provider.calls(), saturated = await provider.occupancy()
        try check(saturatedCalls == beforeSaturation && saturated.active == 10 && saturated.maximum == 10, "Held provider transport occupancy exceeded 10")
        try noAllocation("Saturated cancelled reads allocated a publisher")
        controller.stopStream(); await provider.releaseAll()
        try await wait { coordinator.occupiedAttemptCount == 0 }
        let drained = await provider.occupancy()
        try check(drained.active == 0 && coordinator.entries.isEmpty, "Late held reads did not clean up without reviving review")
        try noAllocation("Late cancelled transport replies allocated a publisher")

        // A successful deliberate confirmation alone reaches the real factory,
        // and the adapter receives the freshly read key, not a saved draft key.
        controller.startDestination(destination.id); try await reviewed()
        coordinator.confirm(destination.id, consent: .init(reviewedPublicEffect: true))
        try noAllocation("Future event bypassed early confirmation")
        coordinator.confirm(destination.id, consent: .init(reviewedPublicEffect: true, startBeforeScheduledTime: true))
        try await wait { allocations.count == 1 }
        for _ in 0..<500 { if await allocations[0].receivedFreshKey { break }; try await Task.sleep(for: .milliseconds(2)) }
        let freshKey = await allocations[0].receivedFreshKey
        try check(freshKey, "Factory did not receive freshly verified key")
        coordinator.confirm(destination.id, consent: .init(reviewedPublicEffect: true, startBeforeScheduledTime: true))
        try check(allocations.count == 1, "One-use factory handoff replayed")
        controller.stopStream(); try await wait { !controller.streamState.isActive }
        await provider.holdNextStream(); controller.startDestination(destination.id)
        for _ in 0..<500 { if await provider.isHeld() { break }; try await Task.sleep(for: .milliseconds(2)) }
        let held = await provider.isHeld()
        try check(held, "Late credential fixture did not enter")
        controller.shutdownManagedStart(); await provider.release(); try await Task.sleep(for: .milliseconds(20))
        controller.startDestination(destination.id)
        try check(allocations.count == 1 && coordinator.entries.isEmpty, "Retired runtime revived managed output")
        print("PASS: shipping managed toolbar/per-target/retry/palette/typed and authenticated loopback adapter gates; settings/rehearsal/ledger/global actual held-read bound/late cleanup/one-use fresh-key/retired-runtime rejection")
    }
}
