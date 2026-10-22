import Darwin
import Dispatch
import Foundation

/// Diagnostics for this generated tool's synthetic localhost children only.
/// Original owned logs/media are retained; printed/JSON tails are bounded and
/// redact URL credentials/paths and token-shaped fields before disclosure.
enum DeckProcessDiagnostics {
    enum Role: String { case receiver, decoder }
    struct Receipt: Codable {
        let role: String
        let exitStatus: Int32
        let terminationReason: String
        let stoppedDuringCleanup: Bool
        let logTailTruncated: Bool
        let logTail: String
    }
    static let tailLimit = 16 * 1024

    static func boundedUTF8Tail(_ text: String) -> String {
        var bytes = Data(text.utf8).suffix(tailLimit)
        // Suffixing valid UTF8 can begin inside a scalar. Drop its continuation
        // bytes rather than expanding them into replacement characters.
        while let first = bytes.first, first & 0xC0 == 0x80 { bytes = bytes.dropFirst() }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func artifactDirectory(under root: URL) throws -> URL {
        let directory = root.appendingPathComponent("artifacts-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileHandle.standardError.write(Data("ARTIFACTS: \(directory.path)\n".utf8))
        return directory
    }

    static func record(_ process: Process, role: Role, log: URL, directory: URL,
                       stoppedDuringCleanup: Bool = false) throws -> Receipt {
        guard process.processIdentifier > 0, !process.isRunning else {
            throw NSError(domain: "DeckProcessDiagnostics", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(role.rawValue) has no completed process status; artifacts: \(directory.path)"])
        }
        let handle = try FileHandle(forReadingFrom: log)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size > UInt64(tailLimit) ? size - UInt64(tailLimit) : 0)
        let bytes = try handle.read(upToCount: tailLimit) ?? Data()
        var tail = String(decoding: bytes, as: UTF8.self)
        if size > UInt64(tailLimit) {
            // Never disclose a credential/URL fragment whose beginning was
            // outside the retained byte window; discard that partial line.
            tail = tail.firstIndex(of: "\n").map { String(tail[tail.index(after: $0)...]) }
                ?? "[truncated log line]"
        }
        tail = tail.replacingOccurrences(of: #"(?i)\b(?:rtmps?|https?)://[^\s<>"']+"#,
                                        with: "[redacted URL]", options: .regularExpression)
        tail = tail.replacingOccurrences(of: #"(?i)\b(?:access_token|refresh_token|stream_key|token)\s*[:=]\s*[^,\s]+"#,
                                        with: "[redacted credential]", options: .regularExpression)
        let redacted = Data(tail.utf8)
        let receipt = Receipt(role: role.rawValue, exitStatus: process.terminationStatus,
                              terminationReason: process.terminationReason == .exit ? "exit" : "signal",
                              stoppedDuringCleanup: stoppedDuringCleanup,
                              logTailTruncated: size > UInt64(tailLimit) || redacted.count > tailLimit,
                              logTail: boundedUTF8Tail(tail))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: directory.appendingPathComponent("\(role.rawValue)-status.json"), options: .atomic)
        return receipt
    }

    static func requireSuccess(_ process: Process, role: Role, log: URL, directory: URL, message: String) throws {
        let receipt = try record(process, role: role, log: log, directory: directory)
        guard receipt.exitStatus == 0 else {
            let detail = "\(message); \(role.rawValue) exit=\(receipt.exitStatus) (\(receipt.terminationReason)); artifacts: \(directory.path)\n\(receipt.logTail)"
            FileHandle.standardError.write(Data("FAIL: \(detail)\n".utf8))
            throw NSError(domain: "DeckTransportFixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
        }
    }

    static func stopOwned(_ process: Process) -> Bool {
        guard process.isRunning else { return false }
        process.terminate()
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while process.isRunning && DispatchTime.now().uptimeNanoseconds < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        return true
    }
}
