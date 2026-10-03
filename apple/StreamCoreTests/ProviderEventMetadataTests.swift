import Foundation
import Testing
@testable import StreamCore

private actor EventMetadataHTTP {
    let body: Data
    var requests: [URLRequest] = []
    init(_ body: Data) { self.body = body }
    func send(_ provider: ManagedProvider, _ request: URLRequest) -> Data {
        requests.append(request)
        return body
    }
    nonisolated var api: ProviderAPI { .init { await self.send($0, $1) } }
    func calls() -> [URLRequest] { requests }
}

@Suite struct ProviderEventMetadataTests {
    private func response(latency: Any? = "low", thumbnails: Any? = nil) throws -> Data {
        var details: [String: Any] = ["boundStreamId": "stream1", "enableAutoStart": false, "enableAutoStop": true,
                                      "ingestionInfo": ["streamName": "PRIVATE_INGEST_FIXTURE"]]
        if let latency { details["latencyPreference"] = latency }
        var snippet: [String: Any] = ["channelId": "UC1", "title": "Production", "description": "Provider metadata",
                                     "scheduledStartTime": "2030-01-01T00:00:00Z"]
        if let thumbnails { snippet["thumbnails"] = thumbnails }
        return try JSONSerialization.data(withJSONObject: ["items": [["id": "event1", "snippet": snippet, "contentDetails": details,
                            "status": ["lifeCycleStatus": "live", "privacyStatus": "unlisted"]]]])
    }
    @Test("Existing event GETs map documented latency preferences and all thumbnail sizes without extra requests")
    func documentedMetadata() async throws {
        var thumbnails: [String: Any] = [:]
        for size in YouTubeThumbnail.Size.allCases {
            thumbnails[size.rawValue] = ["url": "https://i9.ytimg.com/vi/event1/\(size.rawValue).jpg?sqp=public&rs=public",
                                         "width": 3_840, "height": 2_160]
        }
        for (raw, expected) in [("normal", ProviderEvent.LatencyPreference.normal), ("low", .low), ("ultraLow", .ultraLow)] {
            let http = try EventMetadataHTTP(response(latency: raw, thumbnails: thumbnails))
            let event = try await http.api.youtubeEvent(id: "event1")
            #expect(event.latencyPreference == expected)
            #expect(event.thumbnails?.map(\.size) == YouTubeThumbnail.Size.allCases)
            #expect(event.thumbnails?.allSatisfy { $0.width == 3_840 && $0.height == 2_160 } == true)
            #expect(event.channelID == "UC1" && event.title == "Production" && event.description == "Provider metadata")
            #expect(event.privacy == "unlisted" && event.state == .live && event.scheduledAt != nil)
            #expect(event.boundStreamID == "stream1" && event.enableAutoStart == false && event.enableAutoStop == true)
            let encoded = try JSONEncoder().encode(event)
            #expect(try JSONDecoder().decode(ProviderEvent.self, from: encoded) == event)
            #expect(!String(decoding: encoded, as: UTF8.self).contains("PRIVATE_INGEST_FIXTURE"))
            let calls = await http.calls()
            #expect(calls.count == 1 && calls[0].httpMethod == "GET" && calls[0].url?.path == "/youtube/v3/liveBroadcasts")
            #expect(URLComponents(url: calls[0].url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "part" }?.value == "snippet,status,contentDetails")
        }
        let upcomingHTTP = try EventMetadataHTTP(response(latency: "ultraLow", thumbnails: thumbnails))
        #expect(try await upcomingHTTP.api.upcoming(.youtube).first?.latencyPreference == .ultraLow)
        #expect(await upcomingHTTP.calls().count == 1)
    }
    @Test("Absent, unfamiliar and malformed latency remain explicitly unknown, independently of lifecycle")
    func unknownMetadata() async throws {
        let unknown: [Any?] = [nil, "futureLatency", true, 42, ["mode": "low"]]
        for value in unknown {
            let http = try EventMetadataHTTP(response(latency: value))
            let event = try await http.api.youtubeEvent(id: "event1")
            #expect(event.latencyPreference == .unknown && event.state == .live && event.thumbnails == nil)
        }
        let empty = try EventMetadataHTTP(response(thumbnails: [:]))
        #expect(try await empty.api.youtubeEvent(id: "event1").thumbnails == [])
        let malformed = try EventMetadataHTTP(response(thumbnails: "not-a-map"))
        #expect(try await malformed.api.youtubeEvent(id: "event1").thumbnails == nil)
        #expect(ProviderEvent.LatencyPreference.unknown.label == "Unknown")
    }
    @Test("Only bounded public CDN image descriptors survive API normalization; unsafe optional fields do not alter event state")
    func rejectedDescriptors() async throws {
        let safe = "https://i.ytimg.com/vi/event1/high.jpg"
        var rejected: [[String: Any]] = [
            ["url": "http://i.ytimg.com/vi/event1/high.jpg"],
            ["url": "https://user:PRIVATE_FIXTURE@i.ytimg.com/vi/event1/high.jpg"],
            ["url": "https://i.ytimg.com.evil.invalid/vi/event1/high.jpg"],
            ["url": "https://127.0.0.1/high.jpg"],
            ["url": "https://i.ytimg.com:8443/vi/event1/high.jpg"],
            ["url": "https://i.ytimg.com/vi/event1/high.jpg#PRIVATE_FIXTURE"],
            ["url": "https://i.ytimg.com/vi/event1/high.jpg?access_token=PRIVATE_FIXTURE"],
            ["url": "https://i.ytimg.com/" + String(repeating: "x", count: 4_096)],
            ["url": "https://i.ytimg.com/vi/event1/\nhigh.jpg"],
            ["url": "https://i.ytimg.com/vi/event1/%0Ahigh.jpg"],
            ["url": safe, "width": 0], ["url": safe, "height": -1],
            ["url": safe, "width": 16_385], ["url": safe, "height": 1.25],
            ["url": safe, "width": true], ["url": safe, "height": "1080"],
            ["url": safe, "width": NSNull()]
        ]
        rejected.append(["url": safe + "?" + (0..<9).map { "rs=\($0)" }.joined(separator: "&")])
        rejected.append(["url": safe + "?sqp=" + String(repeating: "a", count: 2_049)])
        for thumbnail in rejected {
            let http = try EventMetadataHTTP(response(thumbnails: ["high": thumbnail]))
            let event = try await http.api.youtubeEvent(id: "event1")
            #expect(event.thumbnails == [] && event.state == .live && event.latencyPreference == .low)
            #expect(!String(decoding: try JSONEncoder().encode(event), as: UTF8.self).contains("PRIVATE_FIXTURE"))
            #expect(await http.calls().count == 1)
        }
    }
    @Test("Missing dimensions and known CDN variants remain usable; unknown size keys never leak into metadata")
    func partialDimensions() async throws {
        let http = try EventMetadataHTTP(response(thumbnails: [
            "default": ["url": "https://i.ytimg.com/vi/event1/default.jpg"],
            "high": ["url": "https://lh3.googleusercontent.com/public-image", "width": 1, "height": 16_384],
            "futureSize": ["url": "https://ingest.invalid/live?key=PRIVATE_FIXTURE"]
        ]))
        let event = try await http.api.youtubeEvent(id: "event1"), values = try #require(event.thumbnails)
        #expect(values.map(\.size) == [.default, .high])
        #expect(values[0].width == nil && values[0].height == nil)
        #expect(values[1].width == 1 && values[1].height == 16_384)
        #expect(!String(decoding: try JSONEncoder().encode(event), as: UTF8.self).contains("PRIVATE_FIXTURE"))
        let duplicate = ProviderEvent(id: "id", provider: .youtube, title: "", thumbnails: values + values)
        #expect(duplicate.thumbnails == values)
    }
    @Test("Legacy documents decode without new fields, unknown future latency decodes safely, and new metadata round-trips")
    func documentCompatibility() throws {
        let legacy = Data(#"{"id":"legacy","provider":"youtube","title":"Old event","description":"Old description","state":"unknown","verifiedAt":0}"#.utf8)
        let event = try JSONDecoder().decode(ProviderEvent.self, from: legacy)
        #expect(event.latencyPreference == nil && event.thumbnails == nil && event.boundStreamID == nil)
        var object = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        object["latencyPreference"] = "futureLatency"
        let future = try JSONDecoder().decode(ProviderEvent.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(future.latencyPreference == .unknown && future.state == .unknown)
        object["latencyPreference"] = true
        #expect(try JSONDecoder().decode(ProviderEvent.self, from: JSONSerialization.data(withJSONObject: object)).latencyPreference == .unknown)
        let image = try #require(YouTubeThumbnail(size: .high, url: URL(string: "https://i.ytimg.com/vi/legacy/high.jpg")!, width: 480, height: 360))
        let current = ProviderEvent(id: "legacy", provider: .youtube, title: "Old event", latencyPreference: .ultraLow, thumbnails: [image])
        #expect(try JSONDecoder().decode(ProviderEvent.self, from: JSONEncoder().encode(current)) == current)
    }
    @Test("Decoded documents enforce thumbnail bounds, unique sizes and the same public URL policy as API reads")
    func documentBounds() throws {
        let base = ProviderEvent(id: "event", provider: .youtube, title: "Legacy")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        let safe: [String: Any] = ["size": "high", "url": "https://i.ytimg.com/vi/event/high.jpg", "width": 480, "height": 360]
        let eight: [[String: Any]] = YouTubeThumbnail.Size.allCases.map { size in
            ["size": size.rawValue, "url": "https://i.ytimg.com/vi/event/\(size.rawValue).jpg"]
        }
        object["thumbnails"] = eight
        #expect(try JSONDecoder().decode(ProviderEvent.self, from: JSONSerialization.data(withJSONObject: object)).thumbnails?.count == 8)
        for thumbnails in [[safe, safe], eight + [safe],
                           [["size": "high", "url": "https://ingest.invalid/live?key=PRIVATE_FIXTURE"]],
                           [["size": "high", "url": "https://i.ytimg.com/high.jpg", "width": 16_385]],
                           [["size": "high", "url": "https://i.ytimg.com/high.jpg", "height": true]]] {
            object["thumbnails"] = thumbnails
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(ProviderEvent.self, from: JSONSerialization.data(withJSONObject: object)) }
        }
    }
}
