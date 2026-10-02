import Foundation
import CoreMedia

enum RecordingContainer: String, Codable, CaseIterable, Sendable {
    case mp4, mov
    var title: String { rawValue.uppercased() }
}

enum RecordingCodec: String, Codable, CaseIterable, Sendable {
    case h264, hevc
    var title: String { self == .h264 ? "H.264" : "HEVC" }
}

enum RecordingQuality: String, Codable, CaseIterable, Sendable {
    case standard, high
    var title: String { rawValue.capitalized }
    var bitsPerPixel: Double { self == .standard ? 0.12 : 0.24 }
}

struct RecordingContext: Codable, Equatable, Sendable {
    var projectID: String?
    var profileID: String?
    var projectName: String?
    var profileName: String?
}

struct RecordingMarker: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    let seconds: Double
    let title: String
}

final class RecordingDirectoryAccess: @unchecked Sendable {
    let url: URL
    private let scoped: Bool
    init(url: URL, scoped: Bool) { self.url = url; self.scoped = scoped }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}

struct RecordingPreferences: Codable, Equatable, Sendable {
    var container: RecordingContainer = .mp4
    var codec: RecordingCodec = .h264
    var quality: RecordingQuality = .standard
    var filenamePrefix = "Stream"
    var autoRecordOnGoLive = false
    var countdownSeconds = 0
    /// Zero disables automatic rotation.
    var splitAfterMinutes = 0
    var splitAfterMegabytes = 0
    var isolatedTracks: [IsolatedRecordingSelection] = []
    var isolatedVideoTracks: [IsolatedVideoSelection] = []

    init() {}
    private enum CodingKeys: String, CodingKey {
        case container, codec, quality, filenamePrefix, autoRecordOnGoLive
        case countdownSeconds, splitAfterMinutes, splitAfterMegabytes, isolatedTracks, isolatedVideoTracks
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        container = try c.decodeIfPresent(RecordingContainer.self, forKey: .container) ?? .mp4
        codec = try c.decodeIfPresent(RecordingCodec.self, forKey: .codec) ?? .h264
        quality = try c.decodeIfPresent(RecordingQuality.self, forKey: .quality) ?? .standard
        filenamePrefix = try c.decodeIfPresent(String.self, forKey: .filenamePrefix) ?? "Stream"
        autoRecordOnGoLive = try c.decodeIfPresent(Bool.self, forKey: .autoRecordOnGoLive) ?? false
        countdownSeconds = try c.decodeIfPresent(Int.self, forKey: .countdownSeconds) ?? 0
        splitAfterMinutes = try c.decodeIfPresent(Int.self, forKey: .splitAfterMinutes) ?? 0
        splitAfterMegabytes = try c.decodeIfPresent(Int.self, forKey: .splitAfterMegabytes) ?? 0
        isolatedTracks = try c.decodeIfPresent([IsolatedRecordingSelection].self, forKey: .isolatedTracks) ?? []
        isolatedVideoTracks = try c.decodeIfPresent([IsolatedVideoSelection].self, forKey: .isolatedVideoTracks) ?? []
    }
}

struct RecordingStoragePreflight: Sendable {
    let directory: URL?
    let availableBytes: Int64?
    let isWritable: Bool
    let error: String?
    var isReady: Bool { isWritable && error == nil && (availableBytes ?? 1_000_000_000) >= 1_000_000_000 }
}

/// The taps survive segment rotation; swapping this pointer joins a new writer
/// without dropping composition/audio demand or awaiting the previous finish.
final class ProgramRecordingRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var session: ProgramRecordingSession?
    func install(_ session: ProgramRecordingSession?) {
        lock.lock(); self.session = session; lock.unlock()
    }
    func appendVideo(_ sample: CMSampleBuffer) {
        lock.lock(); let session = session; lock.unlock()
        session?.appendVideo(sample)
    }
    func appendAudio(_ sample: CMSampleBuffer) {
        lock.lock(); let session = session; lock.unlock()
        session?.appendAudio(sample)
    }
}
