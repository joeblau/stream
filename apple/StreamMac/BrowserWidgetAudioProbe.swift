import AppKit
import CoreAudio
import ScreenCaptureKit

enum BrowserWidgetAudioProbe {
    struct Process: Codable, Sendable {
        var objectID: UInt32
        var pid: Int32
        var bundleID: String
        var runningOutput: Bool
    }
    struct Report: Codable, Sendable {
        var windowServerSession = false
        var screenCapturePreflight = false
        var defaultOutputExists = false
        var deviceCount = 0
        var audioProcessCount = 0
        var helperAudioProcesses: [Process] = []
        var namedFixtureAudioProcesses: [Process] = []
        var webKitAudioProcesses: [Process] = []
        var helperShareablePIDs: [Int32] = []
        var shareableContentAvailable = false
        var shareableDisplayCount = 0
        var failure: String?
    }

    /// Read-only: never requests TCC, creates taps, or changes audio devices. Enumeration alone
    /// cannot prove which WKWebView owns a WebContent audio process.
    @MainActor static func readOnly() async -> Report {
        var report = Report()
        report.windowServerSession = CGSessionCopyCurrentDictionary() != nil
        report.screenCapturePreflight = CGPreflightScreenCaptureAccess()
        report.deviceCount = objects(kAudioHardwarePropertyDevices).count
        report.defaultOutputExists = (scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) ?? 0) != 0
        if #available(macOS 14.2, *) {
            let ids = objects(kAudioHardwarePropertyProcessObjectList)
            report.audioProcessCount = ids.count
            for id in ids {
                guard let bundleID = string(id, kAudioProcessPropertyBundleID),
                      bundleID == BrowserWidgetAudioIdentity.helperBundleID || bundleID == "com.joeblau.StreamBrowserAudioNoiseFixture" || bundleID.hasPrefix("com.apple.WebKit"),
                      let pid = scalar(id, kAudioProcessPropertyPID) else { continue }
                let process = Process(objectID: id, pid: Int32(bitPattern: pid), bundleID: bundleID,
                                      runningOutput: scalar(id, kAudioProcessPropertyIsRunningOutput) == 1)
                if bundleID == BrowserWidgetAudioIdentity.helperBundleID { report.helperAudioProcesses.append(process) }
                else if bundleID == "com.joeblau.StreamBrowserAudioNoiseFixture" { report.namedFixtureAudioProcesses.append(process) }
                else { report.webKitAudioProcesses.append(process) }
            }
        }
        guard report.windowServerSession, report.screenCapturePreflight else {
            report.failure = !report.windowServerSession ? "window_server_unavailable" : "screen_capture_not_granted"
            return report
        }
        do {
            let content = try await SCShareableContent.current
            report.shareableContentAvailable = true
            report.shareableDisplayCount = content.displays.count
            report.helperShareablePIDs = content.applications.filter {
                $0.bundleIdentifier == BrowserWidgetAudioIdentity.helperBundleID
            }.map(\.processID)
        } catch { report.failure = "shareable_content_unavailable" }
        return report
    }

    private static func objects(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0, size <= 65_536 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        return AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr ? ids : []
    }
    private static func scalar(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<UInt32>.size), value: UInt32 = 0
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value as String?
    }
}
