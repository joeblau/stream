import Foundation
import Testing
@testable import StreamCore

private actor SchedulingAPIFixture {
    var replies: [Data]
    var requests: [URLRequest] = []
    init(_ replies: [String]) { self.replies = replies.map { Data($0.utf8) } }
    func send(_ request: URLRequest) throws -> Data {
        requests.append(request)
        guard !replies.isEmpty else { throw ProviderFailure(.unavailable) }
        return replies.removeFirst()
    }
    nonisolated var api: ProviderAPI { .init { _, request in try await self.send(request) } }
    func calls() -> [URLRequest] { requests }
}
private func eventRow(bound: String? = nil, owner: String = "owner", state: String = "ready", auto: Bool = false) -> String {
    var details: [String: Any] = ["enableAutoStart": auto, "enableAutoStop": false]
    if let bound { details["boundStreamId"] = bound }
    let row: [String: Any] = ["id": "event", "snippet": ["channelId": owner, "title": "Event"],
        "status": ["lifeCycleStatus": state, "privacyStatus": "private"], "contentDetails": details]
    return String(decoding: try! JSONSerialization.data(withJSONObject: row), as: UTF8.self)
}
private func streamRow(owner: String = "owner", state: String = "ready", resolution: String = "variable", rate: String = "variable") -> String {
    let row: [String: Any] = ["id": "stream", "snippet": ["channelId": owner, "title": "Stream"],
        "status": ["streamStatus": state],
        "cdn": ["ingestionType": "rtmp", "resolution": resolution, "frameRate": rate,
                "ingestionInfo": ["streamName": "SECRET_KEY", "ingestionAddress": "rtmp://private.example/SECRET_ENDPOINT"]],
        "contentDetails": ["isReusable": false, "closedCaptionsIngestionUrl": "https://private.example/SECRET_CAPTIONS"]]
    return String(decoding: try! JSONSerialization.data(withJSONObject: row), as: UTF8.self)
}
private func list(_ row: String) -> String { #"{"items":["# + row + "]}" }

@Suite struct YouTubeStreamAPITests {
    @Test("Stream insert uses a paired variable RTMP profile, explicit reuse and fresh ownership; metadata discards credentials")
    func create() async throws {
        let fixture = SchedulingAPIFixture([#"{"items":[{"id":"owner"}]}"#, streamRow()])
        let stream = try await fixture.api.createYouTubeStream(.init(title: "Camera 🎥", reusable: false), expectedChannelID: "owner")
        #expect(stream.id == "stream" && stream.channelID == "owner" && stream.state == .ready && stream.reusable == false)
        #expect(!String(reflecting: stream).contains("SECRET"))
        let calls = await fixture.calls(), call = try #require(calls.last)
        #expect(calls.count == 2 && call.httpMethod == "POST" && call.url?.path == "/youtube/v3/liveStreams")
        let body = try #require(JSONSerialization.jsonObject(with: call.httpBody!) as? [String: Any])
        #expect(body["snippet"] as? [String: String] == ["title": "Camera 🎥"])
        #expect(body["cdn"] as? [String: String] == ["ingestionType": "rtmp", "resolution": "variable", "frameRate": "variable"])
        #expect(body["contentDetails"] as? [String: Bool] == ["isReusable": false])
    }
    @Test("Invalid profile pairing and oversized titles never create; different account cannot create the reviewed channel")
    func createGuards() async throws {
        let fixture = SchedulingAPIFixture([#"{"items":[{"id":"different"}]}"#])
        for draft in [YouTubeStreamDraft(title: "Bad", resolution: .p1080, frameRate: .variable),
                      .init(title: "Bad", resolution: .variable, frameRate: .fps30),
                      .init(title: String(repeating: "x", count: 129))] {
            await #expect(throws: ProviderFailure.self) { try await fixture.api.createYouTubeStream(draft, expectedChannelID: "owner") }
        }
        #expect(await fixture.calls().isEmpty)
        await #expect(throws: ProviderFailure.self) { try await fixture.api.createYouTubeStream(.init(title: "Good"), expectedChannelID: "owner") }
        #expect(await fixture.calls().count == 1)
        try YouTubeStreamDraft(title: "Explicit", resolution: .p1080, frameRate: .fps30).validate()
    }
    @Test("Owned stream discovery paginates, deduplicates IDs and never invents readiness")
    func streams() async throws {
        let fixture = SchedulingAPIFixture([#"{"items":[{"id":"stream","snippet":{"channelId":"owner","title":"Old"}}],"nextPageToken":"next"}"#,
            list(streamRow())])
        let streams = try await fixture.api.youtubeStreams()
        #expect(streams.count == 1 && streams[0].title == "Stream" && streams[0].state == .ready)
        let calls = await fixture.calls()
        #expect(calls.count == 2 && calls.allSatisfy { ($0.httpMethod ?? "GET") == "GET" })
        let query = URLComponents(url: calls[1].url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first { $0.name == "mine" }?.value == "true")
        #expect(query?.first { $0.name == "pageToken" }?.value == "next")
        let unknown = SchedulingAPIFixture([#"{"items":[{"id":"stream","status":{"streamStatus":"newValue"}}]}"#])
        #expect(try await unknown.api.youtubeStream(id: "stream").state == .unknown)
    }
    @Test("Binding uses fresh exact IDs, one bodyless POST and retains automatic settings")
    func bind() async throws {
        let fixture = SchedulingAPIFixture([list(eventRow(auto: true)), list(streamRow()),
            list(eventRow(auto: true)), list(streamRow()), eventRow(bound: "stream", auto: true)])
        let review = try await fixture.api.reviewYouTubeBinding(eventID: "event", streamID: "stream", expectedChannelID: "owner")
        let event = try await fixture.api.bindYouTube(review)
        #expect(event.boundStreamID == "stream" && event.enableAutoStart == true && event.enableAutoStop == false)
        let calls = await fixture.calls(), post = try #require(calls.last)
        #expect(calls.count == 5 && post.httpMethod == "POST" && post.httpBody == nil)
        #expect(post.url?.path == "/youtube/v3/liveBroadcasts/bind")
        let query = URLComponents(url: post.url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first { $0.name == "id" }?.value == "event")
        #expect(query?.first { $0.name == "streamId" }?.value == "stream")
        #expect(!calls.contains { $0.httpMethod == "PUT" || $0.httpMethod == "DELETE" })
    }
    @Test("Another binding needs explicit replacement; changed binding or automatic settings invalidate a review")
    func replacement() async throws {
        let review = YouTubeBindingReview(event: .init(id: "event", provider: .youtube, channelID: "owner", title: "Event",
            state: .upcoming, boundStreamID: "previous", enableAutoStart: false, enableAutoStop: false),
            stream: .init(id: "stream", channelID: "owner", title: "Stream"))
        let denied = SchedulingAPIFixture([list(eventRow(bound: "previous")), list(streamRow())])
        await #expect(throws: ProviderFailure.self) { try await denied.api.bindYouTube(review) }
        #expect(await denied.calls().count == 2)
        let allowed = SchedulingAPIFixture([list(eventRow(bound: "previous")), list(streamRow()), eventRow(bound: "stream")])
        #expect(try await allowed.api.bindYouTube(review, replacingExisting: true).boundStreamID == "stream")
        for changed in [eventRow(bound: "someoneElse"), eventRow(bound: "previous", auto: true)] {
            let stale = SchedulingAPIFixture([list(changed), list(streamRow())])
            await #expect(throws: ProviderFailure.self) { try await stale.api.bindYouTube(review, replacingExisting: true) }
            #expect(await stale.calls().count == 2)
        }
    }
    @Test("An existing matching binding is an observed read, never another mutation")
    func alreadyBound() async throws {
        let fixture = SchedulingAPIFixture([list(eventRow(bound: "stream")), list(streamRow())])
        let review = YouTubeBindingReview(event: .init(id: "event", provider: .youtube, channelID: "owner", title: "Event",
            state: .upcoming, boundStreamID: "stream", enableAutoStart: false, enableAutoStop: false),
            stream: .init(id: "stream", channelID: "owner", title: "Stream"))
        #expect(try await fixture.api.bindYouTube(review).boundStreamID == "stream")
        #expect(await fixture.calls().count == 2)
    }
    @Test("Foreign or live events, active/error/unknown streams and mismatched profiles cannot bind")
    func bindGuards() async throws {
        for event in [eventRow(owner: "foreign"), eventRow(state: "live"), eventRow(state: "complete"), eventRow(state: "testing")] {
            let fixture = SchedulingAPIFixture([list(event)])
            await #expect(throws: ProviderFailure.self) { try await fixture.api.reviewYouTubeBinding(eventID: "event", streamID: "stream", expectedChannelID: "owner") }
            #expect(await fixture.calls().count == 1)
        }
        for stream in [streamRow(owner: "foreign"), streamRow(state: "active"), streamRow(state: "created"),
                       streamRow(state: "error"), streamRow(resolution: "1080p", rate: "variable")] {
            let fixture = SchedulingAPIFixture([list(eventRow()), list(stream)])
            await #expect(throws: ProviderFailure.self) { try await fixture.api.reviewYouTubeBinding(eventID: "event", streamID: "stream", expectedChannelID: "owner") }
            #expect(await fixture.calls().count == 2)
        }
    }
    @Test("Lost creation and mismatched binding acknowledgements never trigger retry")
    func uncertain() async throws {
        let create = SchedulingAPIFixture([#"{"items":[{"id":"owner"}]}"#, #"{"error":"uncertain"}"#])
        await #expect(throws: ProviderFailure.self) { try await create.api.createYouTubeStream(.init(title: "Stream"), expectedChannelID: "owner") }
        #expect(await create.calls().count == 2)
        let bind = SchedulingAPIFixture([list(eventRow()), list(streamRow()), eventRow(bound: "wrong")])
        let review = YouTubeBindingReview(event: .init(id: "event", provider: .youtube, channelID: "owner", title: "Event",
            state: .upcoming, enableAutoStart: false, enableAutoStop: false), stream: .init(id: "stream", channelID: "owner", title: "Stream"))
        await #expect(throws: ProviderFailure.self) { try await bind.api.bindYouTube(review) }
        #expect(await bind.calls().count == 3)
    }
    @Test("Cached event ownership must match a fresh resource before native edit or delete")
    func cachedOwnerGuard() async throws {
        let foreign = list(eventRow(owner: "foreign"))
        let edit = SchedulingAPIFixture([foreign])
        await #expect(throws: ProviderFailure.self) {
            try await edit.api.editYouTubeEvent(id: "event", title: "Changed", description: "", scheduledAt: Date().addingTimeInterval(3600),
                privacy: .private, expectedChannelID: "owner")
        }
        #expect(await edit.calls().count == 1)
        let delete = SchedulingAPIFixture([foreign])
        await #expect(throws: ProviderFailure.self) { try await delete.api.deleteYouTubeEvent(id: "event", expectedChannelID: "owner") }
        #expect(await delete.calls().count == 1)
    }
    @Test("Existing provider-event documents decode without additive stream and automatic-setting fields")
    func legacyEvent() throws {
        let data = Data(#"{"id":"legacy","provider":"youtube","title":"Old","description":"","state":"unknown","verifiedAt":0}"#.utf8)
        let event = try JSONDecoder().decode(ProviderEvent.self, from: data)
        #expect(event.id == "legacy" && event.boundStreamID == nil && event.enableAutoStart == nil && event.enableAutoStop == nil)
    }
}
