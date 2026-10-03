import CoreMedia
import Foundation

/// Insert-chain choices. Capture-level processing (for example macOS voice
/// isolation) is already present in a captured sample and cannot be undone.
enum IsolatedAudioProcessing: String, Codable, CaseIterable, Sendable {
    case beforeEffects, afterEffects
    var title: String { self == .beforeEffects ? "Before Inserts" : "After Inserts" }
}

enum IsolatedAudioFormat: String, Codable, CaseIterable, Sendable {
    case wav, m4a
    var title: String { self == .wav ? "WAV Float32" : "M4A AAC" }
}

struct IsolatedRecordingSelection: Codable, Identifiable, Equatable, Sendable {
    var id: String { targetID }
    let targetID: String
    var name: String
    var processing: IsolatedAudioProcessing = .afterEffects
    var format: IsolatedAudioFormat = .wav
}

/// Shared by a program file and its isolated files. The program writer chooses
/// the origin and pause offset once; isolated writers wait for those decisions.
final class RecordingTimeline: @unchecked Sendable {
    struct SourceInterval {
        let start: CMTime
        let end: CMTime
        let offset: CMTime
    }
    struct AudioSlice {
        let sample: CMSampleBuffer
        let offset: CMTime
    }
    struct Snapshot {
        var origin: CMTime = .invalid
        var offset: CMTime = .zero
        var end: CMTime = .invalid
        var videoPTS: CMTime = .invalid
        var sealed = false
        var paused = false
        var waitingForResume = false
        var sourceStart: CMTime = .invalid
        var completedIntervals: [SourceInterval] = []

        /// A late PCM buffer keeps the offset of its original source interval.
        /// nil waits for the active frontier/resume decision; [] is a real
        /// source interval excluded by pause or the recording's origin/end.
        func audioSlices(_ sample: CMSampleBuffer, final: Bool) -> [AudioSlice]? {
            guard origin.isNumeric, end.isNumeric, videoPTS.isNumeric else { return nil }
            let start = sample.presentationTimeStamp
            let sampleEnd = start + CMTime(value: Int64(CMSampleBufferGetNumSamples(sample)), timescale: 48_000)
            let cutoff = end + offset
            let frontier = !final && !paused && !sealed && videoPTS.isNumeric
                ? CMTimeMinimum(end, videoPTS) + offset : cutoff
            if !final, sampleEnd > frontier, !paused { return nil }
            var intervals = completedIntervals
            if sourceStart.isNumeric { intervals.append(.init(start: sourceStart, end: cutoff, offset: offset)) }
            return intervals.compactMap { interval in
                guard sampleEnd > interval.start, start < interval.end,
                      let retained = ProgramRecordingSession.audioRange(sample, start: interval.start, end: interval.end) else { return nil }
                return AudioSlice(sample: retained, offset: interval.offset)
            }
        }
    }
    private let lock = NSLock()
    private var value = Snapshot()
    func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return value }
    func begin(at origin: CMTime) { lock.lock(); value.origin = origin; value.sourceStart = origin; lock.unlock() }
    func update(end: CMTime, videoPTS: CMTime? = nil) {
        lock.lock(); value.end = end; if let videoPTS { value.videoPTS = videoPTS }; lock.unlock()
    }
    /// Publish the resolved final source interval only after video admission
    /// has stopped. Active ISO commits lag the last accepted image PTS so an
    /// independently delayed next-frame cut can never retract written PCM.
    func seal(end: CMTime, videoPTS: CMTime? = nil) {
        lock.lock(); value.end = end; value.sealed = true
        if let videoPTS { value.videoPTS = videoPTS }; lock.unlock()
    }
    func pause() { lock.lock(); value.paused = true; lock.unlock() }
    func awaitResume() { lock.lock(); value.paused = false; value.waitingForResume = true; lock.unlock() }
    func resume(offset: CMTime, sourceStart: CMTime) {
        lock.lock()
        if value.sourceStart.isNumeric, value.end.isNumeric {
            value.completedIntervals.append(.init(start: value.sourceStart, end: value.end + value.offset, offset: value.offset))
            // PCM inlet queues hold at most 128 chunks. A bounded history also
            // covers callbacks captured before a rapid pause/resume transition.
            if value.completedIntervals.count > 64 { value.completedIntervals.removeFirst() }
        }
        value.sourceStart = sourceStart; value.offset = offset; value.waitingForResume = false
        lock.unlock()
    }
}

enum IsolatedAudioGap {
    static var key: CFString { "com.joeblau.Stream.isolated.missingFrames" as CFString }
    static func frames(in sample: CMSampleBuffer) -> Int {
        (CMGetAttachment(sample, key: key, attachmentModeOut: nil) as? NSNumber)?.intValue ?? 0
    }
    static func attach(_ frames: Int, to sample: CMSampleBuffer) {
        CMSetAttachment(sample, key: key, value: NSNumber(value: frames), attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
    }
}

struct IsolatedTrackProgress: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let file: String
    var status = "preparing"
    var error: String?
    var samplesWritten = 0
    var droppedChunks = 0
    var missingSourceFrames: Int64 = 0
    var durationSeconds = 0.0
}

struct RecordingAudioSource: Identifiable, Sendable {
    let id: String
    let name: String
    let isBus: Bool
    let isAvailable: Bool
}
