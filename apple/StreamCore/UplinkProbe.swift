import Foundation

public struct UplinkProbeResult: Equatable, Sendable {
    public var uploadedBytes: Int
    public var duration: Double
    public var megabitsPerSecond: Double { Double(uploadedBytes) * 8 / max(duration, 0.001) / 1_000_000 }
    public init(uploadedBytes: Int, duration: Double) { self.uploadedBytes = uploadedBytes; self.duration = duration }
}

/// Explicit short HTTP upload estimate, not a public broadcast and not a promise
/// about a provider ingest route. At most 32 MiB of payload, bounded duration.
/// Endpoint documented at https://github.com/cloudflare/speedtest#configuration
public struct UplinkProbe: Sendable {
    public static let endpoint = URL(string: "https://speed.cloudflare.com/__up")!
    public static let maximumPayloadBytes = 32 * 1024 * 1024
    public static let durationSeconds = 10.0
    public typealias Upload = @Sendable (URLRequest, Data) async throws -> Int
    private let upload: Upload
    private let clock: @Sendable () -> Double

    public init(upload: @escaping Upload, clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.upload = upload
        self.clock = clock
    }

    public init(session: URLSession) {
        self.init(upload: { request, payload in
            let (_, response) = try await session.upload(for: request, from: payload)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        })
    }

    public func run(onProgress: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> UplinkProbeResult {
        let started = clock()
        var payloadBytes = 64 * 1024
        var uploaded = 0
        while uploaded < Self.maximumPayloadBytes && clock() - started < Self.durationSeconds {
            try Task.checkCancellation()
            var request = URLRequest(url: Self.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = max(0.1, Self.durationSeconds - (clock() - started))
            let payload = Data(repeating: 0x5A, count: min(payloadBytes, Self.maximumPayloadBytes - uploaded))
            let status: Int
            do { status = try await upload(request, payload) }
            catch {
                try Task.checkCancellation()
                // The hard deadline can cancel an in-progress ramp request.
                // Acknowledge only earlier successful bytes over the full test
                // interval: this is a conservative lower bound on that route.
                if uploaded > 0 && clock() - started >= Self.durationSeconds - 0.2,
                   let failure = error as? URLError, [.timedOut, .cancelled].contains(failure.code) { break }
                throw error
            }
            try Task.checkCancellation()
            guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
            uploaded += payload.count
            onProgress(uploaded)
            payloadBytes = min(payloadBytes * 2, 1024 * 1024)
        }
        guard uploaded > 0 else { throw URLError(.zeroByteResource) }
        return UplinkProbeResult(uploadedBytes: uploaded, duration: max(0.001, clock() - started))
    }
}
