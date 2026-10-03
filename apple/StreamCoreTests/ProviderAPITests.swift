import Foundation
import Testing
@testable import StreamCore

private actor ProviderFixture {
    var replies: [Data]
    var requests: [URLRequest] = []
    init(_ values: [String]) { replies = values.map { Data($0.utf8) } }
    func send(_ provider: ManagedProvider, _ request: URLRequest) throws -> Data {
        requests.append(request)
        guard !replies.isEmpty else { throw ProviderFailure(.unavailable) }
        return replies.removeFirst()
    }
    nonisolated var api: ProviderAPI { ProviderAPI { try await self.send($0, $1) } }
    func allRequests() -> [URLRequest] { requests }
}
private final class ProviderClock: @unchecked Sendable {
    let lock = NSLock()
    var date = Date(timeIntervalSince1970: 1_000)
    var waits: [Double] = []
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; waits.append(seconds); date += seconds }
    func sleeps() -> [Double] { lock.lock(); defer { lock.unlock() }; return waits }
}

@Suite struct ProviderAPITests {
    @Test("Desktop PKCE uses RFC7636 S256 and exact loopback/state validation")
    func pkce() throws {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(ProviderOAuth.challenge(verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let state = String(repeating: "s", count: 43), redirect = URL(string: "http://127.0.0.1:49201/oauth/callback")!
        let url = try ProviderOAuth.googleAuthorization(clientID: "desktop-client", redirect: redirect, state: state, verifier: verifier)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.host == "accounts.google.com")
        #expect(query.first { $0.name == "code_challenge_method" }?.value == "S256")
        #expect(!query.contains { $0.name == "client_secret" })
        #expect(try ProviderOAuth.googleCode(URL(string: "\(redirect)?code=a%2Bb%26c&state=\(state)")!, redirect: redirect, state: state) == "a+b&c")
        for bad in ["http://localhost:49201/oauth/callback?code=x&state=\(state)", "http://127.0.0.1:49202/oauth/callback?code=x&state=\(state)", "\(redirect)?code=x&state=wrong", "\(redirect)?code=x&code=y&state=\(state)", "\(redirect)?code=x&state=\(state)&error=denied", "\(redirect)?code=x&state=\(state)#fragment"] {
            #expect(throws: ProviderFailure.self) { try ProviderOAuth.googleCode(URL(string: bad)!, redirect: redirect, state: state) }
        }
        #expect(try ProviderOAuth.randomURLSafe().count == 43)
    }
    @Test("Form encoding preserves plus, ampersands and Unicode; refresh retains nonrotated token")
    func tokens() throws {
        #expect(String(decoding: ProviderOAuth.form(["code": "a+b&中", "redirect_uri": "streamchat://oauth"]), as: UTF8.self) == "code=a%2Bb%26%E4%B8%AD&redirect_uri=streamchat%3A%2F%2Foauth")
        let previous = ProviderOAuthToken(access: "old", refresh: "r+&", expiresAt: .distantPast, scopes: ["scope"])
        let token = try ProviderOAuthToken.parse(Data(#"{"access_token":"new","expires_in":3600}"#.utf8), previous: previous, now: .init(timeIntervalSince1970: 0))
        #expect(token.refresh == "r+&" && token.scopes == ["scope"] && token.expiresAt.timeIntervalSince1970 == 3600)
        #expect(throws: ProviderFailure.self) { try ProviderOAuthToken.parse(Data(#"{"access_token":"new","expires_in":0}"#.utf8)) }
    }
    @Test("Channel discovery follows pagination and deduplicates stable IDs")
    func channels() async throws {
        let fixture = ProviderFixture([#"{"items":[{"id":"UC1","snippet":{"title":"First"}}],"nextPageToken":"p+&"}"#, #"{"items":[{"id":"UC1","snippet":{"title":"Updated"}},{"id":"UC2","snippet":{"title":"Second"}}]}"#])
        let channels = try await fixture.api.channels(.youtube)
        #expect(channels.map(\.id) == ["UC1", "UC2"] && channels[0].title == "Updated")
        let requests = await fixture.allRequests()
        #expect(requests.count == 2)
        #expect(URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "pageToken" }?.value == "p+&")
    }
    @Test("Repeated provider page token fails instead of claiming a complete list")
    func repeatedPage() async throws {
        let fixture = ProviderFixture([#"{"items":[],"nextPageToken":"cycle"}"#, #"{"items":[],"nextPageToken":"cycle"}"#])
        await #expect(throws: ProviderFailure.self) { try await fixture.api.channels(.youtube) }
    }
    @Test("Only verified event lifecycle values are mapped, including fractional schedules")
    func events() async throws {
        let fixture = ProviderFixture([#"{"items":[{"id":"event1","snippet":{"channelId":"UC1","title":"Scheduled","scheduledStartTime":"2026-10-03T01:02:03.000Z"},"status":{"lifeCycleStatus":"ready","privacyStatus":"private"}},{"id":"event1","snippet":{"title":"Updated"},"status":{"lifeCycleStatus":"liveStarting"}}]}"#, #"{"items":[{"id":"event2","snippet":{"title":"Done"},"status":{"lifeCycleStatus":"complete"}}]}"#])
        let api = fixture.api, events = try await api.upcoming(.youtube)
        #expect(events.count == 1 && events[0].state == .unknown && events[0].title == "Updated")
        #expect(try await api.youtubeEvent(id: "event2").state == .ended)
        let dateFixture = ProviderFixture([#"{"items":[{"id":"fraction","snippet":{"scheduledStartTime":"2026-10-03T01:02:03.000Z"},"status":{"lifeCycleStatus":"ready"}}]}"#])
        #expect(try await dateFixture.api.upcoming(.youtube).first?.scheduledAt != nil)
    }
    @Test("Unavailable viewer data stays unavailable and unsupported APIs make no request")
    func absentData() async throws {
        let fixture = ProviderFixture([#"{"data":[]}"#, #"{"items":[{"id":"event","liveStreamingDetails":{}}]}"#])
        let api = fixture.api
        #expect(try await api.twitchViewers(channelID: "42") == nil)
        #expect(try await api.youtubeViewers(eventID: "event") == nil)
        await #expect(throws: ProviderFailure.self) { try await api.upcoming(.twitch) }
        await #expect(throws: ProviderFailure.self) { try await api.channels(.facebookPages) }
        await #expect(throws: ProviderFailure.self) { try await api.channels(.linkedinLive) }
        #expect(await fixture.allRequests().count == 2)
    }
    @Test("Create returns actual event ID, safe defaults and absolute schedule without retries")
    func create() async throws {
        let fixture = ProviderFixture([#"{"id":"actual-ID","snippet":{"channelId":"UC1","title":"Created"},"status":{"lifeCycleStatus":"created","privacyStatus":"private"}}"#])
        let event = try await fixture.api.createYouTubeEvent(.init(title: "Created"))
        #expect(event.id == "actual-ID" && event.state == .upcoming)
        let requests = await fixture.allRequests(), request = try #require(requests.first)
        #expect(requests.count == 1 && request.httpMethod == "POST")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect((body["contentDetails"] as? [String: Bool]) == ["enableAutoStart": false, "enableAutoStop": false])
        #expect((body["status"] as? [String: String])?["privacyStatus"] == "private")
    }
    @Test("Snippet edits preserve category/end date and never overwrite privacy or auto-start")
    func edit() async throws {
        let fixture = ProviderFixture([#"{"items":[{"id":"event","etag":"etag1","snippet":{"title":"Old","description":"Old","categoryId":"20","scheduledStartTime":"2030-01-01T00:00:00Z","scheduledEndTime":"2030-01-02T00:00:00Z"},"status":{"lifeCycleStatus":"ready","privacyStatus":"private"}}]}"#, #"{"id":"event","snippet":{"title":"New","scheduledStartTime":"2030-01-01T01:00:00Z"}}"#])
        let date = ISO8601DateFormatter().date(from: "2030-01-01T01:00:00Z")!
        let event = try await fixture.api.editYouTubeEvent(id: "event", title: "New", description: "Changed", scheduledAt: date)
        #expect(event.privacy == "private" && event.state == .upcoming)
        let request = try #require(await fixture.allRequests().last)
        #expect(request.httpMethod == "PUT" && request.value(forHTTPHeaderField: "If-Match") == "etag1")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(body["status"] == nil && body["contentDetails"] == nil)
        #expect((body["snippet"] as? [String: String])?["categoryId"] == "20")
        #expect((body["snippet"] as? [String: String])?["scheduledEndTime"] == "2030-01-02T00:00:00Z")
    }
    @Test("Explicit privacy edits preserve snippet fields and content settings; mismatched acknowledgements fail")
    func privacyEdit() async throws {
        let old = #"{"items":[{"id":"event","etag":"v1","snippet":{"categoryId":"20","scheduledEndTime":"2030-01-02T00:00:00Z"},"status":{"lifeCycleStatus":"ready","privacyStatus":"private"}}]}"#
        let reply = #"{"id":"event","snippet":{"title":"New"},"status":{"lifeCycleStatus":"ready","privacyStatus":"unlisted"}}"#
        let fixture = ProviderFixture([old, reply])
        let date = ISO8601DateFormatter().date(from: "2030-01-01T01:00:00Z")!
        let event = try await fixture.api.editYouTubeEvent(id: "event", title: "New", description: "Unicode 🎬", scheduledAt: date, privacy: .unlisted)
        #expect(event.privacy == "unlisted" && event.state == .upcoming)
        let request = try #require(await fixture.allRequests().last)
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(request.value(forHTTPHeaderField: "If-Match") == "v1")
        #expect(body["contentDetails"] == nil)
        #expect((body["status"] as? [String: String]) == ["privacyStatus": "unlisted"])
        #expect((body["snippet"] as? [String: String])?["categoryId"] == "20")
        let uncertain = ProviderFixture([old, #"{"id":"other","status":{"privacyStatus":"unlisted"}}"#])
        await #expect(throws: ProviderFailure.self) { try await uncertain.api.editYouTubeEvent(id: "event", title: "New", description: "", scheduledAt: date, privacy: .unlisted) }
        #expect(await uncertain.allRequests().count == 2)
    }
    @Test("Thumbnail upload verifies owner, sends exact bounded media once and requires a receipt")
    func thumbnailUpload() async throws {
        let owned = #"{"items":[{"id":"event","snippet":{"channelId":"owner"},"status":{"lifeCycleStatus":"ready"}}]}"#
        let image = Data([137,80,78,71,13,10,26,10,0])
        let fixture = ProviderFixture([owned, #"{"kind":"youtube#thumbnailSetResponse","items":[{"default":{"url":"https://i.ytimg.com/vi/event/default.jpg","width":120,"height":90}}]}"#])
        #expect(try await fixture.api.uploadYouTubeThumbnail(eventID: "event", expectedChannelID: "owner", image: image, mimeType: "image/png").id == "event")
        let requests = await fixture.allRequests(), request = try #require(requests.last)
        #expect(requests.count == 2 && request.httpMethod == "POST")
        #expect(request.url?.path == "/upload/youtube/v3/thumbnails/set" && request.httpBody == image)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "image/png")
        let wrong = ProviderFixture([owned])
        await #expect(throws: ProviderFailure.self) { try await wrong.api.uploadYouTubeThumbnail(eventID: "event", expectedChannelID: "other", image: image, mimeType: "image/png") }
        #expect(await wrong.allRequests().count == 1)
        let malformed = ProviderFixture([owned, #"{"kind":"youtube#thumbnailSetResponse","items":[]}"#])
        await #expect(throws: ProviderFailure.self) { try await malformed.api.uploadYouTubeThumbnail(eventID: "event", expectedChannelID: "owner", image: image, mimeType: "image/png") }
        #expect(await malformed.allRequests().count == 2)
        let invalid = ProviderFixture([])
        for data in [Data(), Data(repeating: 0, count: 2_097_153)] {
            await #expect(throws: ProviderFailure.self) { try await invalid.api.uploadYouTubeThumbnail(eventID: "event", expectedChannelID: "owner", image: data, mimeType: "image/png") }
        }
        #expect(await invalid.allRequests().isEmpty)
    }
    @Test("Complete reads live state and explicitly transitions one remote ID")
    func complete() async throws {
        let fixture = ProviderFixture([#"{"items":[{"id":"live","status":{"lifeCycleStatus":"live"}}]}"#, #"{"id":"live","status":{"lifeCycleStatus":"complete"}}"#])
        #expect(try await fixture.api.completeYouTubeEvent(id: "live").state == .ended)
        let request = try #require(await fixture.allRequests().last)
        #expect(request.httpMethod == "POST")
        #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "broadcastStatus" }?.value == "complete")
    }
    @Test("Ending verifies fresh owner and completion acknowledgement; uncertain mutations stay unknown")
    func endingReceipts() async throws {
        let live = #"{"items":[{"id":"event","snippet":{"channelId":"owner"},"status":{"lifeCycleStatus":"live"}}]}"#
        let completed = #"{"id":"event","snippet":{"channelId":"owner"},"status":{"lifeCycleStatus":"complete"}}"#
        let fixture = ProviderFixture([live, completed])
        let result = await fixture.api.endYouTubeEvent(id: "event", expectedChannelID: "owner")
        #expect(result.disposition == .ended && result.confirmsEnd && result.event?.id == "event")
        let calls = await fixture.allRequests()
        #expect(calls.count == 2 && calls[0].httpMethod == "GET" && calls[1].httpMethod == "POST")
        #expect(URLComponents(url: calls[1].url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value == "event")
        let wrongOwner = ProviderFixture([live])
        #expect(await wrongOwner.api.endYouTubeEvent(id: "event", expectedChannelID: "another").disposition == .blocked)
        #expect(await wrongOwner.allRequests().count == 1)
        for uncertain in [#"{"id":"different","snippet":{"channelId":"owner"},"status":{"lifeCycleStatus":"complete"}}"#,
                          #"{"id":"event","snippet":{"channelId":"owner"},"status":{"lifeCycleStatus":"live"}}"#,
                          #"{"id":"event","snippet":{"channelId":"owner"},"status":{"lifeCycleStatus":"revoked"}}"#] {
            let response = ProviderFixture([live, uncertain])
            let receipt = await response.api.endYouTubeEvent(id: "event", expectedChannelID: "owner")
            #expect(receipt.disposition == .unconfirmed && !receipt.confirmsEnd && receipt.event == nil)
            #expect(await response.allRequests().count == 2)
        }
        let lostReply = ProviderFixture([live])
        #expect(await lostReply.api.endYouTubeEvent(id: "event", expectedChannelID: "owner").disposition == .unconfirmed)
        #expect(await lostReply.allRequests().count == 2) // single mutation, no retry
    }
    @Test("Already ended and review-only calls never mutate; upcoming is not deleted")
    func endingReview() async throws {
        let ended = #"{"items":[{"id":"event","snippet":{"channelId":"owner"},"status":{"lifeCycleStatus":"complete"}}]}"#
        let fixture = ProviderFixture([ended, ended])
        #expect(await fixture.api.endYouTubeEvent(id: "event", expectedChannelID: "owner").disposition == .alreadyEnded)
        let review = await fixture.api.reviewYouTubeEnd(id: "event", expectedChannelID: "owner")
        #expect(review.disposition == .observed && review.confirmsEnd)
        #expect(await fixture.allRequests().allSatisfy { $0.httpMethod == "GET" })
        let upcoming = ProviderFixture([#"{"items":[{"id":"event","snippet":{"channelId":"owner"},"status":{"lifeCycleStatus":"ready"}}]}"#])
        #expect(await upcoming.api.endYouTubeEvent(id: "event", expectedChannelID: "owner").disposition == .blocked)
        #expect(await upcoming.allRequests().count == 1)
    }
    @Test("Only bound documented ingest credentials leave the adapter, never portable metadata")
    func ingest() async throws {
        let fixture = ProviderFixture([#"{"items":[{"contentDetails":{"boundStreamId":"stream1"}}]}"#, #"{"items":[{"cdn":{"ingestionType":"rtmp","ingestionInfo":{"streamName":"SECRET_FIXTURE","ingestionAddress":"rtmp://ingest.invalid/live","rtmpsIngestionAddress":"rtmps://ingest.invalid/live"}}}]}"#])
        let connection = try await fixture.api.youtubeIngest(eventID: "event1")
        #expect(connection.endpoint == "rtmps://ingest.invalid/live" && connection.streamKey == "SECRET_FIXTURE")
        let destination = StreamDestination(name: "YT", providerBinding: .init(provider: .youtube, channelID: "UC1", eventID: "event1"))
        let data = try JSONEncoder().encode(destination)
        #expect(!String(decoding: data, as: UTF8.self).contains("SECRET_FIXTURE"))
        #expect(try JSONDecoder().decode(StreamDestination.self, from: data).providerBinding?.eventID == "event1")
    }
    @Test("Provider errors redact raw bodies and distinguish quota/permission/authorization")
    func errors() throws {
        let secret = Data(#"{"error":{"message":"SECRET_FIXTURE","errors":[{"reason":"quotaExceeded"}]}}"#.utf8)
        let response = HTTPURLResponse(url: URL(string: "https://www.googleapis.com")!, statusCode: 403, httpVersion: nil, headerFields: ["Retry-After": "20"])!
        do { try ProviderFailure.check(data: secret, response: response); Issue.record("Expected failure") }
        catch let error as ProviderFailure { #expect(error.kind == .rateLimited && error.retryAfter == 20); #expect(!error.localizedDescription.contains("SECRET_FIXTURE")) }
        #expect(ProviderChannel.publicLink(URL(string: "https://example.invalid/watch?token=SECRET")) == nil)
        #expect(throws: ProviderFailure.self) { try ProviderAPI.request(.youtube, path: "/../oauth") }
    }
    @Test("Public Twitch device flow honors pending, slow_down, scopes and expiry")
    func device() async throws {
        let fixture = ProviderFixture([#"{"device_code":"device+&","user_code":"ABCD","verification_uri":"https://www.twitch.tv/activate","expires_in":60,"interval":2}"#, #"{"message":"authorization_pending"}"#, #"{"message":"slow_down"}"#, #"{"access_token":"access","refresh_token":"rotated","expires_in":3600,"scope":["channel:read:stream_key"]}"#])
        let clock = ProviderClock()
        let flow = TwitchDeviceAuthorization(send: { request in
            let data = try await fixture.send(.twitch, request)
            let status = String(decoding: data, as: UTF8.self).contains("message") ? 400 : 200
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }, sleep: { clock.advance($0) }, now: { clock.now() })
        let token = try await flow.authorize(clientID: "public-client") { prompt in #expect(prompt.userCode == "ABCD") }
        #expect(token.refresh == "rotated" && clock.sleeps() == [2, 2, 7])
        let requests = await fixture.allRequests()
        let body = String(decoding: requests[1].httpBody!, as: UTF8.self)
        #expect(body.contains("device_code=device%2B%26") && !body.contains("client_secret"))
        #expect(body.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"))
    }
    @Test("Twitch chat grants are explicit and unsupported scopes never reach OAuth")
    func chatScopes() async throws {
        let fixture = ProviderFixture([#"{"device_code":"device","user_code":"ABCD","verification_uri":"https://www.twitch.tv/activate","expires_in":60,"interval":1}"#,
            #"{"access_token":"access","expires_in":3600,"scope":["user:read:chat","user:write:chat"]}"#])
        let clock = ProviderClock()
        let flow = TwitchDeviceAuthorization(send: { request in
            let data = try await fixture.send(.twitch, request)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, sleep: { clock.advance($0) }, now: clock.now)
        let token = try await flow.authorize(clientID: "public", additionalScopes: ["user:read:chat", "user:write:chat", "user:read:chat"]) { _ in }
        #expect(token.scopes == ["user:read:chat", "user:write:chat"])
        let requests = await fixture.allRequests()
        let form = String(decoding: requests[0].httpBody!, as: UTF8.self)
        #expect(form.contains("user%3Aread%3Achat") && form.contains("user%3Awrite%3Achat"))
        #expect(!form.contains("moderator%3Amanage%3Achat_messages"))
        #expect(!form.contains("moderator%3Amanage%3Abanned_users"))
        await #expect(throws: ProviderFailure.self) { try await flow.authorize(clientID: "public", additionalScopes: ["unknown:scope"]) { _ in } }
        #expect(await fixture.allRequests().count == 2)
    }
    @Test("Twitch timeouts and bans request only the explicitly selected optional grant")
    func banScopeOptIn() async throws {
        let fixture = ProviderFixture([#"{"device_code":"device","user_code":"ABCD","verification_uri":"https://www.twitch.tv/activate","expires_in":60,"interval":1}"#,
            #"{"access_token":"access","expires_in":3600,"scope":["moderator:manage:banned_users"]}"#])
        let clock = ProviderClock()
        let flow = TwitchDeviceAuthorization(send: { request in
            let data = try await fixture.send(.twitch, request)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, sleep: { clock.advance($0) }, now: clock.now)
        let token = try await flow.authorize(clientID: "public", additionalScopes: ["moderator:manage:banned_users"]) { _ in }
        #expect(token.scopes == ["moderator:manage:banned_users"])
        let requests = await fixture.allRequests()
        let form = String(decoding: requests[0].httpBody!, as: UTF8.self)
        #expect(form.contains("moderator%3Amanage%3Abanned_users"))
        #expect(!form.contains("user%3Aread%3Achat") && !form.contains("user%3Awrite%3Achat"))
    }
}
