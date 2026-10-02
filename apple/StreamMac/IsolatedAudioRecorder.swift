import AVFoundation
import CoreMedia
import Foundation
import StreamCore

/// One independently bounded, independently failing WAV/M4A writer. Both use
/// AVAudioFile's PCM client format; AAC compression is an Apple file codec.
final class IsolatedAudioRecorder: @unchecked Sendable {
    struct Gap: Codable {
        let startSeconds: Double
        var durationSeconds: Double
        var missingFrames: Int64
        let reason: String
    }
    private struct Manifest: Codable {
        let version: Int
        let sessionID: String
        let segmentIndex: Int
        let programFile: String
        let selection: IsolatedRecordingSelection
        let context: RecordingContext
        var sourceStartSeconds: Double?
        var startOffsetSeconds: Double?
        var pauseOffsetSeconds: Double
        var gaps: [Gap]
        var omittedGapEvents: Int
        var progress: IsolatedTrackProgress
    }
    let outputURL: URL
    private let selection: IsolatedRecordingSelection
    private let sessionID: String
    private let segmentIndex: Int
    private let programFile: String
    private let context: RecordingContext
    private let timeline: RecordingTimeline
    private let event: @Sendable (IsolatedTrackProgress) -> Void
    private let spaceProbe: @Sendable (URL) throws -> Int64?
    private let queue = DispatchQueue(label: "com.joeblau.StreamMac.recording.isolated")
    private let lock = NSLock()
    private var pending: [CMSampleBuffer] = []
    private var accepting = true
    private var dropCount = 0
    private var file: AVAudioFile?
    private var timer: DispatchSourceTimer?
    private var progress: IsolatedTrackProgress
    private var gaps: [Gap] = []
    private var omittedGapEvents = 0
    private var framesWritten: Int64 = 0
    private var firstOffset: Double?
    private var lastHealth = Date.distantPast
    private var failure: String?
    private var finishing = false
    private var finished = false
    private var completion: (@Sendable () -> Void)?

    init(outputURL: URL, selection: IsolatedRecordingSelection,
         sessionID: String, segmentIndex: Int, programFile: String, context: RecordingContext,
         timeline: RecordingTimeline,
         spaceProbe: @escaping @Sendable (URL) throws -> Int64? = { url in
             try url.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity.map(Int64.init)
         }, event: @escaping @Sendable (IsolatedTrackProgress) -> Void) {
        self.outputURL = outputURL; self.selection = selection
        self.sessionID = sessionID; self.segmentIndex = segmentIndex
        self.programFile = programFile; self.context = context; self.timeline = timeline
        self.event = event; self.spaceProbe = spaceProbe
        progress = IsolatedTrackProgress(id: selection.targetID, name: selection.name, file: outputURL.lastPathComponent)
        queue.async { [self] in
            writeManifest()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.pump() }
            self.timer = timer; timer.resume()
        }
    }

    func append(_ sample: CMSampleBuffer) {
        guard !timeline.snapshot().paused else { return }
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        if pending.count >= 128 { pending.removeFirst(); dropCount += 1 }
        pending.append(sample)
    }

    func deactivate() { lock.lock(); accepting = false; lock.unlock() }

    func fail(_ message: String) { queue.async { [self] in failOnQueue(message) } }

    func finish(completion: @escaping @Sendable () -> Void) {
        deactivate()
        queue.async { [self] in
            if finished { completion(); return }
            self.completion = completion
            finishing = true
            pump()
        }
    }

    private func pump() {
        guard !finished else { return }
        let timing = timeline.snapshot()
        if failure == nil, timing.origin.isNumeric, !timing.waitingForResume {
            for _ in 0..<64 {
                lock.lock(); let sample = pending.first; lock.unlock()
                guard let sample else { break }
                let start = sample.presentationTimeStamp - timing.offset
                let end = start + CMTime(value: Int64(CMSampleBufferGetNumSamples(sample)), timescale: 48_000)
                // Do not commit beyond the program writer's accepted window.
                // Otherwise a stalled program encoder or a pause could leave
                // an isolated file longer than the actual program file.
                if start >= timing.origin, (!timing.end.isNumeric || end > timing.end), !finishing { break }
                lock.lock(); pending.removeFirst(); lock.unlock()
                if finishing, timing.end.isNumeric, start >= timing.end { continue }
                appendOnQueue(sample, timing: timing)
                if failure != nil { break }
            }
        }
        if Date().timeIntervalSince(lastHealth) >= 1 {
            lastHealth = Date()
            if failure == nil {
                do {
                    if let bytes = try spaceProbe(outputURL), bytes < 100_000_000 { failOnQueue("Isolated track stopped before exhausting storage.") }
                } catch { failOnQueue("Isolated track storage unavailable: \(error.localizedDescription)") }
            }
            publish()
        }
        if finishing {
            lock.lock(); let empty = pending.isEmpty; lock.unlock()
            if empty || failure != nil || !timing.origin.isNumeric || timing.waitingForResume {
                if failure == nil, !timing.origin.isNumeric { failOnQueue("No common program timeline was established.") }
                if failure == nil, timing.end.isNumeric {
                    let requested = Int64(((timing.end - timing.origin).seconds * 48_000).rounded())
                    if requested > framesWritten { writeSilence(frames: requested - framesWritten, reason: "missing-tail") }
                }
                finalize()
            }
        }
    }

    private func configure() throws {
        guard !FileManager.default.fileExists(atPath: outputURL.path) else { throw CocoaError(.fileWriteFileExists) }
        let settings: [String: Any]
        if selection.format == .wav {
            settings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false]
        } else {
            settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000]
        }
        file = try AVAudioFile(forWriting: outputURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)
    }

    private func appendOnQueue(_ sample: CMSampleBuffer, timing: RecordingTimeline.Snapshot) {
        let pts = sample.presentationTimeStamp
        guard pts.isNumeric else { failOnQueue("Isolated audio has an invalid timestamp."); return }
        let relative = pts - timing.offset - timing.origin
        let position = Int64((relative.seconds * 48_000).rounded())
        let count = Int64(CMSampleBufferGetNumSamples(sample))
        if position < 0 { return } // Preroll precedes the common session origin.
        if position < framesWritten {
            lock.lock(); dropCount += 1; lock.unlock()
            return // Late data cannot reorder a track; report the shed chunk.
        }
        do {
            if file == nil { try configure() }
            if firstOffset == nil { firstOffset = relative.seconds }
            if position > framesWritten { writeSilence(frames: position - framesWritten, reason: "timeline-gap") }
            guard failure == nil, let pcm = CanonicalAudioConverter.makePCMBuffer(from: sample),
                  pcm.format.sampleRate == 48_000, pcm.format.channelCount == 2 else {
                if failure == nil { failOnQueue("Isolated audio is not canonical 48 kHz stereo PCM.") }
                return
            }
            let missing = IsolatedAudioGap.frames(in: sample)
            if missing > 0 {
                progress.missingSourceFrames += Int64(missing)
                addGap(start: relative.seconds, duration: Double(count) / 48_000,
                    missingFrames: Int64(missing), reason: "source-underrun-window")
            }
            if finishing, timing.end.isNumeric {
                let available = Int64(((timing.end - timing.origin).seconds * 48_000).rounded()) - position
                pcm.frameLength = AVAudioFrameCount(max(0, min(Int64(pcm.frameLength), available)))
                guard pcm.frameLength > 0 else { return }
            }
            try file?.write(from: pcm)
            framesWritten += Int64(pcm.frameLength)
            progress.samplesWritten += 1; progress.status = "recording"
        } catch { failOnQueue("Isolated audio write failed: \(error.localizedDescription)") }
    }

    private func writeSilence(frames: Int64, reason: String) {
        guard frames > 0, failure == nil else { return }
        guard frames <= 240_000 else { failOnQueue("Isolated audio clock jumped more than five seconds."); return }
        do {
            if file == nil { try configure() }
            addGap(start: Double(framesWritten) / 48_000, duration: Double(frames) / 48_000,
                missingFrames: frames, reason: reason)
            var remaining = frames
            while remaining > 0 {
                let count = AVAudioFrameCount(min(4096, remaining))
                guard let pcm = AVAudioPCMBuffer(pcmFormat: CanonicalAudioConverter.canonicalFormat, frameCapacity: count) else { throw CocoaError(.fileWriteUnknown) }
                pcm.frameLength = count
                for buffer in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                try file?.write(from: pcm)
                framesWritten += Int64(count); remaining -= Int64(count)
            }
        } catch { failOnQueue("Isolated silence/gap write failed: \(error.localizedDescription)") }
    }

    private func addGap(start: Double, duration: Double, missingFrames: Int64, reason: String) {
        if let previous = gaps.last, previous.reason == reason,
           abs(previous.startSeconds + previous.durationSeconds - start) < 1.0 / 48_000 {
            gaps[gaps.count - 1].durationSeconds += duration
            gaps[gaps.count - 1].missingFrames += missingFrames
        } else if gaps.count < 10_000 {
            gaps.append(Gap(startSeconds: start, durationSeconds: duration, missingFrames: missingFrames, reason: reason))
        } else { omittedGapEvents += 1 }
    }

    private func failOnQueue(_ message: String) {
        guard failure == nil else { return }
        failure = message; progress.error = message; progress.status = "failed"
        deactivate()
        file = nil // Close/finalize what exists; never delete the file.
        lock.lock(); pending.removeAll(); lock.unlock()
        publish()
    }

    private func finalize() {
        file = nil // ExtAudioFile closes and finalizes its WAV/M4A header.
        if failure == nil {
            do {
                let check = try AVAudioFile(forReading: outputURL)
                guard framesWritten > 0, check.length > 0,
                      abs(Double(check.length - framesWritten) / 48_000) < 0.06 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                progress.status = "complete"
            } catch { failOnQueue("Isolated track finalization failed: \(error.localizedDescription)") }
        }
        finished = true; timer?.cancel(); timer = nil
        publish()
        let completion = completion; self.completion = nil; completion?()
    }

    private func publish() {
        lock.lock(); progress.droppedChunks = dropCount; lock.unlock()
        progress.durationSeconds = Double(framesWritten) / 48_000
        writeManifest(); event(progress)
    }

    private func writeManifest() {
        let timing = timeline.snapshot()
        let manifest = Manifest(version: 1, sessionID: sessionID, segmentIndex: segmentIndex,
            programFile: programFile, selection: selection, context: context,
            sourceStartSeconds: timing.origin.isNumeric ? timing.origin.seconds : nil,
            startOffsetSeconds: firstOffset, pauseOffsetSeconds: timing.offset.seconds,
            gaps: gaps, omittedGapEvents: omittedGapEvents, progress: progress)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try encoder.encode(manifest).write(to: outputURL.appendingPathExtension("isolated.json"), options: .atomic) }
        catch {
            // The actual track failure is still delivered when its volume
            // cannot persist the manifest.
            if failure == nil { progress.error = "Isolated journal could not be saved: \(error.localizedDescription)" }
        }
    }
}

final class IsolatedRecordingGroup: @unchecked Sendable {
    let files: [String]
    private let tracks: [String: IsolatedAudioRecorder]
    init(programURL: URL, selections: [IsolatedRecordingSelection], sessionID: String, segmentIndex: Int,
         context: RecordingContext, timeline: RecordingTimeline,
         event: @escaping @Sendable (IsolatedTrackProgress) -> Void) {
        var tracks: [String: IsolatedAudioRecorder] = [:]
        for selection in selections.prefix(8) {
            guard tracks[selection.targetID] == nil else { continue }
            let safeName = String(selection.name.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(40))
            let url = programURL.deletingPathExtension().appendingPathExtension("\(safeName)-\(UUID().uuidString.prefix(8)).\(selection.format.rawValue)")
            tracks[selection.targetID] = IsolatedAudioRecorder(outputURL: url, selection: selection,
                sessionID: sessionID, segmentIndex: segmentIndex, programFile: programURL.lastPathComponent,
                context: context, timeline: timeline, event: event)
        }
        self.tracks = tracks; self.files = tracks.values.map { $0.outputURL.lastPathComponent }.sorted()
    }
    func append(_ sample: CMSampleBuffer, targetID: String) { tracks[targetID]?.append(sample) }
    func fail(targetID: String, message: String) { tracks[targetID]?.fail(message) }
    func deactivate() { tracks.values.forEach { $0.deactivate() } }
    func finish(completion: @escaping @Sendable () -> Void) {
        let group = DispatchGroup()
        for track in tracks.values { group.enter(); track.finish { group.leave() } }
        group.notify(queue: .global(qos: .utility), execute: completion)
    }
}

final class IsolatedRecordingRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var group: IsolatedRecordingGroup?
    func install(_ group: IsolatedRecordingGroup?) { lock.lock(); self.group = group; lock.unlock() }
    func append(_ sample: CMSampleBuffer, targetID: String) {
        lock.lock(); let group = group; lock.unlock()
        group?.append(sample, targetID: targetID)
    }
}
