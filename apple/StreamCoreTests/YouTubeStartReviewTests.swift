import Foundation
import Testing
@testable import StreamCore

private actor StartAPIFixture {
    var replies: [Data]
    var requests: [URLRequest] = []
    init(_ replies: [String]) { self.replies = replies.map { Data($0.utf8) } }
    func send(_ request: URLRequest) throws -> Data {
        requests.append(request)
        guard !replies.isEmpty else { throw ProviderFailure(.unavailable) }
        return replies.removeFirst()
    }
    nonisolated var reader: YouTubeStartReader { .init { _, request in try await self.send(request) } }
    func calls() -> [URLRequest] { requests }
}
private let startBinding = ProviderDestinationBinding(provider: .youtube, channelID: "owner", eventID: "event")
private let startProfile = YouTubeStartProfile(destination: .init(name: "YouTube"), program: .default)
private let startOwner = #"{"items":[{"id":"owner","snippet":{"title":"Channel"}}]}"#
private func startJSON(_ object: [String: Any]) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
private func startEvent(id: String = "event", owner: String = "owner", bound: String = "stream", state: String = "ready", auto: Any? = false,
                        stop: Any? = false, privacy: String = "private", latency: String = "normal", schedule: String = "2030-10-03T12:00:00Z") -> String {
    var details: [String: Any] = ["boundStreamId": bound, "latencyPreference": latency]
    details["enableAutoStart"] = auto; details["enableAutoStop"] = stop
    return startJSON(["items": [["id": id, "snippet": ["channelId": owner, "title": "The selected event", "scheduledStartTime": schedule],
        "status": ["lifeCycleStatus": state, "privacyStatus": privacy], "contentDetails": details]]])
}
private func startStream(id: String = "stream", owner: String = "owner", state: String = "ready", resolution: String = "variable", rate: String = "variable",
                         endpoint: String = "rtmps://a.rtmps.youtube.com:443/live2", health: String = "noData") -> String {
    startJSON(["items": [["id": id, "snippet": ["channelId": owner], "status": ["streamStatus": state, "healthStatus": ["status": health]],
        "cdn": ["ingestionType": "rtmp", "resolution": resolution, "frameRate": rate,
                "ingestionInfo": ["rtmpsIngestionAddress": endpoint, "streamName": "SECRET_KEY"]]]]])
}

@Suite struct YouTubeStartReviewTests {
    @Test("Fresh owned review checks exact IDs twice and retains no ingest credentials")
    func review() async throws {
        let fixture = StartAPIFixture([startOwner, startEvent(), startStream(), startEvent()])
        let review = try await fixture.reader.review(binding: startBinding, profile: startProfile)
        #expect(review.streamID == "stream" && review.lifecycle == "ready" && !review.autoStart && !review.autoStop)
        #expect(review.requiresEarlyStart(at: Date(timeIntervalSince1970: 0)))
        #expect(!String(reflecting: review).contains("SECRET") && !String(reflecting: review).contains("rtmps://"))
        let calls = await fixture.calls()
        #expect(calls.count == 4 && calls.allSatisfy { ($0.httpMethod ?? "GET") == "GET" && $0.httpBody == nil })
        #expect(URLComponents(url: calls[0].url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "mine", value: "true")) == true)
    }
    @Test("Only fresh owned ready/live events and inactive/ready streams may proceed")
    func lifecycle() async throws {
        for state in ["created", "testing", "testStarting", "liveStarting", "complete", "revoked", "unknown"] {
            let fixture = StartAPIFixture([startOwner, startEvent(state: state)])
            await #expect(throws: ProviderFailure.self) { try await fixture.reader.review(binding: startBinding, profile: startProfile) }
            #expect(await fixture.calls().count == 2)
        }
        for state in ["created", "active", "error", "unknown"] {
            let fixture = StartAPIFixture([startOwner, startEvent(), startStream(state: state)])
            await #expect(throws: ProviderFailure.self) { try await fixture.reader.review(binding: startBinding, profile: startProfile) }
        }
        let fixture = StartAPIFixture([startOwner, startEvent(state: "live"), startStream(state: "inactive"), startEvent(state: "live")])
        let review = try await fixture.reader.review(binding: startBinding, profile: startProfile)
        #expect(!review.requiresEarlyStart(at: Date(timeIntervalSince1970: 0)))
    }
    @Test("Absent/foreign/wrong-ID events and streams, missing flags, malformed schedule and binding races are blocked")
    func identity() async throws {
        for response in [#"{"items":[]}"#, startEvent(id: "other"), startEvent(owner: "foreign"), startEvent(bound: ""),
                         startEvent(auto: nil), startEvent(stop: nil), startEvent(auto: 1), startEvent(stop: "false"), startEvent(schedule: "invalid")] {
            let fixture = StartAPIFixture([startOwner, response])
            await #expect(throws: ProviderFailure.self) { try await fixture.reader.review(binding: startBinding, profile: startProfile) }
        }
        for response in [startStream(id: "other"), startStream(owner: "foreign"), #"{"items":[]}"#] {
            let fixture = StartAPIFixture([startOwner, startEvent(), response])
            await #expect(throws: ProviderFailure.self) { try await fixture.reader.review(binding: startBinding, profile: startProfile) }
        }
        let fixture = StartAPIFixture([startOwner, startEvent(), startStream(), startEvent(bound: "replacement")])
        await #expect(throws: ProviderFailure.self) { try await fixture.reader.review(binding: startBinding, profile: startProfile) }
        let foreign = StartAPIFixture([#"{"items":[{"id":"foreign"}]}"#])
        await #expect(throws: ProviderFailure.self) { try await foreign.reader.review(binding: startBinding, profile: startProfile) }
        #expect(await foreign.calls().count == 1)
    }
    @Test("Codec, keyframes, fixed resolution/rate and stream health validate before publisher handoff")
    func profile() async throws {
        for destination in [StreamDestination(name: "Invalid", videoCodec: .hevc), .init(name: "Invalid", keyframeSeconds: 5),
                            .init(name: "Invalid", audioBitrate: 192_000), .init(name: "Invalid", transport: .srt)] {
            let fixture = StartAPIFixture([])
            await #expect(throws: ProviderFailure.self) { try await fixture.reader.review(binding: startBinding, profile: .init(destination: destination, program: .default)) }
            #expect(await fixture.calls().isEmpty)
        }
        for response in [startStream(resolution: "1080p", rate: "30fps"), startStream(resolution: "variable", rate: "30fps"),
                         startStream(health: "bad")] {
            let fixture = StartAPIFixture([startOwner, startEvent(), response])
            await #expect(throws: ProviderFailure.self) { try await fixture.reader.review(binding: startBinding, profile: startProfile) }
        }
        let explicit = YouTubeStartProfile(destination: .init(name: "Explicit"), program: .init(canvasWidth: 1920, canvasHeight: 1080, frameRate: 30))
        let fixture = StartAPIFixture([startOwner, startEvent(), startStream(resolution: "1080p", rate: "30fps"), startEvent()])
        _ = try await fixture.reader.review(binding: startBinding, profile: explicit)
        let large = YouTubeStartProfile(destination: .init(name: "Large"), program: .init(canvasWidth: 3840, canvasHeight: 2160, frameRate: 30))
        let ultra = StartAPIFixture([startOwner, startEvent(latency: "ultraLow"), startStream()])
        await #expect(throws: ProviderFailure.self) { try await ultra.reader.review(binding: startBinding, profile: large) }
    }
    @Test("Ingest read verifies the same owner/event/stream and event again after the credential read")
    func ingest() async throws {
        let fixture = StartAPIFixture([startOwner, startEvent(), startStream(), startEvent(), startOwner, startEvent(), startStream(), startEvent()])
        let review = try await fixture.reader.review(binding: startBinding, profile: startProfile)
        let credentials = try await fixture.reader.reviewedIngest(review)
        #expect(credentials.endpoint == "rtmps://a.rtmps.youtube.com:443/live2" && credentials.streamKey == "SECRET_KEY")
        #expect(await fixture.calls().count == 8)
        #expect(await fixture.calls().allSatisfy { ($0.httpMethod ?? "GET") == "GET" })
    }
    @Test("Changed binding/auto flags/lifecycle/privacy/profile and wrong ingest IDs do not release credentials or retry")
    func ingestChanges() async throws {
        let base = StartAPIFixture([startOwner, startEvent(), startStream(), startEvent()])
        let review = try await base.reader.review(binding: startBinding, profile: startProfile)
        for response in [startEvent(bound: "replacement"), startEvent(auto: true), startEvent(stop: true), startEvent(state: "live"), startEvent(privacy: "public")] {
            let fixture = StartAPIFixture([startOwner, response])
            await #expect(throws: ProviderFailure.self) { try await fixture.reader.reviewedIngest(review) }
            #expect(await fixture.calls().count == 2)
        }
        for response in [startStream(id: "other"), startStream(owner: "foreign"), startStream(resolution: "1080p", rate: "30fps"),
                         startStream(endpoint: "rtmp://a.rtmp.youtube.com/live2"), startStream(endpoint: "rtmps://user:secret@a.rtmps.youtube.com/live2")] {
            let fixture = StartAPIFixture([startOwner, startEvent(), response])
            await #expect(throws: ProviderFailure.self) { try await fixture.reader.reviewedIngest(review) }
            #expect(await fixture.calls().count == 3)
        }
        let changedAfter = StartAPIFixture([startOwner, startEvent(), startStream(), startEvent(bound: "replacement")])
        await #expect(throws: ProviderFailure.self) { try await changedAfter.reader.reviewedIngest(review) }
        #expect(await changedAfter.calls().count == 4)
    }
    @Test("Expired reviews and account loss fail before any secret read; unavailable calls never retry")
    func expiry() async throws {
        let base = StartAPIFixture([startOwner, startEvent(), startStream(), startEvent()])
        let review = try await base.reader.review(binding: startBinding, profile: startProfile)
        let expired = StartAPIFixture([])
        let reader = YouTubeStartReader(send: { _, request in try await expired.send(request) }, now: { review.expiresAt })
        await #expect(throws: ProviderFailure.self) { try await reader.reviewedIngest(review) }
        #expect(await expired.calls().isEmpty)
        for kind in [ProviderFailure.Kind.authorization, .permission, .unavailable, .rateLimited] {
            let reader = YouTubeStartReader { _, _ in throw ProviderFailure(kind) }
            await #expect(throws: ProviderFailure.self) { try await reader.reviewedIngest(review) }
        }
    }
}
