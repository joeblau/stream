import AVFoundation
import CoreMedia
import StreamCore

/// Records the composited program output to a local `.mp4` via `AVAssetWriter`,
/// fed from its own `CompositionEngine` subscription (W08, issue #65) and its
/// own `AudioMixEngine` program-bus tap (A01, issue #82): one of N independent
/// frame/audio consumers, so recording can no longer claim or starve the
/// preview/publisher paths. The audio track carries the same master mix the
/// stream publishes — AAC 48 kHz stereo — so the file is a faithful local
/// copy of the outgoing program.
///
/// The app sandbox denies `~/Movies` without user-selected-file entitlements, so
/// recordings land in the shared App Group container's `Recordings/` folder (the
/// same location the iOS app imports its backups from) via StreamCore's
/// `RecordingStore`, which also provides the timestamped naming and the
/// disk-space guard. The finished file's path is published on `lastRecordingURL`.
@MainActor
final class RecordingController: ObservableObject {
    /// Independent recording lifecycle (W02, issue #62) — drives the transport
    /// bar and the diagnostics strip; `isRecording` is the computed convenience.
    @Published private(set) var state: RecordingSessionState = .idle
    /// Path of the most recent cleanly-finished recording; nil until one exists.
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var lastError: String?

    var isRecording: Bool { state.isRecording }

    private let store = RecordingStore()
    /// Serializes every touch of the `AVAssetWriter` (appends, finish) against the
    /// engine subscription's delivery queue.
    private let queue = DispatchQueue(label: "com.joeblau.StreamMac.recording")
    private var session: RecordingSession?
    private weak var stream: StreamController?
    /// The recording output's engine subscription (W08 fan-out).
    private var frameSubscription: StreamController.FrameSubscription?
    /// The recording output's program-audio tap (A01 fan-out).
    private var audioSubscription: StreamController.AudioTapSubscription?

    /// Start if idle, stop (and finish the .mp4) if recording.
    func toggle(stream: StreamController) {
        state.isRecording ? stop() : start(stream: stream)
    }

    func start(stream: StreamController) {
        guard !state.isActive else { return }
        lastError = nil
        guard store.hasSufficientSpace() else {
            lastError = "Not enough disk space to record (1 GB minimum)."
            state = .failed(lastError!)
            return
        }
        guard let url = store.makeRecordingURL(date: Date()) else {
            lastError = "The recordings folder is unavailable (App Group container missing)."
            state = .failed(lastError!)
            return
        }
        let session = RecordingSession(outputURL: url)
        self.session = session
        self.stream = stream
        // Subscribe as one independent engine consumer: a backed-up writer
        // only sheds recording frames (bounded, drop-oldest queue) and never
        // stalls the preview or the publisher. Same for the A01 program-audio
        // tap: the recorder gets the master mix on its own bounded queue.
        frameSubscription = stream.addFrameSink { [queue] frame in
            queue.async { session.append(frame.sampleBuffer) }
        }
        audioSubscription = stream.addProgramAudioTap { [queue] sample in
            queue.async { session.appendAudio(sample) }
        }
        // The recording output keeps the render pipeline alive on its own, so
        // stopping the preview mid-recording cannot starve the writer.
        stream.noteRecordingStarted()
        state = .recording
    }

    func stop() {
        guard state.isRecording else { return }
        state = .stopping
        if let frameSubscription {
            stream?.removeFrameSink(frameSubscription)
        }
        frameSubscription = nil
        if let audioSubscription {
            stream?.removeAudioTap(audioSubscription)
        }
        audioSubscription = nil
        stream?.noteRecordingStopped()
        stream = nil
        guard let session else {
            state = .idle
            return
        }
        self.session = nil
        queue.async { [weak self, store] in
            session.finish { url in
                Task { @MainActor in
                    guard let self else { return }
                    if let url {
                        store.markComplete(url)
                        self.lastRecordingURL = url
                        self.state = .idle
                    } else {
                        self.lastError = "Recording could not be written."
                        self.state = .failed(self.lastError!)
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
    private var audioInput: AVAssetWriterInput?
    private var started = false
    private var failed = false
    /// The session start time (first video frame's PTS): audio chunks stamped
    /// earlier are dropped so the writer never sees media before t=0.
    private var sessionStart: CMTime = .invalid

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
            sessionStart = CMSampleBufferGetPresentationTimeStamp(sample)
            writer.startSession(atSourceTime: sessionStart)
            started = true
        }
        if input.isReadyForMoreMediaData {
            input.append(sample)
        }
    }

    /// Appends one mixed program-audio chunk (A01: canonical 48 kHz stereo
    /// Float32 LPCM; the writer input encodes it to AAC). Arrives on the
    /// controller's serial queue interleaved with video appends. Chunks
    /// stamped before the session start (audio leads video by up to a frame)
    /// are dropped; before the writer exists (no video frame yet) they are
    /// skipped — a video-first file.
    func appendAudio(_ sample: CMSampleBuffer) {
        guard !failed, started, let writer, let audioInput,
              writer.status != .failed else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid, pts >= sessionStart else { return }
        if audioInput.isReadyForMoreMediaData {
            audioInput.append(sample)
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
        audioInput?.markAsFinished()
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
            // A01: the program mix as AAC 48 kHz stereo. The engine feeds
            // canonical LPCM chunks on the same host-clock timeline as the
            // video frames, so the two tracks line up without re-timing.
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000
            ]
            let audioInput = AVAssetWriterInput(mediaType: .audio,
                                                outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(input), writer.canAdd(audioInput) else {
                failed = true
                return
            }
            writer.add(input)
            writer.add(audioInput)
            self.writer = writer
            self.input = input
            self.audioInput = audioInput
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
