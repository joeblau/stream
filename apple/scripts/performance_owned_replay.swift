import AVFoundation
import CoreMedia
import Foundation

/// Decodes the preceding owned recording on its real compressed media clock.
/// Holds one latest pixel buffer; this is offline footage, never camera access.
final class PerformanceOwnedReplay: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var frames = 0
    func frame(fallback: CVPixelBuffer) -> CVPixelBuffer { lock.lock(); defer { lock.unlock() }; return latest ?? fallback }
    var decodedFrames: Int { lock.lock(); defer { lock.unlock() }; return frames }
    func run(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        defer { reader.cancelReading() }
        let clock = ContinuousClock(), start = ContinuousClock.now
        var first: Double?
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let pts = sample.presentationTimeStamp.seconds
            if first == nil { first = pts }
            try await clock.sleep(until: start + .seconds(max(0, pts - first!)))
            if let buffer = sample.imageBuffer {
                lock.withLock { latest = buffer; frames += 1 }
            }
        }
        guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
    }
}
