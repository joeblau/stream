import AVFoundation
import CoreMedia
import Foundation

/// A source render queue and a separately bounded Apple writer. Reads the
/// program's accepted clock, so pause/split cannot accumulate independent drift.
final class IsolatedVideoRecorder: @unchecked Sendable {
    struct Gap: Codable { let startSeconds: Double; var durationSeconds: Double; let reason: String }
    private struct Manifest: Codable {
        let version: Int
        let sessionID: String
        let segmentIndex: Int
        let programFile: String
        let selection: IsolatedVideoSelection
        let context: RecordingContext
        let budget: IsolatedVideoBudget
        let commonSourceStartSeconds: Double?
        let pauseOffsetSeconds: Double
        let sourceStartOffsetSeconds: Double?
        let gaps: [Gap]
        let omittedGapEvents: Int
        let progress: IsolatedVideoProgress
    }
    let outputURL: URL
    private let selection: IsolatedVideoSelection
    private let sessionID: String
    private let segmentIndex: Int
    private let programFile: String
    private let context: RecordingContext
    private let budget: IsolatedVideoBudget
    private let timeline: RecordingTimeline
    private let spaceProbe: @Sendable (URL) throws -> Int64?
    private let unavailableReason: String
    private var render: IsolatedVideoSource.Render?
    private let event: @Sendable (IsolatedVideoProgress) -> Void
    private let queue = DispatchQueue(label: "com.joeblau.StreamMac.recording.isolatedVideo")
    private let lock = NSLock()
    private var audio: [CMSampleBuffer] = []
    private var acceptingAudio = true
    private var audioDrops = 0
    private var writer: ProgramRecordingSession?
    private var timer: DispatchSourceTimer?
    private var nextVideoTime: CMTime = .invalid
    private var nextAudioTime: CMTime = .invalid
    private var firstVideoTime: CMTime = .invalid
    private var blackPixelBuffer: CVPixelBuffer?
    private var sequence: Int64 = 0
    private var renderDropCount = 0
    private var writerVideoDrops = 0
    private var writerAudioDrops = 0
    private var failure: String?
    private var finishing = false
    private var finished = false
    private var progress: IsolatedVideoProgress
    private var gaps: [Gap] = []
    private var omittedGapEvents = 0
    private var completions: [@Sendable () -> Void] = []
    private var lastPublish = Date.distantPast

    init(outputURL: URL, selection: IsolatedVideoSelection, source: IsolatedVideoSource?,
         sessionID: String, segmentIndex: Int, programFile: String, context: RecordingContext,
         budget: IsolatedVideoBudget, timeline: RecordingTimeline,
         unavailableReason: String = "The selected video source is unavailable or was deleted; no other source was substituted.",
         spaceProbe: @escaping @Sendable (URL) throws -> Int64? = { url in
             try url.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity.map(Int64.init)
         },
         event: @escaping @Sendable (IsolatedVideoProgress) -> Void) {
        self.outputURL = outputURL; self.selection = selection; self.render = source?.makeRenderer()
        self.sessionID = sessionID; self.segmentIndex = segmentIndex; self.programFile = programFile
        self.context = context; self.budget = budget; self.timeline = timeline; self.event = event
        self.unavailableReason = unavailableReason; self.spaceProbe = spaceProbe
        progress = .init(id: selection.targetID, name: selection.name, file: outputURL.lastPathComponent)
        queue.async { [self] in
            if render == nil { failOnQueue(unavailableReason); return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.pump() }; self.timer = timer; timer.resume()
            publish()
        }
    }
    func appendAudio(_ sample: CMSampleBuffer) {
        guard !timeline.snapshot().paused else { return }
        lock.lock(); defer { lock.unlock() }
        guard acceptingAudio, selection.audioTargetID != nil else { return }
        if audio.count >= 128 { audio.removeFirst(); audioDrops += 1 }
        audio.append(sample)
    }
    func deactivate() { lock.lock(); acceptingAudio = false; lock.unlock() }
    func fail(_ message: String) { queue.async { [self] in failOnQueue(message) } }
    func finish(completion: @escaping @Sendable () -> Void) {
        deactivate()
        queue.async { [self] in
            if finished { completion(); return }
            completions.append(completion)
            if !finishing { pump(final: true); finishWriter() }
        }
    }
    private func pump(final: Bool = false) {
        guard !finishing, !finished, failure == nil else { return }
        let timing = timeline.snapshot()
        guard timing.origin.isNumeric, timing.end.isNumeric, !timing.waitingForResume else {
            if final { failOnQueue("No common program video timeline was established.") }; return
        }
        if timing.paused && !final { return }
        if writer == nil {
            var config = ProgramRecordingSession.Configuration()
            config.frameRate = selection.frameRate; config.codec = selection.codec; config.quality = selection.quality
            config.sessionID = sessionID; config.segmentIndex = segmentIndex; config.context = context
            config.requiresAudio = selection.audioTargetID != nil; config.sourceStartTime = timing.origin
            config.videoCapacity = 6; config.maxVideoMemoryBytes = 48_000_000; config.audioCapacity = 128
            writer = ProgramRecordingSession(outputURL: outputURL, configuration: config, spaceProbe: spaceProbe, event: { [weak self] event in
                self?.queue.async { [weak self] in self?.receive(event) }
            })
            nextVideoTime = timing.origin; nextAudioTime = timing.origin
        }
        let interval = CMTime(value: 1, timescale: CMTimeScale(selection.frameRate))
        let due = max(0, Int(((timing.end - nextVideoTime).seconds * Double(selection.frameRate)).rounded(.down)))
        let maximum = final ? 6 : 2
        if due > maximum {
            let skipped = due - maximum
            gap(at: (nextVideoTime - timing.origin).seconds, duration: Double(skipped) / Double(selection.frameRate), reason: "render-overload")
            nextVideoTime = nextVideoTime + CMTime(value: Int64(skipped), timescale: CMTimeScale(selection.frameRate))
            renderDropCount += skipped
        }
        for _ in 0..<maximum {
            let remaining = timing.end - nextVideoTime
            guard remaining > .zero, final || remaining >= interval else { break }
            let duration = CMTimeMinimum(interval, remaining)
            sequence += 1
            guard let frame = render?(CGSize(width: selection.resolution.width, height: selection.resolution.height),
                nextVideoTime, duration, sequence, selection.processing) else {
                failOnQueue("The source renderer could not produce a frame."); return
            }
            progress.sourceAvailable = frame.sourceAvailable
            if !frame.sourceAvailable {
                progress.missingVideoFrames += 1
                gap(at: (nextVideoTime - timing.origin).seconds, duration: duration.seconds, reason: "source-unavailable-black")
            }
            let sample: CMSampleBuffer
            if let rendered = frame.sample { sample = rendered }
            else {
                // The shared renderer's four-buffer pool may be temporarily
                // held by the encoder. A counted black gap preserves clock
                // alignment without blocking another source or deleting media.
                renderDropCount += 1
                gap(at: (nextVideoTime - timing.origin).seconds, duration: duration.seconds, reason: "renderer-backpressure-black")
                guard let black = blackSample(pts: nextVideoTime, duration: duration) else { failOnQueue("The source gap frame could not be allocated."); return }
                sample = black
            }
            if !firstVideoTime.isNumeric { firstVideoTime = nextVideoTime }
            writer?.appendVideo(sample)
            nextVideoTime = nextVideoTime + duration
        }
        if selection.audioTargetID != nil {
            for _ in 0..<128 {
                lock.lock(); let sample = audio.first; lock.unlock()
                guard let sample else { break }
                let pts = sample.presentationTimeStamp - timing.offset
                let end = pts + CMTime(value: Int64(CMSampleBufferGetNumSamples(sample)), timescale: 48_000)
                if end > timing.end && !final { break }
                lock.lock(); audio.removeFirst(); lock.unlock()
                if pts < nextAudioTime || pts >= timing.end { continue }
                if pts > nextAudioTime { padAudio(until: pts, origin: timing.origin) }
                guard failure == nil, let copy = Self.retimed(sample, offset: timing.offset, endingAt: timing.end) else { continue }
                let missing = IsolatedAudioGap.frames(in: sample)
                if missing > 0 {
                    progress.missingAudioFrames += Int64(missing)
                    gap(at: (pts - timing.origin).seconds, duration: Double(CMSampleBufferGetNumSamples(copy)) / 48_000, reason: "associated-audio-underrun-window")
                }
                writer?.appendAudio(copy)
                nextAudioTime = pts + CMTime(value: Int64(CMSampleBufferGetNumSamples(copy)), timescale: 48_000)
            }
            if final { padAudio(until: timing.end, origin: timing.origin) }
        }
        if Date().timeIntervalSince(lastPublish) >= 1 { publish() }
    }
    private func padAudio(until end: CMTime, origin: CMTime) {
        let count = Int64(((end - nextAudioTime).seconds * 48_000).rounded())
        guard count > 0 else { return }
        guard count <= 240_000 else { failOnQueue("Associated audio clock gap exceeds five seconds."); return }
        gap(at: (nextAudioTime - origin).seconds, duration: Double(count) / 48_000, reason: "associated-audio-timeline-gap")
        var remaining = count
        while remaining > 0 {
            let frames = Int(min(4096, remaining))
            guard let sample = Self.silence(frames: frames, pts: nextAudioTime) else { failOnQueue("Associated audio silence could not be created."); return }
            writer?.appendAudio(sample)
            nextAudioTime = nextAudioTime + CMTime(value: Int64(frames), timescale: 48_000); remaining -= Int64(frames)
        }
    }
    private func receive(_ event: ProgramRecordingSession.Event) {
        switch event {
        case .recording: if failure == nil && !finishing && !finished { progress.status = "recording"; publish() }
        case .progress(let value):
            progress.videoSamples = value.videoSamples; progress.durationSeconds = value.durationSeconds
            writerVideoDrops = value.droppedVideo; writerAudioDrops = value.droppedAudio
            progress.warning = value.warning; publish()
        case .failed(let message): failOnQueue(message)
        case .paused: break // The parent timeline owns pause decisions.
        }
    }
    private func failOnQueue(_ message: String) {
        guard failure == nil, !finished else { return }
        failure = message; progress.status = "failed"; progress.error = message
        deactivate(); lock.lock(); audio.removeAll(); lock.unlock()
        publish(); finishWriter()
    }
    private func finishWriter() {
        guard !finishing else { return }
        finishing = true; timer?.cancel(); timer = nil
        if failure == nil { progress.status = "finishing"; publish() }
        guard let writer else { complete(nil); return }
        writer.finish { [weak self] result in self?.queue.async { [weak self] in self?.complete(result) } }
    }
    private func complete(_ result: ProgramRecordingSession.Result?) {
        if let result {
            progress.videoSamples = result.progress.videoSamples; progress.durationSeconds = result.progress.durationSeconds
            writerVideoDrops = result.progress.droppedVideo; writerAudioDrops = result.progress.droppedAudio
            progress.status = failure == nil && result.completed ? "complete" : "failed"
            progress.error = failure ?? result.error; progress.warning = result.progress.warning
        }
        // Completed tracks remain in the session group for their status. Do
        // not retain the renderer's pixel pool after an encoder has stopped.
        finished = true; writer = nil; render = nil; blackPixelBuffer = nil; publish()
        let callbacks = completions; completions.removeAll(); callbacks.forEach { $0() }
    }
    private func gap(at start: Double, duration: Double, reason: String) {
        if let last = gaps.last, last.reason == reason, abs(last.startSeconds + last.durationSeconds - start) < 1.0 / 48_000 {
            gaps[gaps.count - 1].durationSeconds += duration
        } else if gaps.count < 10_000 { gaps.append(.init(startSeconds: start, durationSeconds: duration, reason: reason)) }
        else { omittedGapEvents += 1 }
    }
    private func publish() {
        lastPublish = Date(); lock.lock(); progress.droppedAudio = audioDrops + writerAudioDrops; lock.unlock()
        progress.renderDrops = renderDropCount + writerVideoDrops
        if failure == nil && progress.renderDrops > 0 { progress.warning = "Source rendering shed frames; inspect the marked gaps and reduce encoder load." }
        if failure == nil && !progress.sourceAvailable && progress.missingVideoFrames > 0 { progress.warning = "Source unavailable; marked black frames are being recorded." }
        let timing = timeline.snapshot()
        let manifest = Manifest(version: 1, sessionID: sessionID, segmentIndex: segmentIndex, programFile: programFile,
            selection: selection, context: context, budget: budget,
            commonSourceStartSeconds: timing.origin.isNumeric ? timing.origin.seconds : nil,
            pauseOffsetSeconds: timing.offset.seconds,
            sourceStartOffsetSeconds: firstVideoTime.isNumeric ? (firstVideoTime - timing.origin).seconds : nil,
            gaps: gaps, omittedGapEvents: omittedGapEvents, progress: progress)
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: outputURL.appendingPathExtension("video-isolated.json"), options: .atomic)
        } catch { progress.warning = "Source recording journal could not be saved: \(error.localizedDescription)" }
        event(progress)
    }
    private func blackSample(pts: CMTime, duration: CMTime) -> CMSampleBuffer? {
        if blackPixelBuffer == nil {
            var pixels: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, selection.resolution.width, selection.resolution.height,
                kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pixels) == kCVReturnSuccess,
                let pixels else { return nil }
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), 0, CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            blackPixelBuffer = pixels
        }
        guard let pixels = blackPixelBuffer else { return nil }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &format) == noErr,
            let format else { return nil }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
    private static func retimed(_ sample: CMSampleBuffer, offset: CMTime, endingAt end: CMTime) -> CMSampleBuffer? {
        let pts = sample.presentationTimeStamp - offset
        let frames = min(CMSampleBufferGetNumSamples(sample), max(0, Int(((end - pts).seconds * 48_000).rounded())))
        guard frames > 0 else { return nil }
        var trimmed: CMSampleBuffer?
        guard CMSampleBufferCopySampleBufferForRange(allocator: nil, sampleBuffer: sample,
            sampleRange: CFRange(location: 0, length: frames), sampleBufferOut: &trimmed) == noErr, let trimmed else { return nil }
        var entries = 0
        CMSampleBufferGetSampleTimingInfoArray(trimmed, entryCount: 0, arrayToFill: nil, entriesNeededOut: &entries)
        var timing = [CMSampleTimingInfo](repeating: .init(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid), count: max(1, entries))
        guard CMSampleBufferGetSampleTimingInfoArray(trimmed, entryCount: timing.count, arrayToFill: &timing, entriesNeededOut: &entries) == noErr else { return nil }
        for index in timing.indices {
            timing[index].presentationTimeStamp = timing[index].presentationTimeStamp - offset
            if timing[index].decodeTimeStamp.isNumeric { timing[index].decodeTimeStamp = timing[index].decodeTimeStamp - offset }
        }
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: trimmed, sampleTimingEntryCount: timing.count,
            sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr else { return nil }
        return copy
    }
    private static func silence(frames: Int, pts: CMTime) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, let format else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frames * 8, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: frames * 8, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        guard CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: frames * 8) == noErr else { return nil }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
            sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}

final class IsolatedVideoGroup: @unchecked Sendable {
    let files: [String]
    private let tracks: [String: IsolatedVideoRecorder]
    init(programURL: URL, selections: [IsolatedVideoSelection], sources: [String: IsolatedVideoSource],
         unavailableSourceReasons: [String: String] = [:],
         sessionID: String, segmentIndex: Int, context: RecordingContext, budget: IsolatedVideoBudget,
         timeline: RecordingTimeline, event: @escaping @Sendable (IsolatedVideoProgress) -> Void) {
        var tracks: [String: IsolatedVideoRecorder] = [:]
        for selection in selections.prefix(2) where tracks[selection.targetID] == nil {
            let name = String(selection.name.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(40))
            let url = programURL.deletingPathExtension().appendingPathExtension("video-\(name)-\(UUID().uuidString.prefix(8)).mp4")
            tracks[selection.targetID] = IsolatedVideoRecorder(outputURL: url, selection: selection, source: sources[selection.targetID],
                sessionID: sessionID, segmentIndex: segmentIndex, programFile: programURL.lastPathComponent, context: context,
                budget: budget, timeline: timeline,
                unavailableReason: unavailableSourceReasons[selection.targetID] ?? "The selected video source is unavailable or was deleted; no other source was substituted.", event: event)
        }
        self.tracks = tracks; files = tracks.values.map { $0.outputURL.lastPathComponent }.sorted()
    }
    func appendAudio(_ sample: CMSampleBuffer, videoTargetID: String) { tracks[videoTargetID]?.appendAudio(sample) }
    func fail(targetID: String, message: String) { tracks[targetID]?.fail(message) }
    func deactivate() { tracks.values.forEach { $0.deactivate() } }
    func finish(completion: @escaping @Sendable () -> Void) {
        let group = DispatchGroup()
        for track in tracks.values { group.enter(); track.finish { group.leave() } }
        group.notify(queue: .global(qos: .utility), execute: completion)
    }
}
final class IsolatedVideoRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var group: IsolatedVideoGroup?
    func install(_ group: IsolatedVideoGroup?) { lock.lock(); self.group = group; lock.unlock() }
    func appendAudio(_ sample: CMSampleBuffer, videoTargetID: String) {
        lock.lock(); let group = group; lock.unlock(); group?.appendAudio(sample, videoTargetID: videoTargetID)
    }
}
