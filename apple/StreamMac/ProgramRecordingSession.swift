import AVFoundation
import CoreMedia
import Foundation

/// Only this serial queue touches the writer. Capture callbacks put retained
/// buffers into two bounded mailboxes; they never enqueue one work item per
/// sample, wait for the encoder, or block another output.
final class ProgramRecordingSession: @unchecked Sendable {
    struct Configuration: Sendable {
        var frameRate: Int = 30
        var videoBitrate: Int? = nil
        var container: RecordingContainer = .mp4
        var codec: RecordingCodec = .h264
        var quality: RecordingQuality = .standard
        var sessionID = UUID().uuidString
        var segmentIndex = 1
        var lowSpaceWarningBytes: Int64 = 1_000_000_000
        var minimumSpaceBytes: Int64 = 100_000_000
        var videoCapacity: Int = 30
        var maxVideoMemoryBytes: Int = 128_000_000
        var audioCapacity: Int = 128
    }

    enum TrackStatus: String, Codable, Sendable { case waiting, writing, stalled, failed, complete }

    struct Progress: Codable, Sendable {
        var videoStatus: TrackStatus = .waiting
        var audioStatus: TrackStatus = .waiting
        var videoError: String?
        var audioError: String?
        var videoSamples = 0
        var audioSamples = 0
        var droppedVideo = 0
        var droppedAudio = 0
        var durationSeconds = 0.0
        var availableBytes: Int64?
        var bytesWritten: Int64 = 0
        var warning: String?
    }

    enum Event: Sendable {
        case recording
        case paused
        case progress(Progress)
        case failed(String)
    }

    struct Result: Sendable {
        let url: URL
        let completed: Bool
        let error: String?
        let progress: Progress
        let recoverable: Bool
    }

    private struct PauseGap: Codable {
        let sourceStartSeconds: Double
        let durationSeconds: Double
    }

    private struct Manifest: Codable {
        let version: Int
        let sessionID: String
        let segmentIndex: Int
        let codec: RecordingCodec
        let container: RecordingContainer
        var pauses: [PauseGap]
        let file: String
        let startedAt: Date
        var status: String
        var error: String?
        var sourceStartSeconds: Double?
        var videoStartOffsetSeconds: Double?
        var audioStartOffsetSeconds: Double?
        var progress: Progress
    }

    let outputURL: URL
    private let configuration: Configuration
    private let event: @Sendable (Event) -> Void
    private let spaceProbe: @Sendable (URL) throws -> Int64?
    private let queue = DispatchQueue(label: "com.joeblau.StreamMac.recording.writer")
    private let lock = NSLock()
    // Protected by lock: no unbounded secondary dispatch queue.
    private var video: [CMSampleBuffer] = []
    private var audio: [CMSampleBuffer] = []
    private var accepting = true
    private var pausedAtInlet = false
    private var droppedVideo = 0
    private var firstVideoAccepted = false
    private var droppedAudio = 0
    // Everything below is queue-confined.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var timer: DispatchSourceTimer?
    private var started = false
    private var announcedRecording = false
    private var failure: String?
    private var finishRequested = false
    private var finishing = false
    private var finishDeadline: Date?
    private var completions: [@Sendable (Result) -> Void] = []
    private var result: Result?
    private var sessionStart: CMTime = .invalid
    private var lastVideoPTS: CMTime = .invalid
    private var lastAudioPTS: CMTime = .invalid
    private var endTime: CMTime = .invalid
    private var firstVideoPTS: CMTime = .invalid
    private var firstAudioPTS: CMTime = .invalid
    private let createdAt = Date()
    private var lastVideoWrite = Date()
    private var lastAudioWrite = Date()
    private var lastHealthCheck = Date.distantPast
    private var progress = Progress()
    private var paused = false
    private var resumePending = false
    private var timestampOffset: CMTime = .zero
    private var pauses: [PauseGap] = []

    init(outputURL: URL, configuration: Configuration = .init(),
         spaceProbe: @escaping @Sendable (URL) throws -> Int64? = { url in
             let values = try url.deletingLastPathComponent().resourceValues(
                 forKeys: [.volumeAvailableCapacityKey])
             return values.volumeAvailableCapacity.map(Int64.init)
         }, event: @escaping @Sendable (Event) -> Void = { _ in }) {
        self.outputURL = outputURL
        self.configuration = configuration
        self.spaceProbe = spaceProbe
        self.event = event
        queue.async { [self] in
            writeManifest(status: "preparing")
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.pump() }
            self.timer = timer
            timer.resume()
        }
    }

    func appendVideo(_ sample: CMSampleBuffer) { enqueue(sample, isVideo: true) }
    func appendAudio(_ sample: CMSampleBuffer) { enqueue(sample, isVideo: false) }

    private func enqueue(_ sample: CMSampleBuffer, isVideo: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard accepting, !pausedAtInlet else { return }
        guard CMSampleBufferGetPresentationTimeStamp(sample).isNumeric else {
            if isVideo { droppedVideo += 1 } else { droppedAudio += 1 }
            return
        }
        if isVideo {
            let imageBytes = CMSampleBufferGetImageBuffer(sample).map(CVPixelBufferGetDataSize) ?? 1
            let capacity = max(1, min(configuration.videoCapacity, configuration.maxVideoMemoryBytes / max(1, imageBytes)))
            if video.count >= capacity {
                // Keep the first frame while VideoToolbox warms up so an
                // overloaded start cannot shift the video track origin.
                video.remove(at: !firstVideoAccepted && video.count > 1 ? 1 : 0); droppedVideo += 1
            }
            video.append(sample)
        } else {
            if audio.count >= max(1, configuration.audioCapacity) {
                audio.removeFirst(); droppedAudio += 1
            }
            audio.append(sample)
        }
    }

    func pause() {
        lock.lock(); pausedAtInlet = true; video.removeAll(); audio.removeAll(); lock.unlock()
        queue.async { [self] in
            guard !finishRequested, failure == nil, started else { return }
            paused = true
            writeManifest(status: "paused")
            event(.paused)
        }
    }

    func resume() {
        queue.async { [self] in
            guard paused, !finishRequested, failure == nil else { return }
            paused = false; resumePending = true
            announcedRecording = false
            lastVideoWrite = Date(); lastAudioWrite = Date()
            lock.lock(); pausedAtInlet = false; lock.unlock()
        }
    }

    /// Idempotent. Stop accepting immediately; drain at most three seconds of
    /// pending encode work before finalization. A failed file is preserved.
    func finish(completion: @escaping @Sendable (Result) -> Void) {
        lock.lock(); accepting = false; lock.unlock()
        queue.async { [self] in
            if let result { completion(result); return }
            completions.append(completion)
            guard !finishRequested else { return }
            finishRequested = true
            finishDeadline = Date().addingTimeInterval(3)
            pump()
        }
    }

    private func pump() {
        guard !finishing, result == nil else { return }
        if failure == nil {
            if !started {
                lock.lock()
                let firstVideo = video.first
                let firstAudio = audio.first
                lock.unlock()
                // Audio arriving before video remains bounded and retained.
                if let firstVideo, firstAudio != nil || finishRequested || Date().timeIntervalSince(createdAt) > 1 {
                    configure(video: firstVideo, audio: firstAudio)
                }
            }
            if started, !paused { drain() }
            if Date().timeIntervalSince(lastHealthCheck) >= 1 { checkHealth() }
        }
        if finishRequested {
            lock.lock(); let empty = video.isEmpty && audio.isEmpty; lock.unlock()
            if failure != nil || empty || Date() >= (finishDeadline ?? .distantFuture) {
                if !empty && failure == nil {
                    fail("The recording encoder did not drain before its finalization deadline.")
                }
                finalize()
            }
        }
    }

    private func configure(video: CMSampleBuffer, audio: CMSampleBuffer?) {
        guard let format = CMSampleBufferGetFormatDescription(video) else {
            fail("The program video has no format description."); return
        }
        let size = CMVideoFormatDescriptionGetDimensions(format)
        guard size.width > 0, size.height > 0 else { fail("Invalid program video dimensions."); return }
        let fps = max(1, configuration.frameRate)
        let bitrate = configuration.videoBitrate ?? min(24_000_000,
            max(2_000_000, Int(Double(size.width) * Double(size.height) * Double(fps) * configuration.quality.bitsPerPixel)))
        do {
            let writer = try AVAssetWriter(url: outputURL, fileType: configuration.container == .mp4 ? .mp4 : .mov)
            // Two-second movie fragments preserve finished fragments on a
            // crash/unplug. They cannot guarantee recovery of arbitrary damage.
            writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: configuration.codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
                AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate,
                    AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalKey: fps * 2]
            ])
            input.expectsMediaDataInRealTime = true
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000
            ])
            audioInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(input), writer.canAdd(audioInput) else {
                fail("The selected audio/video encoding settings are unavailable."); return
            }
            writer.add(input); writer.add(audioInput)
            self.writer = writer; self.videoInput = input; self.audioInput = audioInput
            guard writer.startWriting() else { fail(writer.error?.localizedDescription ?? "Cannot open recording writer."); return }
            let videoPTS = CMSampleBufferGetPresentationTimeStamp(video)
            sessionStart = audio.map { CMTimeMinimum(videoPTS, CMSampleBufferGetPresentationTimeStamp($0)) } ?? videoPTS
            writer.startSession(atSourceTime: sessionStart)
            started = true
        } catch { fail("Cannot open recording: \(error.localizedDescription)") }
    }

    private func drain() {
        guard let writer, let videoInput, let audioInput else { return }
        if resumePending {
            lock.lock()
            let firstVideo = video.first; let firstAudio = audio.first
            lock.unlock()
            // Both taps share a clock. Use the earliest resumed timestamp to
            // remove only the paused interval from both tracks.
            guard let firstVideo, let firstAudio else { return }
            let rawStart = CMTimeMinimum(firstVideo.presentationTimeStamp, firstAudio.presentationTimeStamp)
            let gap = CMTimeMaximum(.zero, rawStart - timestampOffset - endTime)
            pauses.append(PauseGap(sourceStartSeconds: (endTime + timestampOffset).seconds, durationSeconds: gap.seconds))
            timestampOffset = timestampOffset + gap
            resumePending = false
        }
        // Bounded work per tick also gives finish/health commands time to run.
        for _ in 0..<64 {
            guard writer.status == .writing else {
                fail(writer.error?.localizedDescription ?? "The recording writer stopped unexpectedly."); return
            }
            lock.lock()
            let nextVideo = videoInput.isReadyForMoreMediaData ? video.first : nil
            let nextAudio = audioInput.isReadyForMoreMediaData ? audio.first : nil
            let isVideo: Bool
            if let nextVideo, let nextAudio {
                isVideo = CMSampleBufferGetPresentationTimeStamp(nextVideo) <= CMSampleBufferGetPresentationTimeStamp(nextAudio)
            } else { isVideo = nextVideo != nil }
            let sample = isVideo ? nextVideo : nextAudio
            if sample != nil {
                if isVideo { video.removeFirst() } else { audio.removeFirst() }
            }
            lock.unlock()
            guard let sourceSample = sample else { return }
            guard let sample = retimed(sourceSample) else {
                fail("Cannot retime recording media after a pause.", videoTrack: isVideo); return
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let last = isVideo ? lastVideoPTS : lastAudioPTS
            guard pts >= sessionStart, !last.isValid || pts > last else {
                lock.lock()
                if isVideo { droppedVideo += 1 } else { droppedAudio += 1 }
                lock.unlock()
                continue
            }
            let input = isVideo ? videoInput : audioInput
            guard input.append(sample) else {
                fail("\(isVideo ? "Video" : "Program audio") track failed: \(writer.error?.localizedDescription ?? "encoder rejected media")", videoTrack: isVideo)
                return
            }
            let duration = CMSampleBufferGetDuration(sample)
            let sampleEnd = pts + (duration.isNumeric ? duration : CMTime(value: 1, timescale: Int32(max(1, configuration.frameRate))))
            endTime = endTime.isValid ? CMTimeMaximum(endTime, sampleEnd) : sampleEnd
            if isVideo {
                lastVideoPTS = pts; lastVideoWrite = Date(); progress.videoSamples += 1
                progress.videoStatus = .writing
                lock.lock(); firstVideoAccepted = true; lock.unlock()
                if !firstVideoPTS.isValid { firstVideoPTS = pts }
            } else {
                lastAudioPTS = pts; lastAudioWrite = Date(); progress.audioSamples += 1
                progress.audioStatus = .writing
                if !firstAudioPTS.isValid { firstAudioPTS = pts }
            }
            if !announcedRecording, progress.videoSamples > 0, progress.audioSamples > 0 {
                announcedRecording = true
                event(.recording)
            }
        }
    }

    private func retimed(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard timestampOffset > .zero else { return sample }
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr else { return nil }
        var timings = [CMSampleTimingInfo](repeating: .invalid, count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count) == noErr else { return nil }
        for index in timings.indices {
            timings[index].presentationTimeStamp = timings[index].presentationTimeStamp - timestampOffset
            if timings[index].decodeTimeStamp.isNumeric { timings[index].decodeTimeStamp = timings[index].decodeTimeStamp - timestampOffset }
        }
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: timings.count, sampleTimingArray: &timings, sampleBufferOut: &copy) == noErr else { return nil }
        return copy
    }

    private func checkHealth() {
        lastHealthCheck = Date()
        updateProgress()
        progress.warning = nil
        if failure == nil, !finishRequested, !paused, Date().timeIntervalSince(createdAt) > 3 {
            if Date().timeIntervalSince(lastVideoWrite) > 3 { progress.videoStatus = .stalled }
            if Date().timeIntervalSince(lastAudioWrite) > 3 { progress.audioStatus = .stalled }
        }
        do {
            progress.availableBytes = try spaceProbe(outputURL)
            if let bytes = progress.availableBytes {
                if bytes < configuration.minimumSpaceBytes {
                    fail("Recording stopped before exhausting storage (less than \(configuration.minimumSpaceBytes / 1_000_000) MB free).")
                } else if bytes < configuration.lowSpaceWarningBytes {
                    progress.warning = "Recording storage is low: \(bytes / 1_000_000) MB free."
                }
            }
            let sinceStart = Date().timeIntervalSince(createdAt)
            if !finishRequested, !paused, sinceStart > 10 {
                if Date().timeIntervalSince(lastVideoWrite) > 10 { fail("No video was written for ten seconds.") }
                else if Date().timeIntervalSince(lastAudioWrite) > 10 { fail("No program audio was written for ten seconds.") }
            }
            if !finishRequested, !paused, sinceStart > 3 {
                if !announcedRecording { progress.warning = "Waiting for program audio and video." }
                else if Date().timeIntervalSince(lastVideoWrite) > 3 || Date().timeIntervalSince(lastAudioWrite) > 3 {
                    progress.warning = "Recording write progress has stalled; check disk and encoder load."
                }
            }
        } catch { fail("Recording storage is unavailable: \(error.localizedDescription)") }
        if progress.droppedAudio > 0 || progress.droppedVideo > 0 {
            progress.warning = "Recording dropped \(progress.droppedVideo) video frames and \(progress.droppedAudio) audio chunks; check disk and encoder load."
        }
        event(.progress(progress))
        writeManifest(status: failure == nil ? (paused ? "paused" : announcedRecording ? "recording" : "preparing") : "partial")
    }

    private func updateProgress() {
        lock.lock()
        progress.droppedAudio = droppedAudio; progress.droppedVideo = droppedVideo
        lock.unlock()
        progress.bytesWritten = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        if endTime.isValid, sessionStart.isValid { progress.durationSeconds = max(0, (endTime - sessionStart).seconds) }
    }

    private func fail(_ message: String, videoTrack: Bool? = nil) {
        guard failure == nil else { return }
        failure = message
        if videoTrack != false { progress.videoStatus = .failed; progress.videoError = message }
        if videoTrack != true { progress.audioStatus = .failed; progress.audioError = message }
        lock.lock(); accepting = false; lock.unlock()
        updateProgress()
        writeManifest(status: "partial")
        event(.failed(message))
    }

    private func finalize() {
        guard !finishing else { return }
        finishing = true
        timer?.cancel(); timer = nil
        updateProgress()
        lock.lock(); video.removeAll(); audio.removeAll(); lock.unlock()
        guard started, let writer, writer.status == .writing else {
            complete(error: failure ?? "No program media was received."); return
        }
        videoInput?.markAsFinished(); audioInput?.markAsFinished()
        if endTime.isNumeric { writer.endSession(atSourceTime: endTime) }
        writeManifest(status: "finishing")
        writer.finishWriting { [self] in
            queue.async { [self] in
                let error = failure ?? (self.writer?.status == .completed ? nil : self.writer?.error?.localizedDescription ?? "Recording finalization failed.")
                complete(error: error ?? (progress.videoSamples == 0 || progress.audioSamples == 0 ? "The recording is missing program audio or video." : nil))
            }
        }
    }

    private func complete(error: String?) {
        failure = error
        updateProgress()
        if error == nil { progress.videoStatus = .complete; progress.audioStatus = .complete }
        else {
            if progress.videoStatus != .failed { progress.videoStatus = progress.videoSamples > 0 ? .complete : .failed }
            if progress.audioStatus != .failed { progress.audioStatus = progress.audioSamples > 0 ? .complete : .failed }
        }
        let recoverable = error != nil && writer?.status == .completed && progress.audioSamples > 0 && progress.videoSamples > 0
        let result = Result(url: outputURL, completed: error == nil, error: error, progress: progress, recoverable: recoverable)
        self.result = result
        writeManifest(status: result.completed ? "complete" : result.recoverable ? "recoverable" : "partial")
        let callbacks = completions; completions.removeAll()
        callbacks.forEach { $0(result) }
    }

    private func writeManifest(status: String) {
        let manifest = Manifest(version: 1, sessionID: configuration.sessionID, segmentIndex: configuration.segmentIndex, codec: configuration.codec, container: configuration.container, pauses: pauses, file: outputURL.lastPathComponent, startedAt: createdAt,
            status: status, error: failure,
            sourceStartSeconds: sessionStart.isNumeric ? sessionStart.seconds : nil,
            videoStartOffsetSeconds: firstVideoPTS.isNumeric ? (firstVideoPTS - sessionStart).seconds : nil,
            audioStartOffsetSeconds: firstAudioPTS.isNumeric ? (firstAudioPTS - sessionStart).seconds : nil,
            progress: progress)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(manifest).write(to: outputURL.appendingPathExtension("recording.json"), options: .atomic)
        } catch {
            // A removed/full volume often fails both writes. The in-memory
            // event still reaches the studio even when the journal cannot.
            progress.warning = "Recording journal could not be saved: \(error.localizedDescription)"
        }
    }
}
