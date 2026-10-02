import Foundation
import Testing
@testable import StreamCore

@Suite struct RecoveryEventReviewTests {
    let date = Date(timeIntervalSince1970: 1_000)
    func identity(_ provider: ManagedProvider = .youtube) -> RecoveryEventIdentity {
        .init(outputID: UUID(), publisherSessionID: UUID(), provider: provider,
              channelID: "owned_channel", eventID: "exact_event", capturedAt: date.addingTimeInterval(-100))
    }
    func receipt(_ state: ProviderEvent.State) -> RecoveryEventVerification {
        .init(provider: .youtube, eventID: "exact_event", channelID: "owned_channel", authorizedChannelIDs: ["owned_channel"],
              state: state, readStartedAt: date, observedAt: date.addingTimeInterval(1))
    }
    @Test("Only exact fresh owned live and terminal states are classified")
    func classification() {
        for (state, expected) in [(ProviderEvent.State.live, SessionRecoveryRemoteEvent.State.reconnectable), (.ended, .ended), (.upcoming, .unknown), (.unknown, .unknown)] {
            #expect(RecoveryEventReview.classify(receipt(state), identity: identity(), requestedAt: date,
                now: date.addingTimeInterval(2)).state == expected)
        }
        var value = receipt(.live); value.channelID = "foreign_channel"
        #expect(RecoveryEventReview.classify(value, identity: identity(), requestedAt: date, now: date.addingTimeInterval(2)).reason == .foreignOwnership)
        value = receipt(.live); value.authorizedChannelIDs = ["other_account"]
        #expect(RecoveryEventReview.classify(value, identity: identity(), requestedAt: date, now: date.addingTimeInterval(2)).reason == .foreignOwnership)
        value = receipt(.live); value.eventID = "other_event"
        #expect(RecoveryEventReview.classify(value, identity: identity(), requestedAt: date, now: date.addingTimeInterval(2)).reason == .invalidResponse)
    }
    @Test("Cached, expired, future and inverted receipts remain unknown")
    func timing() {
        var value = receipt(.live); value.readStartedAt = date.addingTimeInterval(-1)
        #expect(RecoveryEventReview.classify(value, identity: identity(), requestedAt: date, now: date.addingTimeInterval(2)).reason == .stale)
        value = receipt(.live)
        #expect(RecoveryEventReview.classify(value, identity: identity(), requestedAt: date, now: date.addingTimeInterval(62)).reason == .stale)
        #expect(RecoveryEventReview.classify(value, identity: identity(), requestedAt: date, now: date).reason == .stale)
        value.observedAt = date.addingTimeInterval(-1)
        #expect(RecoveryEventReview.classify(value, identity: identity(), requestedAt: date, now: date.addingTimeInterval(2)).reason == .stale)
        let review = RecoveryEventReview(state: .ended, reason: .ended, checkedAt: date)
        #expect(review.current(at: date.addingTimeInterval(61)).state == .unknown)
    }
    @Test("Legacy journals decode without pretending a cached end is current evidence")
    func compatibility() throws {
        let output = UUID()
        let old = Data("{\"outputID\":\"\(output)\",\"eventID\":\"exact_event\",\"state\":\"ended\"}".utf8)
        let decoded = try JSONDecoder().decode(SessionRecoveryRemoteEvent.self, from: old)
        #expect(decoded.reviewIdentity == nil && decoded.state == .ended)
        var event = SessionRecoveryRemoteEvent(outputID: output, eventID: "exact_event", provider: .youtube,
            channelID: "owned_channel", publisherSessionID: UUID(), capturedAt: date)
        var snapshot = SessionRecoverySnapshot(projectID: UUID(), profileID: UUID()); snapshot.remoteEvents = [event]
        let reopened = try JSONDecoder().decode(SessionRecoverySnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(reopened.remoteEvents[0].reviewIdentity != nil && reopened.validationError == nil)
        event.channelID = "https://foreign?secret=token"; snapshot.remoteEvents = [event]
        #expect(snapshot.validationError != nil)
    }
    @Test("Fresh reader sends only uncached GETs, proves current owner first, never transitions")
    func requests() async throws {
        let transport = RecoveryRequestFixture()
        let reader = RecoveryEventReader(send: { provider, request in try await transport.send(provider, request) }, now: { Date(timeIntervalSince1970: 1_000) })
        let result = try await reader.verify(identity())
        #expect(result.state == .live && result.authorizedChannelIDs == ["owned_channel"])
        let paths = await transport.paths
        #expect(paths == ["/youtube/v3/channels", "/youtube/v3/liveBroadcasts"])
        await transport.foreign()
        let other = try await reader.verify(identity())
        #expect(other.channelID == nil && other.state == .unknown)
        #expect(await transport.paths.count == 3)
    }
    @Test("Transitional and missing exact API states do not become reconnectable")
    func lifecycle() async throws {
        for state in ["created", "ready", "testing", "liveStarting", "testStarting", "mystery"] {
            let transport = RecoveryRequestFixture(lifecycle: state)
            let result = try await RecoveryEventReader(send: { p, r in try await transport.send(p, r) }, now: { Date(timeIntervalSince1970: 1_000) }).verify(identity())
            #expect(RecoveryEventReview.classify(result, identity: identity(), requestedAt: date, now: date).state == .unknown)
        }
        for state in ["complete", "revoked"] {
            let transport = RecoveryRequestFixture(lifecycle: state)
            let result = try await RecoveryEventReader(send: { p, r in try await transport.send(p, r) }, now: { Date(timeIntervalSince1970: 1_000) }).verify(identity())
            #expect(RecoveryEventReview.classify(result, identity: identity(), requestedAt: date, now: date).state == .ended)
        }
    }
}

private actor RecoveryRequestFixture {
    var paths: [String] = []
    var owner = "owned_channel"
    let lifecycle: String
    init(lifecycle: String = "live") { self.lifecycle = lifecycle }
    func foreign() { owner = "foreign_channel" }
    func send(_ provider: ManagedProvider, _ request: URLRequest) throws -> Data {
        #expect(provider == .youtube && request.httpMethod == "GET" && request.httpBody == nil)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData && request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
        let path = request.url!.path; paths.append(path)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        if path == "/youtube/v3/channels" {
            #expect(query.contains { $0.name == "mine" && $0.value == "true" })
            return Data("{\"items\":[{\"id\":\"\(owner)\",\"snippet\":{\"title\":\"Fixture\"}}]}".utf8)
        }
        #expect(path == "/youtube/v3/liveBroadcasts")
        #expect(query.contains { $0.name == "id" && $0.value == "exact_event" })
        return Data("{\"items\":[{\"id\":\"exact_event\",\"snippet\":{\"channelId\":\"owned_channel\"},\"status\":{\"lifeCycleStatus\":\"\(lifecycle)\"}}]}".utf8)
    }
}
