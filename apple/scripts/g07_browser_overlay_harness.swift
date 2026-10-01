import AppKit
import Foundation

// G07 (issue #114) browser-overlay measurement harness.
//
// run_g07_browser_overlay_harness.zsh compiles the REAL app-target prototype
// (StreamMac/BrowserOverlayPrototype.swift) together with this file as one
// module and runs it. The harness hosts the prototype's WKWebView in a real
// (briefly visible) window — WKWebView does not render reliably without one —
// loads each BrowserFixtures fixture at 30 and 60 fps targets, and measures:
//   - cadence:    achieved snapshot completions/sec vs the requested rate,
//   - latency:    takeSnapshot round-trip ms (mean of the window),
//   - alpha:      fixed probe points — transparent page regions must sample
//                 alpha≈0, widget pixels must keep their alpha (not flatten),
//   - CPU/memory: rusage deltas of the harness + its WebKit child processes,
//   - interaction: evaluateJavaScript round-trip latency (the programmatic
//                 channel a click-through overlay keeps),
//   - audio:      WidgetAudioRouteProbe — whether WebKit processes are
//                 capturable via ScreenCaptureKit (A06) or visible to Core
//                 Audio process taps, and whether in-page audio autoplays.
// Prints PASS/FAIL per check (S06/S12 harness convention), a markdown
// results table, and writes machine-readable JSON to argv[2] when given.

var failures = 0
@MainActor
func check(_ condition: Bool, _ name: String) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}

guard CommandLine.arguments.count >= 2 else {
    print("usage: g07-harness <fixtures-dir> [results.json]")
    exit(2)
}
let fixturesDir = CommandLine.arguments[1]
let outputPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil

// MARK: - CPU / memory sampling (libproc: self + WebKit child processes)

func cpuAndFootprint(of pid: pid_t) -> (seconds: Double, bytes: UInt64) {
    var info = rusage_info_v4()
    // C signature takes rusage_info_t* (void**): rebind the struct pointer.
    let status = withUnsafeMutablePointer(to: &info) { ptr in
        proc_pid_rusage(pid, RUSAGE_INFO_V4,
                        UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: rusage_info_t?.self))
    }
    guard status == 0 else { return (0, 0) }
    // rusage_info_v4 times are MACH ABSOLUTE units, not nanoseconds (verified
    // empirically in the G07 harness: a 2 s flat-out spinner reports ~47 M
    // raw units — exactly wall time through the 125/3 arm64 timebase).
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let seconds = Double(info.ri_user_time + info.ri_system_time)
        * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    return (seconds, info.ri_phys_footprint)
}

/// Harness launch time — the WebKit attribution cutoff (see below).
let harnessStartSec = UInt64(Date().timeIntervalSince1970)

/// CPU seconds + physical footprint of this process PLUS the WebKit helper
/// processes this harness spawned. WebKit's WebContent/Networking/GPU
/// XPC services are parented to launchd (verified: PPID 1, not the UI
/// process), so `proc_listchildpids` attribution finds nothing — instead we
/// diff by start time: any com.apple.WebKit.* process started at/after
/// harness launch is attributed to this run. Caveat for the report: another
/// app spawning a WebKit process during the window would be misattributed
/// (quiet-machine assumption, documented in the G07 findings).
func sampleProcessCost() -> (cpuSeconds: Double, footprintMB: Double, helpers: [String]) {
    var total = cpuAndFootprint(of: getpid())
    var helpers: [String] = []
    var pids = [pid_t](repeating: 0, count: 4096)
    let bytes = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.stride * pids.count))
    guard bytes > 0 else {
        return (total.seconds, Double(total.bytes) / 1_048_576, helpers)
    }
    for index in 0..<(Int(bytes) / MemoryLayout<pid_t>.stride) {
        let pid = pids[index]
        guard pid > 0 else { continue }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info,
                           Int32(MemoryLayout<proc_bsdinfo>.stride)) > 0 else { continue }
        let name = withUnsafeBytes(of: info.pbi_name) { raw -> String in
            let end = raw.firstIndex(of: 0) ?? raw.endIndex
            return String(decoding: raw[..<end], as: UTF8.self)
        }
        guard name.hasPrefix("com.apple.WebKit"),
              info.pbi_start_tvsec >= harnessStartSec - 2 else { continue }
        let helper = cpuAndFootprint(of: pid)
        total.seconds += helper.seconds
        total.bytes += helper.bytes
        helpers.append("\(name)(\(pid))")
    }
    return (total.seconds, Double(total.bytes) / 1_048_576, helpers)
}

// MARK: - Runner

@MainActor
final class HarnessRunner {
    let fixturesDir: String
    let window: NSWindow
    /// Fixture stems and whether the fixed alpha probes expect a widget at
    /// canvas center (the ticker renders a bottom strip; its center is page
    /// background).
    let fixtures: [(name: String, widgetAtCenter: Bool)] = [
        ("alert-follow", true),
        ("alert-glow", true),
        ("ticker", false)
    ]
    let fpsTargets = [30, 60]
    let warmupSeconds = 2.0
    let measureSeconds = 6.0

    var results: [[String: Any]] = []
    var audioFindings: [String: Any] = [:]

    init(fixturesDir: String) {
        self.fixturesDir = fixturesDir
        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1280, height: 720),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "G07 browser-overlay harness"
        window.isReleasedWhenClosed = false
    }

    func run() async -> Int32 {
        window.orderFrontRegardless()
        // Occluded windows are throttled by WebKit (verified: occlusion stalls
        // snapshot delivery). Activate so the measurement window is unoccluded.
        NSApplication.shared.activate(ignoringOtherApps: true)
        print("G07 harness — \(ProcessInfo.processInfo.operatingSystemVersionString)")
        if let webkit = Bundle(path: "/System/Library/Frameworks/WebKit.framework")?
            .infoDictionary?["CFBundleVersion"] as? String {
            print("WebKit bundle version: \(webkit)")
        }

        for fixture in fixtures {
            for fps in fpsTargets {
                await measure(fixture: fixture.name, widgetAtCenter: fixture.widgetAtCenter,
                              fps: fps)
            }
        }
        await probeAudio()
        printReport()
        writeResults()
        window.close()
        return failures == 0 ? 0 : 1
    }

    // MARK: Per-fixture measurement

    func measure(fixture name: String, widgetAtCenter: Bool, fps: Int) async {
        let url = URL(fileURLWithPath: fixturesDir).appendingPathComponent("\(name).html")
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("FAIL: fixture missing at \(url.path)")
            failures += 1
            return
        }
        let prototype = BrowserOverlayPrototype(content: .url(url),
                                                targetFPS: fps,
                                                pixelSize: CGSize(width: 1280, height: 720))
        prototype.webView.frame = NSRect(x: 0, y: 0, width: 1280, height: 720)
        window.contentView?.addSubview(prototype.webView)
        prototype.start()

        try? await Task.sleep(for: .seconds(warmupSeconds))
        let cpuStart = sampleProcessCost()
        let metricsStart = prototype.metrics
        let clockStart = CFAbsoluteTimeGetCurrent()

        // Cadence/latency/CPU window: let the snapshot clock run undisturbed.
        try? await Task.sleep(for: .seconds(measureSeconds))

        let elapsed = CFAbsoluteTimeGetCurrent() - clockStart
        let metricsEnd = prototype.metrics
        let cpuEnd = sampleProcessCost()

        // Alpha correctness: PAUSE the capture clock so probe snapshots don't
        // queue behind measurement load, then sample through the fixtures'
        // animation cycles (alert-follow hides ~18% of its 6 s loop, so 12
        // samples at 0.5 s always catch a visible phase).
        prototype.pauseCapture()
        try? await Task.sleep(for: .milliseconds(500))
        var alphaReport = BrowserOverlayAlphaReport()
        var bestWidgetAlpha = 0.0
        for _ in 0..<12 {
            alphaReport = await prototype.measureAlpha()
            if let widget = alphaReport.probes.first(where: { $0.label.hasPrefix("widget") }) {
                bestWidgetAlpha = max(bestWidgetAlpha, widget.alpha)
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        // Widget alpha uses the max over samples (the verdict must not depend
        // on catching the alert's visible phase at one fixed instant);
        // transparent regions are geometry-fixed page background and are
        // checked on the final sample.

        // Interaction: JS round trips on a click-through (hit-test-disabled)
        // webview — the alert-trigger channel.
        let jsSamples = await prototype.measureJavaScriptLatency(iterations: 50)
        let jsAverage = jsSamples.reduce(0, +) / Double(max(1, jsSamples.count))

        prototype.stop()
        prototype.webView.removeFromSuperview()

        let ok = metricsEnd.succeeded - metricsStart.succeeded
        let failed = metricsEnd.failed - metricsStart.failed
        let dropped = metricsEnd.dropped - metricsStart.dropped
        let achievedFPS = Double(ok) / elapsed
        let latencySum = metricsEnd.averageLatencyMs * Double(metricsEnd.succeeded)
            - metricsStart.averageLatencyMs * Double(metricsStart.succeeded)
        let averageLatency = ok > 0 ? latencySum / Double(ok) : 0
        let cpuSeconds = cpuEnd.cpuSeconds - cpuStart.cpuSeconds
        let cpuPercentOfOneCore = cpuSeconds / elapsed * 100

        print("""
          \(name) @ \(fps) fps target: achieved \(String(format: "%.1f", achievedFPS)) fps, \
          snapshot latency \(String(format: "%.1f", averageLatency)) ms, \
          CPU \(String(format: "%.0f", cpuPercentOfOneCore))% of one core, \
          footprint \(String(format: "%.0f", cpuEnd.footprintMB)) MB, failed \(failed), dropped \(dropped)
          webkit helpers: \(cpuEnd.helpers.joined(separator: ", "))
        """)

        check(achievedFPS >= Double(fps) * 0.8,
              "\(name)@\(fps): cadence reaches ≥80% of target (measured \(String(format: "%.1f", achievedFPS)))")
        check(averageLatency < 1000 / Double(fps),
              "\(name)@\(fps): snapshot latency under one frame interval")
        let transparentOK = alphaReport.transparentRegionsClear
        check(transparentOK, "\(name)@\(fps): transparent page regions sample alpha≈0")
        if widgetAtCenter {
            check(bestWidgetAlpha > 0.5,
                  "\(name)@\(fps): widget pixels keep alpha (max \(String(format: "%.2f", bestWidgetAlpha)))")
        } else {
            check(bestWidgetAlpha < 0.02,
                  "\(name)@\(fps): empty canvas center stays transparent")
        }
        check(jsAverage < 50,
              "\(name)@\(fps): evaluateJavaScript round-trip < 50 ms avg (measured \(String(format: "%.1f", jsAverage)) ms)")

        results.append([
            "fixture": name,
            "targetFPS": fps,
            "achievedFPS": achievedFPS,
            "snapshotLatencyMs": averageLatency,
            "cpuPercentOfOneCore": cpuPercentOfOneCore,
            "cpuSeconds": cpuSeconds,
            "footprintMB": cpuEnd.footprintMB,
            "snapshotsOK": ok,
            "snapshotsFailed": failed,
            "windowSeconds": elapsed,
            "alphaTransparentRegionsClear": transparentOK,
            "alphaWidgetMax": bestWidgetAlpha,
            "alphaProbes": alphaReport.probes.map {
                ["label": $0.label, "alpha": $0.alpha, "r": $0.red, "g": $0.green, "b": $0.blue]
            },
            "jsRoundTripMsAvg": jsAverage,
            "snapshotsDropped": dropped,
            "webkitHelpers": cpuEnd.helpers
        ])
    }

    // MARK: Audio routing probe

    func probeAudio() async {
        // Baseline: what the capture surfaces see BEFORE widget audio plays.
        let before = await WidgetAudioRouteProbe.probe()
        check(before.shareableContentAvailable,
              "audio: SCShareableContent available (Screen Recording granted) — \(before.shareableContentError ?? "ok")")
        check(!before.webKitProcessVisibleToScreenCaptureKit,
              "audio: no WebKit process is an SCK per-app capture target (as documented)")

        // Play the audio-widget fixture: a synthesized Web Audio sting.
        let url = URL(fileURLWithPath: fixturesDir).appendingPathComponent("audio-widget.html")
        let prototype = BrowserOverlayPrototype(content: .url(url), targetFPS: 5,
                                                pixelSize: CGSize(width: 640, height: 360))
        prototype.webView.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        window.contentView?.addSubview(prototype.webView)
        prototype.start()
        try? await Task.sleep(for: .seconds(3))
        let audioState = await prototype.evaluateProbe("window.__widgetAudioState")
        // While the sting repeats, Core Audio should list the WebContent
        // process as a live audio process object (macOS 14.2+ surface).
        let during = await WidgetAudioRouteProbe.probe()
        try? await Task.sleep(for: .seconds(1))
        prototype.stop()
        prototype.webView.removeFromSuperview()

        check(audioState == "running",
              "audio: widget AudioContext autoplays (state=\(audioState ?? "nil"))")
        print("audio: Core Audio process objects during playback: \(during.audioProcessBundleIDs.joined(separator: ", "))")
        check(during.webKitProcessVisibleToCoreAudio,
              "audio: WebKit WebContent visible to Core Audio process taps while playing")

        audioFindings = [
            "shareableContentAvailable": before.shareableContentAvailable,
            "shareableContentError": before.shareableContentError ?? "",
            "webkitVisibleToSCK": before.webKitProcessVisibleToScreenCaptureKit,
            "capturableAppCount": before.capturableBundleIDs.count,
            "widgetAudioContextState": audioState ?? "unknown",
            "coreAudioProcessBundleIDs": during.audioProcessBundleIDs,
            "webkitVisibleToCoreAudio": during.webKitProcessVisibleToCoreAudio
        ]
    }

    // MARK: Report

    func printReport() {
        print("""

        | fixture | target fps | achieved fps | snapshot ms | CPU % (1 core) | MB | alpha T/W | JS ms |
        |---|---|---|---|---|---|---|---|
        """)
        for result in results {
            print("| \(result["fixture"] ?? "")"
                + " | \(result["targetFPS"] ?? "")"
                + " | \(String(format: "%.1f", result["achievedFPS"] as? Double ?? 0))"
                + " | \(String(format: "%.1f", result["snapshotLatencyMs"] as? Double ?? 0))"
                + " | \(String(format: "%.0f", result["cpuPercentOfOneCore"] as? Double ?? 0))"
                + " | \(String(format: "%.0f", result["footprintMB"] as? Double ?? 0))"
                + " | \(result["alphaTransparentRegionsClear"] as? Bool == true ? "ok" : "FAIL")/\(String(format: "%.2f", result["alphaWidgetMax"] as? Double ?? 0))"
                + " | \(String(format: "%.1f", result["jsRoundTripMsAvg"] as? Double ?? 0)) |")
        }
    }

    func writeResults() {
        guard let outputPath else { return }
        let payload: [String: Any] = [
            "issue": "G07 #114",
            "date": ISO8601DateFormatter().string(from: Date()),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "measurements": results,
            "audioFindings": audioFindings,
            "failures": failures
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: outputPath))
            print("results written to \(outputPath)")
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let runner = HarnessRunner(fixturesDir: fixturesDir)
Task { @MainActor in
    let code = await runner.run()
    exit(code)
}
app.run()
