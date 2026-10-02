import CoreGraphics
import CoreMedia
import Darwin
import Foundation

enum IsolatedVideoProcessing: String, Codable, CaseIterable, Sendable {
    case raw, processed
    var title: String { self == .raw ? "No Source Effects" : "Source Effects" }
}
enum IsolatedVideoResolution: String, Codable, CaseIterable, Sendable {
    case hd720, fullHD1080
    var width: Int { self == .hd720 ? 1280 : 1920 }
    var height: Int { self == .hd720 ? 720 : 1080 }
    var title: String { self == .hd720 ? "720p" : "1080p" }
}
struct IsolatedVideoSelection: Codable, Equatable, Identifiable, Sendable {
    var id: String { targetID }
    let targetID: String
    var name: String
    var processing: IsolatedVideoProcessing = .raw
    var resolution: IsolatedVideoResolution = .hd720
    var frameRate = 30
    var codec: RecordingCodec = .h264
    var quality: RecordingQuality = .standard
    var audioTargetID: String?
    var audioName: String?
    var bitrate: Int {
        let raw = Double(resolution.width) * Double(resolution.height) * Double(frameRate) * quality.bitsPerPixel
        return Int(min(24_000_000, max(2_000_000, raw)))
    }
}
struct RecordingVideoSource: Identifiable, Sendable {
    let id: String
    let name: String
    let isAvailable: Bool
    var unsupportedReason: String?
}
struct IsolatedVideoProgress: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let file: String
    var status = "preparing"
    var error: String?
    var warning: String?
    var sourceAvailable = false
    var missingVideoFrames = 0
    var renderDrops = 0
    var droppedAudio = 0
    var missingAudioFrames: Int64 = 0
    var videoSamples = 0
    var durationSeconds = 0.0
}
struct IsolatedVideoRenderedFrame: @unchecked Sendable {
    let sample: CMSampleBuffer?
    let sourceAvailable: Bool
}
/// A factory-created render closure is confined to one ISO worker queue.
/// It reads exact source holders and owns its own native renderer.
struct IsolatedVideoSource: Sendable {
    typealias Render = @Sendable (CGSize, CMTime, CMTime, Int64, IsolatedVideoProcessing) -> IsolatedVideoRenderedFrame?
    let makeRenderer: @Sendable () -> Render
}

struct IsolatedVideoBudget: Codable, Sendable {
    let machineClass: String
    let qualified: Bool
    let maximumIsolatedSources: Int
    let maximumEncoderSessions: Int
    var publishingEncoders: Int
    var selectedEncoders: Int
    var estimatedDiskMegabytesPerSecond: Double
    var measuredDiskMegabytesPerSecond: Double?
    static var current: Self {
        let brand = systemString("machdep.cpu.brand_string") ?? "Unknown Mac"
        let model = systemString("hw.model") ?? "Unknown model"
        let cpus = ProcessInfo.processInfo.processorCount
        // Only the measured model/variant is enabled. Other variants need
        // their own native qualification, even if the chip name is similar.
        let qualified = brand == "Apple M3 Max" && model == "Mac15,8" && cpus == 16
        return Self(machineClass: "\(brand) (\(model), \(cpus) CPUs)", qualified: qualified, maximumIsolatedSources: qualified ? 2 : 0,
            maximumEncoderSessions: qualified ? 4 : 0, publishingEncoders: 0, selectedEncoders: 0,
            estimatedDiskMegabytesPerSecond: 0, measuredDiskMegabytesPerSecond: nil)
    }
    private static func systemString(_ name: String) -> String? {
        var length = 0
        guard sysctlbyname(name, nil, &length, nil, 0) == 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: max(1, length))
        let status = bytes.withUnsafeMutableBytes { sysctlbyname(name, $0.baseAddress, &length, nil, 0) }
        return status == 0 ? String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) : nil
    }
    func rejection(programWidth: Int, programHeight: Int, programFPS: Int,
                   selections: [IsolatedVideoSelection]) -> String? {
        guard qualified else { return "Isolated video is not yet qualified on \(machineClass). Run the native source-recording qualification before enabling this Mac class." }
        guard max(programWidth, programHeight) <= 1920, min(programWidth, programHeight) <= 1080, programFPS <= 30 else {
            return "Isolated video is qualified with a program up to 1080p30. Choose that program profile before recording." }
        guard selections.count <= maximumIsolatedSources, Set(selections.map(\.targetID)).count == selections.count else {
            return "Choose at most \(maximumIsolatedSources) distinct isolated video sources." }
        guard selections.allSatisfy({ [15, 30].contains($0.frameRate) }) else { return "Isolated video frame rates are 15 or 30 fps." }
        guard selectedEncoders + publishingEncoders + 1 <= maximumEncoderSessions else {
            return "Program, publishers and isolated video exceed the measured \(maximumEncoderSessions)-encoder budget." }
        if let measuredDiskMegabytesPerSecond, measuredDiskMegabytesPerSecond * 0.5 < estimatedDiskMegabytesPerSecond {
            return "The selected folder wrote \(Int(measuredDiskMegabytesPerSecond)) MB/s; the recordings need \(Int(ceil(estimatedDiskMegabytesPerSecond * 2))) MB/s including headroom." }
        return nil
    }
}

enum RecordingVideoStorageProbe {
    /// An actual new-file write plus fsync, outside the UI actor. This short
    /// probe establishes a start budget, not sustained/removable-disk support.
    static func measure(_ directory: URL) throws -> Double {
        let url = directory.appendingPathComponent(".stream-recording-probe-\(UUID().uuidString)")
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor); try? FileManager.default.removeItem(at: url) }
        let bytes = [UInt8](repeating: 0xA7, count: 1_048_576)
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<8 {
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    offset += written
                }
            }
        }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Double(bytes.count * 8) / 1_000_000 / max(0.001, ProcessInfo.processInfo.systemUptime - start)
    }
}
