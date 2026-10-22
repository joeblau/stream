import AppKit
import CoreAudio
import Darwin
import Foundation
import ScreenCaptureKit

// Read-only attribution for one caller-owned Chrome parent. Never starts
// capture, creates a tap/aggregate, requests consent, or changes audio routing.
private func processInfo(_ pid: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        == MemoryLayout<proc_bsdinfo>.size ? info : nil
}
private func belongsTo(_ pid: pid_t, root: pid_t) -> Bool {
    var cursor = pid, visited = Set<pid_t>()
    for _ in 0..<16 {
        if cursor == root { return true }
        guard cursor > 1, visited.insert(cursor).inserted, let info = processInfo(cursor) else { return false }
        cursor = pid_t(info.pbi_ppid)
    }
    return false
}
private func scalar(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                            mElement: kAudioObjectPropertyElementMain)
    var bytes: UInt32 = 4, value: UInt32 = 0
    return AudioObjectGetPropertyData(object, &address, 0, nil, &bytes, &value) == noErr && bytes == 4 ? value : nil
}

@main @MainActor struct OwnedChromeAudioProcessProbe {
    static func main() async throws {
        guard #available(macOS 14.2, *) else { exit(77) }
        guard CommandLine.arguments.count == 2, let root = pid_t(CommandLine.arguments[1]), root > 1,
              let initial = processInfo(root), initial.pbi_uid == getuid(),
              let app = NSRunningApplication(processIdentifier: root), !app.isTerminated,
              let bundle = app.bundleIdentifier,
              bundle.hasPrefix("com.google.Chrome") || bundle.hasPrefix("org.chromium.Chromium") else { exit(77) }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &bytes) == noErr,
              bytes <= 65_536, bytes % 4 == 0 else { exit(77) }
        var objects = [AudioObjectID](repeating: 0, count: Int(bytes) / 4)
        if bytes > 0 {
            guard AudioObjectGetPropertyData(system, &address, 0, nil, &bytes, &objects) == noErr else { exit(77) }
        }
        let audio = objects.compactMap { object -> [String: Any]? in
            guard let bits = scalar(object, kAudioProcessPropertyPID) else { return nil }
            let pid = pid_t(bitPattern: bits)
            guard belongsTo(pid, root: root), let info = processInfo(pid), info.pbi_uid == initial.pbi_uid,
                  info.pbi_start_tvsec >= initial.pbi_start_tvsec else { return nil }
            return ["pid": pid, "objectID": object, "runningOutput": scalar(object, kAudioProcessPropertyIsRunningOutput) == 1,
                    "parent": info.pbi_ppid]
        }
        let preflight = CGPreflightScreenCaptureAccess()
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        var report: [String: Any] = ["ownedRoot": root, "audioProcesses": audio,
            "screenCapturePreflight": preflight, "sessionPresent": session != nil,
            "screenLocked": session?["CGSSessionScreenIsLocked"] as Any? ?? NSNull()]
        if preflight {
            do {
                let content = try await SCShareableContent.current
                report["shareableOwned"] = content.applications.filter { belongsTo($0.processID, root: root) }
                    .map { ["pid": $0.processID, "bundleID": $0.bundleIdentifier] as [String: Any] }
                report["shareableDisplayCount"] = content.displays.count
            } catch { report["shareableContentAvailable"] = false }
        }
        guard let final = processInfo(root), final.pbi_start_tvsec == initial.pbi_start_tvsec,
              final.pbi_start_tvusec == initial.pbi_start_tvusec, !app.isTerminated else { exit(77) }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([10]))
    }
}
