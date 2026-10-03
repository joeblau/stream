import Foundation
import StreamCore

private func require(_ value: Bool, _ message: String) throws {
    if !value { throw NSError(domain: "ManagedStartFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
@MainActor private func settle(_ predicate: @escaping () -> Bool) async throws {
    for _ in 0..<500 {
        if predicate() { return }; try await Task.sleep(for: .milliseconds(2))
    }
    throw NSError(domain: "ManagedStartFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for fixture state"])
}

/// The actual reader/coordinator run against exact injected wire responses.
/// No OAuth secrets, external requests, publishers or camera/audio APIs exist.
@MainActor private final class Fixture {
    var account: UUID? = UUID()
    var contexts: [UUID: ManagedYouTubeStartContext] = [:]
    var requests: [URLRequest] = []
    var allocations = 0
    var blockAt: Int?
    var held: CheckedContinuation<Void, Never>?
    var failure: ProviderFailure?
    var replacementBindingAt: Int?
    var allowAllocation = true
    var coordinator: ManagedYouTubeStartCoordinator!
    init(timeout: Duration = .seconds(30)) {
        coordinator = ManagedYouTubeStartCoordinator(generation: { [weak self] in self?.account },
            read: { [weak self] request, expected in
                guard let self, account == expected else { throw ProviderFailure(.authorization) }
                requests.append(request)
                let number = requests.count
                if blockAt == number { await withCheckedContinuation { held = $0 } }
                if let failure { throw failure }
                return try response(request, number: number)
            }, current: { [weak self] in self?.contexts[$0] }, publish: { [weak self] context, credentials in
                guard let self, allowAllocation, contexts[context.destination.id] == context else { return false }
                // This represents the factory seam, reached only after real
                // production GET parsing/fences/consent. Never log the key.
                guard credentials.streamKey == "PRIVATE_FIXTURE_KEY", credentials.endpoint.hasPrefix("rtmps://") else { return false }
                allocations += 1; return true
            }, operationTimeout: timeout)
    }
    func context(provider: ManagedProvider? = .youtube) -> ManagedYouTubeStartContext {
        let binding = provider.map { ProviderDestinationBinding(provider: $0, channelID: "owner", eventID: "event") }
        let destination = StreamDestination(name: "Managed", providerBinding: binding)
        var settings = StreamSettings.default; settings.rtmpURL = "rtmps://PRIVATE_ENDPOINT"; settings.streamKey = "PRIVATE_KEY"
        let value = ManagedYouTubeStartContext(destination: destination, settings: settings)
        contexts[destination.id] = value; return value
    }
    func release() { let value = held; held = nil; value?.resume() }
    private func response(_ request: URLRequest, number: Int) throws -> Data {
        try require(request.httpMethod == "GET" && request.httpBody == nil, "Unexpected provider mutation")
        try require(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData && request.timeoutInterval == 10, "Fresh bounded read configuration")
        let row: [String: Any]
        switch request.url?.path {
        case "/youtube/v3/channels": row = ["id": "owner"]
        case "/youtube/v3/liveBroadcasts":
            row = ["id": "event", "snippet": ["channelId": "owner", "title": "Scheduled event", "scheduledStartTime": "2030-10-03T12:00:00Z"],
                "status": ["lifeCycleStatus": "ready", "privacyStatus": "private"],
                "contentDetails": ["boundStreamId": replacementBindingAt == number ? "replacement" : "stream", "enableAutoStart": true, "enableAutoStop": false]]
        case "/youtube/v3/liveStreams":
            row = ["id": "stream", "snippet": ["channelId": "owner"], "status": ["streamStatus": "ready"],
                "cdn": ["ingestionType": "rtmp", "resolution": "variable", "frameRate": "variable",
                    "ingestionInfo": ["rtmpsIngestionAddress": "rtmps://a.rtmps.youtube.com/live2", "streamName": "PRIVATE_FIXTURE_KEY"]]]
        default: throw ProviderFailure(.invalidRequest)
        }
        return try JSONSerialization.data(withJSONObject: ["items": [row]])
    }
}

@main struct ManagedStartHarness {
    @MainActor static func main() async throws {
        // Successful real review does not allocate. Consent is separate and
        // future schedules require the deliberate early-start checkbox.
        let success = Fixture(), context = success.context(), id = context.destination.id
        try require(success.coordinator.request(context), "Managed route was not intercepted")
        try await settle { success.coordinator.entries.first?.phase == .review }
        try require(success.allocations == 0 && success.requests.count == 4, "Allocation happened before review")
        try require(!String(reflecting: success.coordinator.entries).contains("PRIVATE"), "Review retained a private field")
        success.coordinator.confirm(id, consent: .init())
        success.coordinator.confirm(id, consent: .init(reviewedPublicEffect: true))
        try require(success.requests.count == 4 && success.allocations == 0, "Consent/early-start gate bypassed")
        success.coordinator.confirm(id, consent: .init(reviewedPublicEffect: true, startBeforeScheduledTime: true))
        success.coordinator.confirm(id, consent: .init(reviewedPublicEffect: true, startBeforeScheduledTime: true))
        try await settle { success.allocations == 1 }
        try require(success.requests.count == 8 && success.coordinator.entries.isEmpty, "Handoff was replayable or not reverified")
        success.coordinator.confirm(id, consent: .init(reviewedPublicEffect: true, startBeforeScheduledTime: true))
        try require(success.allocations == 1, "Consumed review replayed")

        // Local settings changes, account change and remote binding change
        // block independently; no guessed prior Keychain key is released.
        for change in 0..<4 {
            let fixture = Fixture(), value = fixture.context(), destinationID = value.destination.id
            fixture.coordinator.request(value); try await settle { fixture.coordinator.entries.first?.phase == .review }
            switch change {
            case 0: var destination = value.destination; destination.name = "Changed"; fixture.contexts[destinationID] = .init(destination: destination, settings: value.settings)
            case 1: var settings = value.settings; settings.outputProfile = .init(canvasWidth: 1920, canvasHeight: 1080, frameRate: 30); fixture.contexts[destinationID] = .init(destination: value.destination, settings: settings)
            case 2: fixture.account = UUID()
            default: fixture.replacementBindingAt = 6
            }
            fixture.coordinator.confirm(destinationID, consent: .init(reviewedPublicEffect: true, startBeforeScheduledTime: true))
            try await settle { fixture.coordinator.entries.first?.phase == .blocked }
            try require(fixture.allocations == 0, "Changed identity/profile allocated publisher")
            if change < 3 {
                fixture.coordinator.reviewAgain(destinationID)
                try await settle { fixture.coordinator.entries.first?.phase == .review }
                try require(fixture.coordinator.entries.first?.context == fixture.contexts[destinationID], "Explicit new review kept stale settings")
            }
        }

        // Noncooperative request completion cannot revive cancellation,
        // profile closure, a replacement attempt or a deadline.
        for action in 0..<4 {
            let fixture = Fixture(timeout: action == 3 ? .milliseconds(30) : .seconds(30)), value = fixture.context()
            fixture.blockAt = 3; fixture.coordinator.request(value)
            try await settle { fixture.held != nil }
            switch action {
            case 0: fixture.coordinator.cancel(value.destination.id)
            case 1: fixture.coordinator.shutdown()
            case 2:
                fixture.coordinator.cancel(value.destination.id); fixture.blockAt = nil
                fixture.coordinator.request(value); try await settle { fixture.coordinator.entries.first?.phase == .review }
            default: try await settle { fixture.coordinator.entries.first?.phase == .blocked }
            }
            fixture.release(); try await Task.sleep(for: .milliseconds(20))
            try require(fixture.allocations == 0, "Late read allocated publisher")
            if action < 2 { try require(fixture.coordinator.entries.isEmpty, "Late read revived a retired review") }
            if action == 2 { try require(fixture.coordinator.entries.first?.phase == .review, "Late read replaced the current review") }
        }
        // Late credentials after account replacement/cancel/shutdown cannot be
        // passed to the factory, even when the underlying read ignores cancel.
        for action in 0..<3 {
            let fixture = Fixture(), value = fixture.context()
            fixture.coordinator.request(value); try await settle { fixture.coordinator.entries.first?.phase == .review }
            fixture.blockAt = 7
            fixture.coordinator.confirm(value.destination.id, consent: .init(reviewedPublicEffect: true, startBeforeScheduledTime: true))
            try await settle { fixture.held != nil }
            switch action {
            case 0: fixture.account = UUID()
            case 1: fixture.coordinator.cancel(value.destination.id)
            default: fixture.coordinator.shutdown()
            }
            fixture.release(); try await Task.sleep(for: .milliseconds(20))
            try require(fixture.allocations == 0, "Late ingest credentials allocated a publisher")
        }
        for kind in [ProviderFailure.Kind.permission, .authorization, .unavailable, .rateLimited] {
            let fixture = Fixture(), value = fixture.context(); fixture.failure = .init(kind)
            fixture.coordinator.request(value); try await settle { fixture.coordinator.entries.first?.phase == .blocked }
            try require(fixture.requests.count == 1 && fixture.allocations == 0, "Provider failure retried or allocated")
        }
        let routes = Fixture(), manual = routes.context(provider: nil), unsupported = routes.context(provider: .restream)
        try require(!routes.coordinator.request(manual), "Manual route changed")
        try require(routes.coordinator.request(unsupported) && routes.coordinator.entries.first?.phase == .blocked, "Unsupported managed route guessed eligibility")
        try require(routes.requests.isEmpty && routes.allocations == 0, "Unsupported route performed a request")
        let resource = Fixture(), resourceContext = resource.context(); resource.allowAllocation = false
        resource.coordinator.request(resourceContext); try await settle { resource.coordinator.entries.first?.phase == .review }
        resource.coordinator.confirm(resourceContext.destination.id, consent: .init(reviewedPublicEffect: true, startBeforeScheduledTime: true))
        try await settle { resource.coordinator.entries.first?.phase == .blocked }
        try require(resource.allocations == 0 && resource.requests.count == 8, "Resource refusal allocated/retried")
        let bounded = Fixture()
        for _ in 0..<12 { bounded.coordinator.request(bounded.context(provider: .twitch)) }
        try require(bounded.coordinator.entries.count == 10, "Review queue exceeded bound")
        bounded.coordinator.shutdown()
        print("PASS: production managed YouTube review, early-start/consent, exact binding, one-use allocation, account/settings/profile, cancellation/late credentials, timeout, failures and bounded routes")
    }
}
