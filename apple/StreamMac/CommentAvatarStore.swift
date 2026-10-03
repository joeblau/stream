import CoreGraphics
import Foundation
import ImageIO

/// Ephemeral pixels only. Saved scenes carry an opaque key, never the
/// provider URL/query, credentials, cookies, or downloaded image bytes.
final class CommentAvatarStore: @unchecked Sendable {
    static let shared = CommentAvatarStore()
    private let lock = NSLock()
    private var images: [String: CGImage] = [:]
    private var order: [String] = []
    func publish(_ image: CGImage) -> String {
        let key = "public-avatar-" + UUID().uuidString
        lock.lock(); defer { lock.unlock() }
        images[key] = image; order.append(key)
        while order.count > 32 { images.removeValue(forKey: order.removeFirst()) }
        return key
    }
    func image(_ key: String?) -> CGImage? {
        guard let key else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let image = images[key] {
            order.removeAll { $0 == key }; order.append(key)
            return image
        }
        return nil
    }
}

private final class CommentAvatarRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.flatMap { CommentAvatarLoader.accepts($0) ? request : nil })
    }
}

enum CommentAvatarLoader {
    /// Public provider image hosts only; metadata cannot turn this optional
    /// fetch into an arbitrary authenticated URL or a request to localhost.
    static func accepts(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.absoluteString.utf8.count <= 2048,
              let host = url.host?.lowercased() else { return false }
        return ["yt3.ggpht.com", "yt3.googleusercontent.com", "static-cdn.jtvnw.net", "pbs.twimg.com", "cdn.discordapp.com"].contains(host)
    }
    static func load(_ url: URL) async throws -> CGImage {
        try Task.checkCancellation()
        guard accepts(url) else { throw RecordingChatError.invalid("This public avatar image host is unsupported.") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 5; configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration, delegate: CommentAvatarRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        let (stream, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= 1_048_576,
              response.mimeType?.hasPrefix("image/") == true,
              response.url.map(accepts) == true else { throw RecordingChatError.invalid("Public avatar image was unavailable.") }
        var data = Data(); data.reserveCapacity(32_768)
        for try await byte in stream {
            try Task.checkCancellation()
            guard data.count < 1_048_576 else { throw RecordingChatError.invalid("Public avatar image exceeds its size limit.") }
            data.append(byte)
        }
        try Task.checkCancellation()
        return try decode(data)
    }
    static func decode(_ data: Data) throws -> CGImage {
        guard data.count <= 1_048_576, let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096, width * height <= 4_194_304,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw RecordingChatError.invalid("Public avatar image could not be decoded within its limits.")
        }
        return image
    }
}
