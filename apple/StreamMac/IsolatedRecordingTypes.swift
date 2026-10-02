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
    struct Snapshot {
        var origin: CMTime = .invalid
        var offset: CMTime = .zero
        var end: CMTime = .invalid
        var paused = false
        var waitingForResume = false
    }
    private let lock = NSLock()
    private var value = Snapshot()
    func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return value }
    func begin(at origin: CMTime) { lock.lock(); value.origin = origin; lock.unlock() }
    func update(end: CMTime) { lock.lock(); value.end = end; lock.unlock() }
    func pause() { lock.lock(); value.paused = true; lock.unlock() }
    func awaitResume() { lock.lock(); value.paused = false; value.waitingForResume = true; lock.unlock() }
    func resume(offset: CMTime) { lock.lock(); value.offset = offset; value.waitingForResume = false; lock.unlock() }
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
