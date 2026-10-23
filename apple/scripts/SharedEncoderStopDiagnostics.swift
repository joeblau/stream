import Foundation

/// Fixture-only observations. Synchronous locking, JSON encoding and file writes
/// add uncalibrated shutdown overhead; they do not establish a failure's cause.
/// No endpoint, stream key, transport error text or media is recorded.
enum SharedEncoderStopDiagnostics {
    private final class Writer: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var file: FileHandle?
        private var attemptedOpen = false
        private let epoch = DispatchTime.now().uptimeNanoseconds

        func record(_ name: String, _ edge: String, fields: [String: String]) {
            // This is the observer callback's timestamp, before writer contention,
            // not the receiver's kernel exit time or a native transport status.
            let observed = DispatchTime.now().uptimeNanoseconds
            lock.lock(); defer { lock.unlock() }
            guard count < 512 else { return }
            count += 1
            do {
                if !attemptedOpen {
                    attemptedOpen = true
                    let root = ProcessInfo.processInfo.environment["STREAM_TRANSPORT_ARTIFACT_ROOT"]
                        ?? "build/shared-encoder-validation/artifacts"
                    let url = URL(fileURLWithPath: root, isDirectory: true)
                        .appendingPathComponent("stop-observations.jsonl")
                    guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return }
                    file = try FileHandle(forWritingTo: url)
                }
                let event: [String: Any] = ["sequence": count, "phase": name, "edge": edge,
                    "observedUptimeNanoseconds": String(observed),
                    "observerElapsedSeconds": Double(observed - epoch) / 1_000_000_000,
                    "eventLimitReached": count == 512,
                    "fields": fields]
                let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
                try file?.write(contentsOf: data + Data([10]))
            } catch {
                // Diagnostics never replace the original stop/media result.
                FileHandle.standardError.write(Data("DIAGNOSTIC WRITE ERROR: shared encoder stop observation unavailable\n".utf8))
            }
        }
    }
    private static let writer = Writer()

    static func record(_ name: String, _ edge: String, fields: [String: String]) {
        writer.record(name, edge, fields: fields)
    }
}
