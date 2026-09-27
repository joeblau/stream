import AVFoundation
import CoreMedia
import StreamCore

/// Moves a `CMSampleBuffer` (not yet `Sendable`-annotated in CoreMedia on all
/// SDKs) across the hop from the compositor's callback thread onto the writer's
/// serial queue. The buffer is retained, so it stays valid until the queue
/// releases it.
private struct SendableSampleBuffer: @unchecked Sendable {
    let buffer: CMSampleBuffer
}

/// Records the composited program output to a local `.mp4` via `AVAssetWriter`,
/// fed from `StreamController.onCompositedSample`. Video only; audio is a v2
/// nicety and intentionally skipped.
///
/// The app sandbox denies `~/Movies` without user-selected-file entitlements, so
/// recordings land in the shared App Group container's `Recordings/` folder (the
/// same location the iOS app imports its backups from) via StreamCore's
/// `RecordingStore`, which also provides the timestamped naming and the
/// disk-space guard. The finished file's path is published on `lastRecordingURL`.
@MainActor
final class RecordingController: ObservableObject {
    @Published private(set) var isRecording = false
    /// Path of the most recent cleanly-finished recording; nil until one exists.
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var lastError: String?

    private let store = RecordingStore()
    /// Serializes every touch of the `AVAssetWriter` (appends, finish) against the
    /// compositor's callback thread.
    private let queue = DispatchQueue(label: "com.joeblau.StreamMac.recording")
    private var session: RecordingSession?
    private weak var stream: StreamController?

    /// Start if idle, stop (and finish the .mp4) if recording.
    func toggle(stream: StreamController) {
        isRecording ? stop() : start(stream: stream)
    }

    func start(stream: StreamController) {
        guard !isRecording else { return }
        lastError = nil
        guard store.hasSufficientSpace() else {
            lastError = "Not enough disk space to record (1 GB minimum)."
            return
        }
        guard let url = store.makeRecordingURL(date: Date()) else {
            lastError = "The recordings folder is unavailable (App Group container missing)."
            return
        }
        let session = RecordingSession(outputURL: url)
        self.session = session
        self.stream = stream
        // Note: this claims the single-consumer composited-sample hook for the
        // duration of the recording and hands it back on stop.
        stream.onCompositedSample = { [queue] sample in
            let box = SendableSampleBuffer(buffer: sample)
            queue.async { session.append(box.buffer) }
        }
        isRecording = true
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        stream?.onCompositedSample = nil
        stream = nil
        guard let session else { return }
        self.session = nil
        queue.async { [weak self, store] in
            session.finish { url in
                Task { @MainActor in
                    guard let self else { return }
                    if let url {
                        store.markComplete(url)
                        self.lastRecordingURL = url
                    } else {
                        self.lastError = "Recording could not be written."
                    }
                }
            }
        }
    }
}

/// One recording's writer state. `@unchecked Sendable`: every method runs on the
/// controller's serial `queue` only, so the writer and input are never touched
/// concurrently; the class is shared across threads solely through that queue.
private final class RecordingSession: @unchecked Sendable {
    private let outputURL: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var started = false
    private var failed = false

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    /// Appends one composited BGRA frame. The writer is configured lazily from the
    /// first frame's format description, so the input's dimensions/bitrate always
    /// match what the pipeline is actually producing.
    func append(_ sample: CMSampleBuffer) {
        guard !failed else { return }
        if writer == nil { configure(from: sample) }
        guard let writer, let input else { return }
        if writer.status == .failed { failed = true; return }

        if !started {
            // Begin on a sync frame so the file is decodable from byte zero.
            // (Composited BGRA frames are uncompressed, so they are all sync —
            // this only guards a future compressed tap.)
            guard Self.isSyncSample(sample) else { return }
            guard writer.startWriting() else { failed = true; return }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample))
            started = true
        }
        if input.isReadyForMoreMediaData {
            input.append(sample)
        }
    }

    /// Finishes the writer so the .mp4 is playable. Completes with the file URL on
    /// success, nil on failure or when no frame ever arrived (partial files are
    /// deleted). Called on the serial queue; the completion hops threads.
    func finish(completion: @escaping @Sendable (URL?) -> Void) {
        guard let input, started else {
            cleanupPartialFile()
            completion(nil)
            return
        }
        input.markAsFinished()
        // Capture `self` (Sendable) rather than the non-Sendable writer.
        writer?.finishWriting { [self] in
            if writer?.status == .completed {
                completion(outputURL)
            } else {
                try? FileManager.default.removeItem(at: outputURL)
                completion(nil)
            }
        }
    }

    // MARK: - Writer configuration

    private func configure(from sample: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let pixels = Double(dimensions.width) * Double(dimensions.height)
        // Same bits/pixel heuristic as StreamSettings.backupVideoBitrate: screen
        // content compresses well, so ~0.12 bpp looks clean at 30 fps.
        let bitrate = min(12_000_000, max(2_000_000, Int(pixels * 30 * 0.12)))

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(dimensions.width),
            AVVideoHeightKey: Int(dimensions.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: 30
            ]
        ]

        do {
            let writer = try AVAssetWriter(url: outputURL, fileType: .mp4)
            writer.shouldOptimizeForNetworkUse = true
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                failed = true
                return
            }
            writer.add(input)
            self.writer = writer
            self.input = input
        } catch {
            failed = true
        }
    }

    private func cleanupPartialFile() {
        try? FileManager.default.removeItem(at: outputURL)
    }

    private static func isSyncSample(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[String: Any]],
              let first = attachments.first else { return true }
        return (first[kCMSampleAttachmentKey_NotSync as String] as? Bool) != true
    }
}
