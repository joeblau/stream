import Foundation
import StreamCore

/// OAuth and authorized APIs use fixed documented HTTPS hosts. Reject redirects
/// rather than forwarding codes, refresh tokens or a bearer to a new location.
final class ProviderHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = ProviderHTTP()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    private let lock = NSLock()
    private func client() -> URLSession { lock.lock(); defer { lock.unlock() }; return session }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await client().bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderFailure(.invalidResponse) }
        var data = Data()
        for try await byte in bytes {
            if data.count >= 2_097_152 { throw ProviderFailure(.invalidResponse) }
            data.append(byte)
        }
        return (data, http)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
