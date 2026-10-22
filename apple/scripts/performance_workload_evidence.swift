import Foundation

/// Source facts come from compressed sample timestamps, never the requested
/// output frame rate. A sparse source cannot establish nominal decode capacity.
struct PerformanceReplayInventory: Codable, Sendable {
    var availableFrames: Int
    var framesDueBeforeGraceEnd: Int
    var durationSeconds: Double
    var monotonic: Bool
}

struct PerformanceWorkloadCheck: Codable, Sendable {
    enum Status: String, Codable { case pending, passed, failed }
    var name: String
    var status: Status
    var detail: String

    static func check(_ name: String, _ passed: Bool, _ detail: String) -> Self {
        .init(name: name, status: passed ? .passed : .failed, detail: detail)
    }

    static func cadence(fps: Int, seconds: Double, rendered: Int,
                        decoded: Int, source: PerformanceReplayInventory?) -> [Self] {
        // Preserve the original nominal fps * (seconds - 5) requirement.
        let minimum = fps * Int(max(0, seconds - 5))
        var checks: [Self] = [.check("nominalCompositorCapacity", rendered >= minimum,
            "Rendered \(rendered); required at least \(minimum) for \(fps) fps over \(seconds)s with the existing 5s allowance.")]
        if let source {
            // Availability uses the whole workload's input inventory. The
            // five-second decoder grace below is not a second source-rate
            // requirement (for example, a perfect 30fps rate through 595 seconds).
            checks.append(.check("nominalReplayInputAvailability", source.availableFrames >= minimum,
                "Source has \(source.availableFrames) total frames for the \(seconds)s workload; nominal requirement \(minimum). \(source.framesDueBeforeGraceEnd) frames are due before decoder grace ends."))
            checks.append(.check("actualSourceDecodeCadence", source.availableFrames > 0 && source.monotonic && decoded >= source.framesDueBeforeGraceEnd,
                "Decoded \(decoded) actual frames; required \(source.framesDueBeforeGraceEnd) from compressed source timestamps. This does not qualify nominal \(fps) fps capacity."))
            checks.append(.check("nominalReplayDecodeCapacity", decoded >= minimum,
                "Original nominal gate unchanged: decoded \(decoded), required at least \(minimum). Input availability and actual-source decoding are reported separately."))
        }
        return checks
    }
}

/// Commit each case separately before media inspection or qualification can
/// fail. The aggregate is a convenience; earlier case files remain independent.
struct PerformanceEvidenceJournal {
    let directory: URL
    func write<T: Encodable>(_ value: T, name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
