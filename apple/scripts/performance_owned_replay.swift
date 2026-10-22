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
    static func inventory(url: URL, workloadSeconds: Double) async throws -> PerformanceReplayInventory {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        let reader = try AVAssetReader(asset: asset)
        // Count compressed samples without decoding a second copy of the movie.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        defer { reader.cancelReading() }
        var count = 0, due = 0
        var first: Double?, previous: Double?, end = 0.0, monotonic = true
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            // Reader marker buffers carry no video samples or valid PTS.
            guard sample.numSamples > 0 else { continue }
            let pts = sample.presentationTimeStamp.seconds
            guard pts.isFinite else { throw CocoaError(.fileReadCorruptFile) }
            if first == nil { first = pts }
            if let previous, pts <= previous { monotonic = false }
            previous = pts
            let relative = pts - first!
            if relative < max(0, workloadSeconds - 5) { due += sample.numSamples }
            let duration = sample.duration.seconds
            end = max(end, relative + (duration.isFinite ? max(0, duration) : 0))
            count += sample.numSamples
        }
        guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        return .init(availableFrames: count, framesDueBeforeGraceEnd: due, durationSeconds: end, monotonic: monotonic)
    }
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
