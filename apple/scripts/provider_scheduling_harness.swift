import Foundation
import StreamCore

private final class SchedulingCredentials: ProviderCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(for item: KeychainStore.Item) -> String? { lock.withLock { values[String(reflecting: item)] } }
    func set(_ value: String, for item: KeychainStore.Item) -> Bool { lock.withLock { values[String(reflecting: item)] = value }; return true }
    func remove(_ item: KeychainStore.Item) { _ = lock.withLock { values.removeValue(forKey: String(reflecting: item)) } }
}
@MainActor private final class SchedulingRestream: ProviderRestreamBoundary {
    var hasProviderAuthorization = false
    func signOut() {}
    func authorizedProviderRequest(_ request: URLRequest) async throws -> Data { throw ProviderFailure(.unavailable) }
}
private actor SchedulingHTTP {
    var calls: [URLRequest] = []
    var bound: String?
    var bindingFails = false
    var holdCreate = false
    var createEntered = false
    var createGate: CheckedContinuation<Void, Never>?
    var hideUpcoming = false
    var createdStreamCount = 0
    func configure(failBind: Bool = false, holdCreate: Bool = false, hideUpcoming: Bool = false) {
        bindingFails = failBind; self.holdCreate = holdCreate; self.hideUpcoming = hideUpcoming; createEntered = false
    }
    func releaseCreate() { holdCreate = false; createGate?.resume(); createGate = nil }
    func requests() -> [URLRequest] { calls }
    func send(_ call: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls.append(call)
        let path = call.url!.path, method = call.httpMethod ?? "GET"
        let query = URLComponents(url: call.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var object: [String: Any], status = 200
        if path == "/youtube/v3/channels" { object = ["items": [["id": "owner", "snippet": ["title": "Owner"]]]] }
        else if path == "/youtube/v3/liveStreams" {
            if method == "POST", holdCreate { createEntered = true; await withCheckedContinuation { createGate = $0 } }
            if method == "POST" { createdStreamCount += 1 }
            let streamID = method == "POST" ? (createdStreamCount == 1 ? "created-stream" : "created-stream-\(createdStreamCount)") :
                (query.first { $0.name == "id" }?.value ?? "created-stream")
            let stream: [String: Any] = ["id": streamID, "snippet": ["channelId": "owner", "title": "Actual stream"],
                "status": ["streamStatus": "ready"], "contentDetails": ["isReusable": false],
                "cdn": ["ingestionType": "rtmp", "resolution": "variable", "frameRate": "variable",
                        "ingestionInfo": ["streamName": "SECRET_KEY", "ingestionAddress": "rtmp://private.example/SECRET_ENDPOINT"]]]
            object = method == "POST" ? stream : ["items": [stream]]
        } else if path == "/youtube/v3/liveBroadcasts/bind" {
            if bindingFails { status = 503; object = ["error": ["message": "SECRET_UNCERTAIN"]] }
            else { bound = query.first { $0.name == "streamId" }?.value; object = event() }
        } else if path == "/youtube/v3/liveBroadcasts" {
            object = method == "POST" ? event() : ["items": hideUpcoming && !query.contains(where: { $0.name == "id" }) ? [] : [event()]]
        } else if path == "/youtube/v3/videos" { object = ["items": []] }
        else { throw ProviderFailure(.invalidRequest) }
        return (try JSONSerialization.data(withJSONObject: object),
            HTTPURLResponse(url: call.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    private func event() -> [String: Any] {
        var details: [String: Any] = ["enableAutoStart": false, "enableAutoStop": false]
        if let bound { details["boundStreamId"] = bound }
        return ["id": "created-event", "snippet": ["channelId": "owner", "title": "Actual event"],
            "status": ["lifeCycleStatus": "ready", "privacyStatus": "private"], "contentDetails": details]
    }
}

@main struct ProviderSchedulingHarness {
    @MainActor static func check(_ value: Bool) { precondition(value) }
    @MainActor static func until(_ predicate: () async -> Bool) async {
        for _ in 0..<1000 { if await predicate() { return }; try? await Task.sleep(for: .milliseconds(2)) }
        preconditionFailure("Native scheduling fixture did not settle")
    }
    @MainActor private static func session(_ http: SchedulingHTTP, directory: URL, scopes: [String] = ManagedProvider.youtube.scopes) async throws -> (ProviderAccountSession, ProviderTokenVault) {
        let vault = ProviderTokenVault(keychain: SchedulingCredentials(), transport: { try await http.send($0) })
        let generation = try await vault.configure(.youtube, clientID: "fixture-public")
        try await vault.accept(.init(access: "SECRET_ACCESS", expiresAt: Date().addingTimeInterval(3600), scopes: scopes),
                               provider: .youtube, generation: generation)
        let session = ProviderAccountSession(restream: SchedulingRestream(), vault: vault, pendingDirectory: directory)
        await until { session.snapshot(.youtube).hasCredential }
        return (session, vault)
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stream-provider-scheduling-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try catalog(root)
        let project = root.appendingPathComponent("project")
        let http = SchedulingHTTP()
        let (manager, vault) = try await session(http, directory: project)
        check(await http.requests().isEmpty)
        manager.refresh(.youtube); await until { !manager.snapshot(.youtube).isWorking }
        manager.createYouTube(.init(title: "Explicit event"), channelID: "owner")
        await until { !manager.snapshot(.youtube).isWorking }
        precondition(manager.lastSchedulingReceipt?.state == .acknowledged && manager.pending.document.records.count == 1)
        manager.createYouTubeStream(.init(title: "Explicit stream"), channelID: "owner")
        await until { !manager.snapshot(.youtube).isWorking }
        precondition(manager.lastSchedulingReceipt?.resourceID == "created-stream" && manager.pending.document.records.count == 2)
        let persisted = try Data(contentsOf: project.appendingPathComponent("provider-pending.json"))
        let text = String(decoding: persisted, as: UTF8.self)
        for forbidden in ["SECRET", "ingestion", "endpoint", "access", "streamName", "state", "verifiedAt", "enableAuto"] {
            precondition(!text.contains(forbidden))
        }
        let restoredCatalog = ProviderPendingCatalog(directory: project)
        precondition(restoredCatalog.document == manager.pending.document)
        await http.configure(failBind: true)
        manager.reviewYouTubeBinding(eventID: "created-event", streamID: "created-stream", channelID: "owner")
        await until { !manager.snapshot(.youtube).isWorking }
        let review = manager.bindingReview!
        manager.bindYouTube(review)
        await until { !manager.snapshot(.youtube).isWorking }
        precondition(manager.lastSchedulingReceipt?.state == .unconfirmed && manager.pending.document.records.count == 2)
        let afterFailure = await http.requests()
        precondition(afterFailure.filter { $0.url!.path == "/youtube/v3/liveStreams" && $0.httpMethod == "POST" }.count == 1)
        precondition(afterFailure.filter { $0.url!.path.hasSuffix("/bind") }.count == 1)
        manager.shutdown()
        let restarted = ProviderAccountSession(restream: SchedulingRestream(), vault: vault, pendingDirectory: project)
        await until { restarted.snapshot(.youtube).hasCredential }
        check(await http.requests().count == afterFailure.count)
        precondition(restarted.snapshot(.youtube).verifiedAt == nil)
        precondition(restarted.snapshot(.youtube).events.allSatisfy { $0.state == .unknown && $0.verifiedAt == .distantPast })
        precondition(restarted.youtubeStreams.allSatisfy { $0.state == .unknown && $0.verifiedAt == .distantPast })
        let otherProject = ProviderAccountSession(restream: SchedulingRestream(), vault: vault, pendingDirectory: root.appendingPathComponent("other-project"))
        precondition(otherProject.pending.document.records.isEmpty && otherProject.youtubeStreams.isEmpty && otherProject.snapshot(.youtube).events.isEmpty)
        otherProject.shutdown()
        await http.configure(hideUpcoming: true)
        restarted.refresh(.youtube); await until { !restarted.snapshot(.youtube).isWorking }
        precondition(restarted.snapshot(.youtube).events.count == 1 && restarted.snapshot(.youtube).events[0].state == .unknown)
        restarted.reviewYouTubeBinding(eventID: "created-event", streamID: "created-stream", channelID: "owner")
        await until { !restarted.snapshot(.youtube).isWorking }
        restarted.bindYouTube(restarted.bindingReview!)
        await until { !restarted.snapshot(.youtube).isWorking }
        precondition(restarted.lastSchedulingReceipt?.state == .acknowledged)
        let afterRepair = await http.requests()
        precondition(afterRepair.filter { $0.url!.path == "/youtube/v3/liveStreams" && $0.httpMethod == "POST" }.count == 1)
        restarted.reviewYouTubeBinding(eventID: "created-event", streamID: "created-stream", channelID: "owner")
        await until { !restarted.snapshot(.youtube).isWorking }
        restarted.bindYouTube(restarted.bindingReview!)
        await until { !restarted.snapshot(.youtube).isWorking }
        precondition(restarted.lastSchedulingReceipt?.state == .observed)
        check(await http.requests().filter { $0.url!.path.hasSuffix("/bind") }.count == 2)

        // Noncooperative completion cannot revive a cancelled/profile-old job.
        await http.configure(holdCreate: true)
        restarted.createYouTubeStream(.init(title: "Stopped locally"), channelID: "owner")
        await until { await http.createEntered }
        let recordsBeforeCancel = restarted.pending.document.records
        restarted.cancel(.youtube)
        precondition(restarted.lastSchedulingReceipt?.state == .unconfirmed)
        await http.releaseCreate()
        try? await Task.sleep(for: .milliseconds(20))
        precondition(restarted.pending.document.records == recordsBeforeCancel && restarted.lastSchedulingReceipt?.state == .unconfirmed)
        await http.configure(holdCreate: true)
        restarted.createYouTubeStream(.init(title: "Old account"), channelID: "owner")
        await until { await http.createEntered }
        restarted.forget(.youtube); await until { !restarted.snapshot(.youtube).isWorking }
        await http.releaseCreate()
        try? await Task.sleep(for: .milliseconds(20))
        precondition(!restarted.snapshot(.youtube).hasCredential && restarted.pending.document.records == recordsBeforeCancel)
        restarted.shutdown()

        let closingHTTP = SchedulingHTTP()
        let (closing, closingVault) = try await session(closingHTTP, directory: root.appendingPathComponent("closing"))
        await closingHTTP.configure(holdCreate: true)
        closing.createYouTubeStream(.init(title: "Old workspace"), channelID: "owner")
        await until { await closingHTTP.createEntered }
        closing.shutdown()
        let replacement = ProviderAccountSession(restream: SchedulingRestream(), vault: closingVault, pendingDirectory: root.appendingPathComponent("closing"))
        await closingHTTP.releaseCreate()
        try? await Task.sleep(for: .milliseconds(20))
        precondition(closing.pending.document.records.isEmpty && replacement.pending.document.records.isEmpty)
        precondition(closing.lastSchedulingReceipt?.state == .unconfirmed)
        let beforeClosed = await closingHTTP.requests().count
        closing.createYouTubeStream(.init(title: "Closed old workspace"), channelID: "owner")
        check(await closingHTTP.requests().count == beforeClosed)
        replacement.shutdown()
        let readHTTP = SchedulingHTTP()
        let (readOnly, _) = try await session(readHTTP, directory: root.appendingPathComponent("read-only"),
            scopes: ["https://www.googleapis.com/auth/youtube.readonly"])
        readOnly.createYouTube(.init(title: "Forbidden event"), channelID: "owner")
        readOnly.createYouTubeStream(.init(title: "Forbidden stream"), channelID: "owner")
        check(await readHTTP.requests().isEmpty)
        precondition(readOnly.pending.document.records.isEmpty)
        readOnly.shutdown()

        // A real disk failure retains the acknowledged ID in memory and blocks
        // another create instead of losing it or silently retrying the POST.
        let file = root.appendingPathComponent("not-a-directory"); try Data("file".utf8).write(to: file)
        let failingHTTP = SchedulingHTTP(), (failing, _) = try await session(failingHTTP, directory: file)
        failing.createYouTubeStream(.init(title: "Disk failure"), channelID: "owner")
        await until { !failing.snapshot(.youtube).isWorking }
        precondition(failing.lastSchedulingReceipt?.state == .acknowledged && failing.pending.document.records.count == 1)
        precondition(!failing.pending.writable && failing.pending.error != nil)
        let beforeBlocked = await failingHTTP.requests().count
        failing.createYouTubeStream(.init(title: "Must not repeat"), channelID: "owner")
        check(await failingHTTP.requests().count == beforeBlocked)
        failing.shutdown()
        print("PASS: production scheduling session/catalog; actual stream/event IDs before binding, partial bind failure + explicit repair without recreate, restart/project isolation + unknown states/no replay, account lifecycle/noncooperative late-result guards, exact per-resource receipts, bounded/versioned/public-only storage and real disk-failure retention")
    }
    @MainActor static func catalog(_ root: URL) throws {
        let directory = root.appendingPathComponent("catalog")
        let catalog = ProviderPendingCatalog(directory: directory)
        for index in 0..<128 {
            precondition(catalog.retain([.init(ProviderEvent(id: "event-\(index)", provider: .youtube, channelID: "owner", title: "Public", state: .live))]))
        }
        precondition(!catalog.canCreate && catalog.document.records.count == 128)
        precondition(catalog.canRetain([.init(ProviderEvent(id: "event-0", provider: .youtube, channelID: "owner", title: "Updated"))]))
        precondition(!catalog.canRetain([.init(ProviderEvent(id: "overflow", provider: .youtube, channelID: "owner", title: "No"))]))
        let restored = ProviderPendingCatalog(directory: directory)
        precondition(restored.document.records.count == 128 && restored.document.records.allSatisfy { $0.cachedEvent.state == .unknown })
        catalog.remove("youtube:event:event-0"); precondition(catalog.canCreate && catalog.document.records.count == 127)
        for (name, data) in [("future", Data(#"{"version":99,"records":[]}"#.utf8)), ("oversized", Data(repeating: 32, count: 524289))] {
            let folder = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("provider-pending.json"); try data.write(to: file)
            let preserved = ProviderPendingCatalog(directory: folder)
            precondition(!preserved.writable && !preserved.canCreate && preserved.document.records.isEmpty)
            let after = try Data(contentsOf: file); precondition(after == data)
        }
    }
}
