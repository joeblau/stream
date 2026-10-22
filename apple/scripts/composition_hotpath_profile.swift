// Copied only into the ignored attribution tool, never the shipping target.
import Foundation
import Darwin
import CryptoKit
import CoreVideo

final class CompositionHotPathProfile: @unchecked Sendable {
    static let shared = CompositionHotPathProfile()
    struct Stamp {
        let wall: Double
        let cpu: UInt64
        let thread: UInt32
    }
    private let lock = NSLock()
    private var entries: [String: [Double]] = [:]
    private var events: [[String: Any]] = []
    private var omittedEvents = 0
    private var labels: [UUID: String] = [:]
    private var pixelHash: String?
    private static let eventLimit = 100_000
    static func now() -> Double { ProcessInfo.processInfo.systemUptime }
    static func stamp() -> Stamp {
        Stamp(wall: now(), cpu: clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID),
              thread: pthread_mach_thread_np(pthread_self()))
    }
    func label(_ id: UUID, _ name: String) { lock.lock(); labels[id] = name; lock.unlock() }
    func name(_ id: UUID) -> String { lock.lock(); defer { lock.unlock() }; return labels[id] ?? "other" }
    func record(_ name: String, since start: Stamp, until finish: Stamp? = nil, sequence: Int64? = nil) {
        let end = finish ?? Self.stamp()
        let wall = (end.wall - start.wall) * 1000
        let cpu = end.thread == start.thread && end.cpu >= start.cpu ? Double(end.cpu - start.cpu) / 1e6 : nil
        var event: [String: Any] = ["phase": name, "startUptime": start.wall,
            "endUptime": end.wall, "wallMilliseconds": wall, "thread": start.thread,
            "endThread": end.thread]
        if let cpu { event["threadCPUMilliseconds"] = cpu }
        if let sequence { event["sequence"] = sequence }
        lock.lock()
        entries[name + ".wall", default: []].append(wall)
        if let cpu { entries[name + ".threadCPU", default: []].append(cpu) }
        if events.count < Self.eventLimit { events.append(event) } else { omittedEvents += 1 }
        lock.unlock()
    }
    // Wall-only scopes may cross a suspension/thread migration; no CPU delta.
    func recordWall(_ name: String, since: Double) { recordValue(name, (Self.now() - since) * 1000) }
    func recordValue(_ name: String, _ ms: Double) {
        lock.lock(); entries[name, default: []].append(ms); lock.unlock()
    }
    func point(_ name: String, sequence: Int64, values: [String: Any] = [:]) {
        var event = values
        event["phase"] = name; event["sequence"] = sequence; event["uptime"] = Self.now()
        lock.lock()
        if events.count < Self.eventLimit { events.append(event) } else { omittedEvents += 1 }
        lock.unlock()
    }
    func count(_ name: String) { recordValue(name, 0) }
    func hash(_ image: CVPixelBuffer?) {
        guard let image else { return }
        lock.lock(); let needed = pixelHash == nil; if needed { pixelHash = "pending" }; lock.unlock()
        guard needed else { return }
        let t = Self.stamp(); CVPixelBufferLockBaseAddress(image, .readOnly)
        var bytes = Data(); let base = CVPixelBufferGetBaseAddress(image)!; let rowBytes = CVPixelBufferGetBytesPerRow(image)
        for row in 0..<CVPixelBufferGetHeight(image) {
            bytes.append(base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self), count: CVPixelBufferGetWidth(image) * 4)
        }
        let value = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        CVPixelBufferUnlockBaseAddress(image, .readOnly)
        lock.lock(); pixelHash = value; lock.unlock(); record("oneTimePixelHash", since: t)
    }
    func reset() {
        lock.lock(); entries.removeAll(); labels.removeAll(); pixelHash = nil
        events.removeAll(keepingCapacity: true); events.reserveCapacity(Self.eventLimit); omittedEvents = 0
        lock.unlock()
        for _ in 0..<200 { let t = Self.stamp(); record("counterEmptySpanCalibration", since: t) }
        for _ in 0..<200 {
            let t = Self.stamp(); recordValue("calibrationInnerRecord", 0)
            record("counterRecordValueCalibration", since: t)
        }
        for _ in 0..<200 {
            let t = Self.stamp(); record("calibrationInnerFullRecord", since: Self.stamp())
            record("counterFullRecordCalibration", since: t)
        }
    }
    func write(_ url: URL, caseIndex: Int) throws {
        lock.lock(); let values = entries; let hash = pixelHash; let trace = events; let omitted = omittedEvents; lock.unlock()
        var result: [String: Any] = [:]
        for (key, samples) in values where !samples.isEmpty {
            let ordered = samples.sorted(); let count = ordered.count; let sum = ordered.reduce(0, +)
            result[key] = ["count": count, "sumMilliseconds": sum, "meanMilliseconds": sum / Double(count),
                "medianMilliseconds": ordered[count / 2], "p95Milliseconds": ordered[Int(Double(count - 1) * 0.95)],
                "p99Milliseconds": ordered[Int(Double(count - 1) * 0.99)], "maxMilliseconds": ordered.last!,
                "over33ms": ordered.filter { $0 > 33.333 }.count, "over100ms": ordered.filter { $0 > 100 }.count]
        }
        let traceURL = url.deletingPathExtension().appendingPathExtension("events.json")
        try JSONSerialization.data(withJSONObject: ["events": trace, "omittedEvents": omitted], options: [.sortedKeys]).write(to: traceURL, options: .atomic)
        let object: [String: Any] = ["sourceIdentity": "see profile-source-hashes.json", "case": caseIndex,
            "seconds": 20, "canvas": "1920x1080", "fps": 30, "layers": 12,
            "firstWarmPixelSHA256": hash ?? "missing", "eventFile": traceURL.lastPathComponent,
            "eventCount": trace.count, "omittedEvents": omitted,
            "scope": "Instrumented bounded local attribution only; not sustained capacity, hosted-VM cause, waveform or physical-source qualification. Thread CPU uses Darwin CLOCK_THREAD_CPUTIME_ID only within synchronous same-thread scopes. Nested spans overlap; do not sum them. Counter storage overhead occurs outside leaf measurements but inside enclosing spans. Drop removal preserves production location under lock; between-callback residual includes release, loop and scheduling and is not an isolated destructor measurement.",
            "spans": result]
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}
