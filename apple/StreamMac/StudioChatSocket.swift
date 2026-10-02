import Foundation

protocol StudioChatSocket: AnyObject, Sendable {
    func receive() async throws -> Data
    func cancel()
}
/// A single bounded public EventSub socket. No tokens are placed in its URL.
final class NativeStudioChatSocket: StudioChatSocket, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    init(_ url: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.urlCache = nil
        session = URLSession(configuration: configuration)
        task = session.webSocketTask(with: url); task.maximumMessageSize = 262_144; task.resume()
    }
    func receive() async throws -> Data {
        try Task.checkCancellation()
        let message = try await task.receive()
        try Task.checkCancellation()
        switch message {
        case .data(let data): return data
        case .string(let text): return Data(text.utf8)
        @unknown default: throw URLError(.cannotParseResponse)
        }
    }
    func cancel() { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
    deinit { cancel() }
}
