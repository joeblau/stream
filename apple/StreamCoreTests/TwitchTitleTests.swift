import Foundation
import Testing
@testable import StreamCore

private actor TwitchTitleRequestFixture {
    private var requests: [URLRequest] = []
    func send(_ provider: ManagedProvider, _ request: URLRequest) throws -> Data {
        #expect(provider == .twitch)
        requests.append(request)
        return Data() // The successful PATCH has an empty response body.
    }
    func allRequests() -> [URLRequest] { requests }
    nonisolated var api: ProviderAPI { .init { try await self.send($0, $1) } }
}

@Suite struct TwitchTitleTests {
    private func acceptsUnchanged(_ title: String) async throws {
        let fixture = TwitchTitleRequestFixture()
        try await fixture.api.setTwitchTitle(channelID: "42", title: title)
        let requests = await fixture.allRequests()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.httpMethod == "PATCH" && request.url?.scheme == "https" && request.url?.host == "api.twitch.tv")
        #expect(request.url?.path == "/helix/channels")
        let query = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(query == [URLQueryItem(name: "broadcaster_id", value: "42")])
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(Set(object.keys) == ["title"])
        let encodedTitle = try #require(object["title"])
        // Swift String equality treats canonically equivalent strings as equal;
        // compare bytes to prove that this adapter did not normalize or trim.
        #expect(Array(encodedTitle.utf8) == Array(title.utf8))
    }

    @Test("A 140-character ASCII Twitch title sends exactly one unchanged PATCH")
    func asciiBoundary() async throws {
        try await acceptsUnchanged(String(repeating: "a", count: 140))
    }

    @Test("A 140-character CJK Twitch title sends exactly one unchanged PATCH")
    func cjkBoundary() async throws {
        let title = String(repeating: "界", count: 140)
        #expect(title.count == 140 && title.utf8.count == 420)
        try await acceptsUnchanged(title)
    }

    @Test("Twitch title validation preserves original Unicode representation and whitespace")
    func preservesText() async throws {
        for title in ["Café", "Cafe\u{301}", "  Title  "] {
            try await acceptsUnchanged(title)
        }
    }

    @Test("Empty and 141-character Twitch titles fail before any provider request")
    func refusesInvalidTitles() async throws {
        for title in ["", String(repeating: "a", count: 141), String(repeating: "界", count: 141)] {
            let fixture = TwitchTitleRequestFixture()
            do { try await fixture.api.setTwitchTitle(channelID: "42", title: title); Issue.record("Invalid title emitted a PATCH") }
            catch let failure as ProviderFailure { #expect(failure.kind == .invalidRequest) }
            #expect(await fixture.allRequests().isEmpty)
        }
    }
}
