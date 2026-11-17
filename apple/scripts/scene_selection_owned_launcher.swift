import AppKit
import CryptoKit
import Darwin
import Foundation

// Standalone owned-fixture launcher. Launch success is never oracle success.
// The test-only build below exercises this SAME public kqueue monitor without UI.
private struct LaunchFailure: Error, CustomStringConvertible { let description: String }
private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw LaunchFailure(description: message) }
}
private func uptime() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
private func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
private func digest(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}
private func readJSON(_ url: URL) throws -> [String: Any] {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
    try require(values.isRegularFile == true && values.isSymbolicLink != true
        && (values.fileSize ?? 16_385) <= 16_384, "Unbounded/nonregular handshake")
    let data = try Data(contentsOf: url)
    try require(data.count <= 16_384, "Handshake changed size")
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw LaunchFailure(description: "Invalid handshake object")
    }
    return object
}
private func writeJSON(_ object: [String: Any], _ url: URL) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url, options: .atomic)
}
private func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite, number.doubleValue == Double(number.intValue) else { return nil }
    return number.intValue
}
private func matches(_ object: [String: Any], _ identity: [String: Any]) -> Bool {
    guard integer(object["schema"]) == 1, integer(identity["schema"]) == 1,
          let expectedPID = integer(identity["pid"]), expectedPID > 1,
          integer(object["pid"]) == expectedPID else { return false }
    return ["nonce", "bundleURL", "executableURL", "sourceSHA256", "binarySHA256", "deadlineUptimeNanoseconds", "runtimeLogURL"].allSatisfy {
        guard let expected = identity[$0] as? String, !expected.isEmpty else { return false }
        return (object[$0] as? String) == expected
    }
}
private func readJSONPlist(_ url: URL) throws -> [String: Any] {
    guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any] else {
        throw LaunchFailure(description: "Invalid owned app plist")
    }; return value
}
private struct NativeExit {
    let raw: Int32
    let flags: UInt16
    let notes: UInt32
    var normal: Bool { raw & 0x7f == 0 }
    var code: Int { Int((raw >> 8) & 0xff) }
}
private final class OwnedExitMonitor {
    let pid: pid_t
    private var descriptor: Int32 = -1
    private(set) var armedAt: UInt64 = 0
    init(pid: pid_t) throws {
        try require(pid > 1 && pid != getpid(), "Invalid owned target PID")
        self.pid = pid
        descriptor = kqueue()
        guard descriptor >= 0 else { throw LaunchFailure(description: "kqueue failed errno \(errno)") }
        var change = kevent64_s()
        change.ident = UInt64(pid)
        change.filter = Int16(EVFILT_PROC)
        change.flags = UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT | EV_RECEIPT)
        change.fflags = UInt32(NOTE_EXIT) | UInt32(NOTE_EXITSTATUS)
        var receipt = kevent64_s(), zero = timespec()
        let count = kevent64(descriptor, &change, 1, &receipt, 1, 0, &zero)
        guard count == 1, receipt.ident == UInt64(pid), receipt.filter == Int16(EVFILT_PROC),
              receipt.flags & UInt16(EV_ERROR) != 0, receipt.data == 0 else {
            close(descriptor); descriptor = -1
            throw LaunchFailure(description: "Exit monitor arm refused count=\(count) errno=\(errno) flags=\(receipt.flags) data=\(receipt.data)")
        }
        armedAt = uptime()
    }
    deinit { if descriptor >= 0 { close(descriptor) } }
    func poll() throws -> NativeExit? {
        var event = kevent64_s(), zero = timespec()
        let count = kevent64(descriptor, nil, 0, &event, 1, 0, &zero)
        if count < 0 && errno == EINTR { return nil }
        try require(count >= 0, "Exit monitor read failed errno \(errno)")
        if count == 0 { return nil }
        try require(count == 1 && event.ident == UInt64(pid) && event.filter == Int16(EVFILT_PROC)
            && event.flags & UInt16(EV_ERROR) == 0
            && event.fflags & UInt32(NOTE_EXIT) != 0 && event.fflags & UInt32(NOTE_EXITSTATUS) != 0
            && event.data >= 0 && event.data <= 65_535, "Missing/invalid owned native exit status")
        return NativeExit(raw: Int32(event.data), flags: event.flags, notes: event.fflags)
    }
}
private struct Options {
    var values: [String: String] = [:]
    var appArguments: [String] = []
    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--" { appArguments = Array(arguments.dropFirst(index + 1)); return }
            try require(index + 1 < arguments.count && arguments[index].hasPrefix("--")
                && values[arguments[index]] == nil, "Malformed/duplicate launcher argument")
            values[arguments[index]] = arguments[index + 1]; index += 2
        }
    }
    func string(_ name: String) throws -> String {
        guard let value = values[name], !value.isEmpty else { throw LaunchFailure(description: "Missing \(name)") }
        return value
    }
    func number(_ name: String) throws -> UInt64 {
        guard let value = UInt64(try string(name)) else { throw LaunchFailure(description: "Invalid \(name)") }
        return value
    }
}

#if !OWNED_SCENE_MONITOR_CONTROL
@MainActor private final class OwnedApplicationLaunch {
    let options: Options
    let bundle: URL
    let executable: URL
    let artifacts: URL
    let nonce: String
    let sourceHash: String
    let binaryHash: String
    let deadline: UInt64
    let helperDeadline: UInt64
    let ready: URL
    let ack: URL
    let terminal: URL
    var application: NSRunningApplication?
    var ownedLaunchDate: Date?
    var callbackReceived = false
    var launchError: String?
    var ownershipVerified = false
    var monitor: OwnedExitMonitor?
    var nativeExit: NativeExit?
    var identity: [String: Any] = [:]
    var terminalVerified = false
    var terminalOracleCode: Int?
    var cleanupRequested = false
    var forceCleanupRequested = false
    var failure: String?
    var acknowledged = false

    init(_ options: Options) throws {
        self.options = options
        bundle = canonical(URL(fileURLWithPath: try options.string("--app")))
        artifacts = canonical(URL(fileURLWithPath: try options.string("--artifacts")))
        executable = bundle.appendingPathComponent("Contents/MacOS/harness")
        nonce = try options.string("--nonce")
        sourceHash = try options.string("--source-sha256"); binaryHash = try options.string("--binary-sha256")
        deadline = try options.number("--deadline-uptime-ns")
        helperDeadline = try options.number("--helper-deadline-uptime-ns")
        try require(UUID(uuidString: nonce)?.uuidString.lowercased() == nonce && sourceHash.count == 64 && binaryHash.count == 64
            && (sourceHash + binaryHash).allSatisfy { "0123456789abcdef".contains($0) }, "Invalid run identity")
        let now = uptime()
        try require(now < helperDeadline && helperDeadline < deadline && deadline - now <= 30_000_000_000
            && helperDeadline - now > 2_000_000_000, "Expired/invalid original deadline")
        try require(bundle.lastPathComponent == "OwnedSceneSemanticBaseline.app"
            && bundle.deletingLastPathComponent() == artifacts
            && canonical(executable) == executable, "Not the exact owned artifact bundle")
        let info = try readJSONPlist(bundle.appendingPathComponent("Contents/Info.plist"))
        let actualBinaryHash = try digest(executable)
        try require(info["CFBundleIdentifier"] as? String == "com.stream.owned.scene-semantic-baseline.wave18"
            && info["CFBundleExecutable"] as? String == "harness" && actualBinaryHash == binaryHash,
            "Owned bundle/binary mismatch")
        let prefix = "owned-launch-\(nonce)-"
        ready = artifacts.appendingPathComponent(prefix + "ready.json")
        ack = artifacts.appendingPathComponent(prefix + "ack.json")
        terminal = artifacts.appendingPathComponent(prefix + "terminal.json")
        try require([ready, ack, terminal].allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "Stale handshake artifacts")
        try require(options.appArguments == ["--public-cax-child", "--owned-keyboard-setup"], "Unexpected oracle arguments")
        let env = ProcessInfo.processInfo.environment
        try require(env["GITHUB_ACTIONS"] == "true" && env["RUNNER_ENVIRONMENT"] == "self-hosted", "Not actual self-hosted environment")
    }
    private func capture(_ app: NSRunningApplication, ready object: [String: Any]? = nil) throws {
        let actualBinaryHash = try digest(executable)
        guard let launchedAt = app.launchDate else { throw LaunchFailure(description: "Missing owned LaunchServices process birth identity") }
        try require(!app.isTerminated && app.processIdentifier > 1
            && app.bundleIdentifier == "com.stream.owned.scene-semantic-baseline.wave18"
            && app.bundleURL.map(canonical) == bundle && app.executableURL.map(canonical) == executable
            && actualBinaryHash == binaryHash, "Launch callback is not exact owned application")
        if let previous = application {
            try require(previous.isEqual(app) && ownedLaunchDate == launchedAt
                && Int(app.processIdentifier) == integer(identity["pid"]), "Callback tried to replace owned instance")
        }
        let expected: [String: Any] = ["schema": 1, "nonce": nonce, "pid": Int(app.processIdentifier),
            "bundleURL": bundle.absoluteString, "executableURL": executable.absoluteString,
            "sourceSHA256": sourceHash, "binarySHA256": binaryHash,
            "deadlineUptimeNanoseconds": String(deadline),
            "runtimeLogURL": artifacts.appendingPathComponent("owned-launch-runtime-\(nonce).log").absoluteString]
        if let object {
            try require(matches(object, expected) && object["phase"] as? String == "ready"
                && object["oracleExitCode"] == nil, "Ready fallback identity mismatch")
        }
        application = app; ownedLaunchDate = launchedAt; identity = expected; ownershipVerified = true
    }
    private func sameLiveInstance() -> Bool {
        guard let app = application, !app.isTerminated, let ownedLaunchDate,
              app.launchDate == ownedLaunchDate, let pid = integer(identity["pid"]),
              Int(app.processIdentifier) == pid, let current = NSRunningApplication(processIdentifier: pid_t(pid)) else { return false }
        return current.isEqual(app) && current.launchDate == ownedLaunchDate && current.bundleURL.map(canonical) == bundle
            && current.executableURL.map(canonical) == executable
    }
    private func ownedCleanup(force: Bool) {
        if force ? forceCleanupRequested : cleanupRequested { return }
        guard sameLiveInstance(), let app = application else { return }
        cleanupRequested = true
        if force { forceCleanupRequested = true; _ = app.forceTerminate() } else { _ = app.terminate() }
    }
    func run() async -> Int32 {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true; configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.hides = false; configuration.hidesOthers = false
        configuration.addsToRecentItems = false; configuration.promptsUserIfNeeded = false
        configuration.arguments = options.appArguments + ["--owned-launchservices-bootstrap",
            "--owned-launch-nonce", nonce, "--owned-launch-ready", ready.path,
            "--owned-launch-ack", ack.path, "--owned-launch-terminal", terminal.path,
            "--owned-launch-source-sha256", sourceHash, "--owned-launch-deadline-uptime-ns", String(deadline)]
        let env = ProcessInfo.processInfo.environment
        configuration.environment = ["GITHUB_ACTIONS": env["GITHUB_ACTIONS"]!,
            "RUNNER_ENVIRONMENT": env["RUNNER_ENVIRONMENT"]!, "STREAM_SCENE_SEMANTIC_ARTIFACTS": artifacts.path]
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { app, error in
            Task { @MainActor in
                self.callbackReceived = true
                do {
                    guard let app, error == nil else { throw LaunchFailure(description: "Owned launch failed: \(error?.localizedDescription ?? "missing application")") }
                    try self.capture(app)
                    if uptime() >= self.helperDeadline - 2_000_000_000 { self.ownedCleanup(force: true) }
                } catch { self.launchError = String(describing: error) }
            }
        }
        while uptime() < helperDeadline {
            do {
                // Ready-PID fallback is ownership-checked, never an app search.
                if application == nil, FileManager.default.fileExists(atPath: ready.path) {
                    let object = try readJSON(ready)
                    guard let pid = integer(object["pid"]), pid > 1,
                          let app = NSRunningApplication(processIdentifier: pid_t(pid)) else {
                        throw LaunchFailure(description: "Ready PID has no owned application")
                    }
                    try capture(app, ready: object)
                }
                if let launchError { throw LaunchFailure(description: launchError) }
                if callbackReceived && ownershipVerified && !acknowledged && failure == nil {
                    if uptime() >= helperDeadline - 2_000_000_000 { throw LaunchFailure(description: "Launch/handshake deadline expired") }
                    if FileManager.default.fileExists(atPath: ready.path) {
                        try require(sameLiveInstance(), "Owned process changed before monitor arm")
                        let object = try readJSON(ready)
                        try require(matches(object, identity) && object["phase"] as? String == "ready"
                            && object["oracleExitCode"] == nil, "Ready identity mismatch")
                        let armed = try OwnedExitMonitor(pid: pid_t(integer(identity["pid"])!))
                        monitor = armed // Strong ownership before ACK; registration receipt already checked.
                        try require(uptime() < helperDeadline - 2_000_000_000, "Monitor armed too late")
                        var armedIdentity = identity; armedIdentity["phase"] = "ack"; armedIdentity["monitorArmed"] = true
                        armedIdentity["monitorArmedUptimeNanoseconds"] = String(armed.armedAt)
                        try writeJSON(armedIdentity, ack); acknowledged = true
                    }
                }
                if let monitor, nativeExit == nil { nativeExit = try monitor.poll() }
                if nativeExit != nil, let app = application, app.isTerminated {
                    if FileManager.default.fileExists(atPath: terminal.path) {
                        let object = try readJSON(terminal)
                        terminalOracleCode = integer(object["oracleExitCode"])
                        terminalVerified = matches(object, identity) && object["phase"] as? String == "oracle"
                            && nativeExit?.normal == true && terminalOracleCode == nativeExit?.code
                            && terminalOracleCode.map { [0, 1, 77].contains($0) } == true
                    }
                    break
                }
            } catch { if failure == nil { failure = String(describing: error) } }
            if failure != nil || uptime() >= helperDeadline - 2_000_000_000 {
                if failure == nil { failure = "Owned launch/oracle timed out" }
                ownedCleanup(force: false)
                if uptime() >= helperDeadline - 1_000_000_000 { ownedCleanup(force: true) }
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let terminated = application?.isTerminated == true
        let resultVerified = failure == nil && !cleanupRequested && callbackReceived && acknowledged && ownershipVerified
            && nativeExit?.normal == true && terminalVerified && terminated
        let success = resultVerified && nativeExit?.code == 0
        var report = identity
        report["schema"] = 1
        report["nonce"] = nonce
        report["sourceSHA256"] = sourceHash
        report["binarySHA256"] = binaryHash
        report["deadlineUptimeNanoseconds"] = String(deadline)
        report["helperDeadlineUptimeNanoseconds"] = String(helperDeadline)
        report["callbackReceived"] = callbackReceived
        report["ownershipVerified"] = ownershipVerified
        report["ownedLaunchDate"] = ownedLaunchDate.map { ISO8601DateFormatter().string(from: $0) as Any } ?? NSNull()
        report["statusObserved"] = nativeExit != nil
        report["observedExitStatus"] = nativeExit.map { $0.normal ? $0.code as Any : NSNull() } ?? NSNull()
        report["observedExitReason"] = nativeExit.map { $0.normal ? "normal" : "signal" } ?? "unknown"
        report["rawWaitStatus"] = nativeExit.map { $0.raw as Any } ?? NSNull()
        report["nativeEventFlags"] = nativeExit.map { $0.flags as Any } ?? NSNull()
        report["nativeEventNotes"] = nativeExit.map { $0.notes as Any } ?? NSNull()
        report["terminalVerified"] = terminalVerified
        report["resultVerified"] = resultVerified
        report["terminalOracleExitCode"] = terminalOracleCode.map { $0 as Any } ?? NSNull()
        report["terminated"] = terminated
        report["cleanupRequested"] = cleanupRequested
        report["forceCleanupRequested"] = forceCleanupRequested
        report["verifiedSuccess"] = success
        report["failure"] = failure ?? (resultVerified ? "" : "Missing native exit, terminal or termination proof")
        report["scope"] = "Owned LaunchServices application only. Launch callback is not native exit. Missing ownership/status/termination remains unknown; no global app search or trust/input change."
        do { try writeJSON(report, artifacts.appendingPathComponent("launcher-receipt.json")) }
        catch { print("UNQUALIFIED: launcher receipt write failed: \(error)"); return 77 }
        print("Owned launcher verifiedSuccess=\(success), statusObserved=\(nativeExit != nil), terminated=\(terminated)")
        return resultVerified ? Int32(nativeExit!.code) : 77
    }
}
@main private enum SceneSelectionOwnedLauncher {
    @MainActor static func main() {
        do {
            let launcher = try OwnedApplicationLaunch(Options(Array(CommandLine.arguments.dropFirst())))
            let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
            Task { @MainActor in exit(await launcher.run()) }; app.run()
        } catch { print("UNQUALIFIED: \(error)"); exit(77) }
    }
}
#else
// Compile-only recipe: swiftc -j2 -swift-version 6 -D OWNED_SCENE_MONITOR_CONTROL
// this file -o OwnedExitMonitorControl. A separate Python parent owns/reaps a
// gated child and launches this monitor as its SIBLING, never the target's parent.
// Target waits on an owned pipe before exit0/23/SIGTERM; parent releases it ONLY
// after this monitor's atomic arm ACK. Cross-check packed event status against
// the real parent's wait status. Normal0 with a missing terminal must fail.
// No UI, AppKit launch, global process enumeration or target oracle runs here.
@main private enum OwnedMonitorControl {
    static func main() {
        do {
            let o = try Options(Array(CommandLine.arguments.dropFirst()))
            let readyURL = URL(fileURLWithPath: try o.string("--ready"))
            let ackURL = URL(fileURLWithPath: try o.string("--ack"))
            let terminalURL = URL(fileURLWithPath: try o.string("--terminal"))
            let reportURL = URL(fileURLWithPath: try o.string("--report"))
            let identity = try readJSON(readyURL)
            try require(identity["nonce"] as? String == (try o.string("--nonce")), "Control nonce mismatch")
            guard let pid = integer(identity["pid"]), pid > 1 else { throw LaunchFailure(description: "Missing control PID") }
            try require(pid != Int(getpid()) && pid != Int(getppid()), "Control must target a non-parent process")
            let deadline = try o.number("--deadline-uptime-ns")
            let now = uptime()
            try require(now < deadline && deadline - now <= 10_000_000_000, "Expired control deadline")
            try require(matches(identity, identity)
                && identity["deadlineUptimeNanoseconds"] as? String == String(deadline), "Incomplete control identity")
            let monitor = try OwnedExitMonitor(pid: pid_t(pid))
            var armedIdentity = identity; armedIdentity["phase"] = "ack"; armedIdentity["monitorArmed"] = true
            armedIdentity["monitorArmedUptimeNanoseconds"] = String(monitor.armedAt)
            try writeJSON(armedIdentity, ackURL)
            var event: NativeExit?
            while uptime() < deadline && event == nil { event = try monitor.poll(); if event == nil { usleep(1_000) } }
            let receipt = FileManager.default.fileExists(atPath: terminalURL.path) ? try readJSON(terminalURL) : [:]
            let resultVerified = event?.normal == true && matches(receipt, identity)
                && receipt["phase"] as? String == "oracle" && integer(receipt["oracleExitCode"]) == event?.code
            let verified = resultVerified && event?.code == 0
            try writeJSON(["statusObserved": event != nil, "rawWaitStatus": event.map { $0.raw as Any } ?? NSNull(),
                "observedExitReason": event.map { $0.normal ? "normal" : "signal" } ?? "unknown",
                "observedExitStatus": event.map { $0.normal ? $0.code as Any : NSNull() } ?? NSNull(),
                "nativeEventFlags": event.map { $0.flags as Any } ?? NSNull(),
                "nativeEventNotes": event.map { $0.notes as Any } ?? NSNull(),
                "monitorArmedUptimeNanoseconds": String(monitor.armedAt),
                "pid": pid, "monitorPID": Int(getpid()), "monitorParentPID": Int(getppid()),
                "verifiedSuccess": verified, "resultVerified": resultVerified, "nonce": try o.string("--nonce")], reportURL)
            exit(resultVerified ? Int32(event!.code) : 77)
        } catch { print("UNQUALIFIED monitor control: \(error)"); exit(77) }
    }
}
#endif
