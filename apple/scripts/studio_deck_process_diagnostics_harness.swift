import Foundation

@main enum DeckProcessDiagnosticsHarness {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "DeckProcessDiagnosticsHarness", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() throws {
        let unicodeTail = DeckProcessDiagnostics.boundedUTF8Tail(String(repeating: "😀", count: 8192) + "x")
        try check(unicodeTail.utf8.count <= DeckProcessDiagnostics.tailLimit && !unicodeTail.contains("�") && unicodeTail.hasSuffix("x"),
                  "A truncated Unicode scalar expanded the byte bound")
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let directory = try DeckProcessDiagnostics.artifactDirectory(under: root)
        let log = directory.appendingPathComponent("receiver.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        // The bounded tail begins mid-line, before the synthetic credentials.
        try handle.write(contentsOf: Data(repeating: 65, count: 24 * 1024))
        try handle.write(contentsOf: Data("\n".utf8))
        let failure = Process()
        failure.executableURL = URL(fileURLWithPath: "/bin/sh")
        failure.arguments = ["-c", "printf 'owned receiver diagnostic access_token=synthetic-secret rtmp://fake:fake@127.0.0.1:1/live/synthetic-key\\n' >&2; exit 23"]
        failure.standardOutput = handle; failure.standardError = handle
        try failure.run(); failure.waitUntilExit(); try handle.close()
        var refused = false
        do {
            try DeckProcessDiagnostics.requireSuccess(failure, role: .receiver, log: log, directory: directory,
                                                       message: "Expected owned nonzero negative control")
        } catch {
            refused = true
            let message = (error as NSError).localizedDescription
            try check(message.contains("exit=23 (exit)") && message.contains(directory.path), "Failure lost exact child status or artifact location")
            try check(!message.contains("synthetic-secret") && !message.contains("synthetic-key"), "Failure printed synthetic credentials")
        }
        try check(refused, "Nonzero receiver status was accepted")
        let statusFile = directory.appendingPathComponent("receiver-status.json")
        let status = try JSONDecoder().decode(DeckProcessDiagnostics.Receipt.self, from: Data(contentsOf: statusFile))
        try check(status.exitStatus == 23 && status.terminationReason == "exit" && !status.stoppedDuringCleanup,
                  "Retained receipt changed original exit status")
        try check(status.logTailTruncated && status.logTail.utf8.count <= DeckProcessDiagnostics.tailLimit,
                  "Retained diagnostic exceeded its bound")
        try check(status.logTail.contains("owned receiver diagnostic") && !status.logTail.contains("synthetic-secret")
            && !status.logTail.contains("synthetic-key") && !status.logTail.contains(String(repeating: "A", count: 16)),
                  "Diagnostic omitted final error, exposed credentials or disclosed a truncated line")
        let rawLog = try Data(contentsOf: log)
        try check(rawLog.count > 24 * 1024, "Original owned raw log was deleted or truncated")
        let retainedFailure = try Data(contentsOf: statusFile)

        let positiveLog = directory.appendingPathComponent("decoder.log")
        FileManager.default.createFile(atPath: positiveLog.path, contents: nil)
        let output = try FileHandle(forWritingTo: positiveLog)
        let success = Process(); success.executableURL = URL(fileURLWithPath: "/bin/sh")
        success.arguments = ["-c", "printf 'owned decoder success\\n' >&2; exit 0"]
        success.standardOutput = output; success.standardError = output
        try success.run(); success.waitUntilExit(); try output.close()
        try DeckProcessDiagnostics.requireSuccess(success, role: .decoder, log: positiveLog, directory: directory,
                                                   message: "Zero exit positive control failed")
        let stillRetained = try Data(contentsOf: statusFile)
        try check(stillRetained == retainedFailure, "Successful decoder overwrote the receiver failure receipt")
        print("PASS: owned exit23 is still rejected, exact status/raw log retained, bounded redacted complete-line tail and separate successful decoder receipt; artifacts \(directory.path)")

        let cleanup = Process(), readiness = Pipe()
        cleanup.executableURL = URL(fileURLWithPath: "/bin/sh")
        cleanup.arguments = ["-c", "trap '' TERM; printf ready; exec /bin/sleep 60"]
        cleanup.standardOutput = readiness; cleanup.standardError = FileHandle.nullDevice
        try cleanup.run()
        try check(readiness.fileHandleForReading.readData(ofLength: 5) == Data("ready".utf8), "Owned cleanup child never became ready")
        let start = ProcessInfo.processInfo.systemUptime
        try check(DeckProcessDiagnostics.stopOwned(cleanup), "Owned child was not stopped")
        try check(!cleanup.isRunning && cleanup.terminationReason == .uncaughtSignal && cleanup.terminationStatus == 9,
                  "SIGTERM-ignoring owned child was not killed and reaped")
        try check(ProcessInfo.processInfo.systemUptime - start < 4, "Owned child cleanup exceeded its deadline")
        let cleanupDirectory = directory.appendingPathComponent("cleanup", isDirectory: true)
        try FileManager.default.createDirectory(at: cleanupDirectory, withIntermediateDirectories: true)
        let cleanupLog = cleanupDirectory.appendingPathComponent("decoder.log")
        FileManager.default.createFile(atPath: cleanupLog.path, contents: Data())
        let cleanupReceipt = try DeckProcessDiagnostics.record(cleanup, role: .decoder, log: cleanupLog,
                                                               directory: cleanupDirectory, stoppedDuringCleanup: true)
        try check(cleanupReceipt.exitStatus == 9 && cleanupReceipt.terminationReason == "signal" && cleanupReceipt.stoppedDuringCleanup,
                  "Cleanup status was presented as the child's original normal exit")
        print("PASS: cleanup escalates only its owned SIGTERM-ignoring child after two-second TERM grace, reaps it and labels cleanup termination")
    }
}
