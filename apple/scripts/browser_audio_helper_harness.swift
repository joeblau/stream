import AppKit
import AVFoundation
import CoreMedia
import StreamCore

private final class HelperProcess: @unchecked Sendable {
    let process = Process()
    let input = Pipe(), output = Pipe()
    private var application: NSRunningApplication?
    private var connection: FileHandle?
    private var listener: BrowserWidgetAudioSocket?
    var pid: Int32 { application?.processIdentifier ?? process.processIdentifier }
    private let lock = NSLock()
    private var replies: [BrowserWidgetAudioReply] = []
    init(executable: URL, arguments: [String] = []) throws {
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        readReplies(output.fileHandleForReading)
    }
    private init() {}
    @MainActor static func launch(applicationURL: URL, arguments: [String] = []) async throws -> HelperProcess {
        let helper = HelperProcess()
        let listener = try BrowserWidgetAudioSocket()
        helper.listener = listener
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments + ["--ipc-socket", listener.path]
        configuration.activates = false; configuration.createsNewApplicationInstance = true; configuration.addsToRecentItems = false
        helper.application = try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
        do { helper.connection = try await listener.accept(expectedPID: helper.pid) }
        catch { helper.application?.terminate(); throw error }
        helper.readReplies(helper.connection!)
        return helper
    }
    private func readReplies(_ handle: FileHandle) {
        DispatchQueue(label: "browser-helper-fixture.replies").async { [self] in
            var bytes = Data()
            var chunk = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = Darwin.read(handle.fileDescriptor, &chunk, chunk.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                bytes.append(contentsOf: chunk.prefix(count))
                guard bytes.count <= BrowserWidgetAudioCommand.maximumLineBytes else { break }
                while let end = bytes.firstIndex(of: 10) {
                    let line = Data(bytes[..<end]); bytes.removeSubrange(...end)
                    if let value = try? JSONDecoder().decode(BrowserWidgetAudioReply.self, from: line) {
                        lock.withLock { if replies.count == 128 { replies.removeFirst() }; replies.append(value) }
                    }
                }
            }
        }
    }
    func send(_ command: BrowserWidgetAudioCommand) throws {
        let bytes = try command.encodedLine()
        try (connection ?? input.fileHandleForWriting).write(contentsOf: bytes)
    }
    func has(_ state: BrowserWidgetAudioReply.State, id: UUID? = nil, media: String? = nil) -> Bool {
        lock.withLock { replies.contains { $0.state == state && (id == nil || $0.widgetID == id) && (media == nil || $0.mediaState == media) } }
    }
    func close() {
        try? send(.init(action: .close)); try? (connection ?? input.fileHandleForWriting).close()
        application?.terminate()
        if process.isRunning { process.terminate() }
    }
}

private final class AudioTrace: @unchecked Sendable {
    private let lock = NSLock(), converter = CanonicalAudioConverter()
    private var values: [Float] = []
    private var pts: [Double] = []
    private(set) var maximumArrivalError = 0.0
    var frameCount: Int { lock.withLock { values.count / 2 } }
    var timestamps: [Double] { lock.withLock { pts } }
    func append(_ sample: CMSampleBuffer) {
        lock.withLock {
            guard let pcm = converter.convert(sample), let floats = CanonicalAudioConverter.interleavedFloats(pcm) else { return }
            if values.count + floats.count <= 48_000 * 2 * 30 { values += floats }
            if pts.count < 4_096 { pts.append(sample.presentationTimeStamp.seconds) }
            maximumArrivalError = max(maximumArrivalError, abs(CMClockGetTime(CMClockGetHostTimeClock()).seconds - sample.presentationTimeStamp.seconds))
        }
    }
    func amplitude(_ frequency: Double, channel: Int, seconds: Double = 0.5) -> Double {
        let samples = lock.withLock { () -> [Float] in
            guard let last = pts.last, CMClockGetTime(CMClockGetHostTimeClock()).seconds - last < seconds else { return [] }
            return Array(values.suffix(Int(seconds * 48_000) * 2))
        }
        guard samples.count >= 4_800 else { return 0 }
        var real = 0.0, imaginary = 0.0
        let frames = samples.count / 2
        for frame in 0..<frames {
            let phase = Double(frame) * 2 * .pi * frequency / 48_000
            let value = Double(samples[frame * 2 + channel])
            real += value * cos(phase); imaginary += value * sin(phase)
        }
        return 2 * hypot(real, imaginary) / Double(frames)
    }
    func export(_ url: URL) throws {
        let (samples, times, error) = lock.withLock { (values, pts, maximumArrivalError) }
        precondition(samples.count > 48_000 * 2)
        precondition(zip(times, times.dropFirst()).allSatisfy { $0 < $1 }, "PTS must remain strictly ordered")
        let format = CanonicalAudioConverter.canonicalFormat
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count / 2))!
        pcm.frameLength = pcm.frameCapacity
        samples.withUnsafeBufferPointer { data in
            pcm.mutableAudioBufferList.pointee.mBuffers.mData!.copyMemory(from: data.baseAddress!, byteCount: samples.count * 4)
        }
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
            try file.write(from: pcm)
        }
        let decoded = try AVAudioFile(forReading: url)
        precondition(decoded.fileFormat.channelCount == 2 && decoded.length == Int64(samples.count / 2))
        let metadata: [String: Any] = ["frames": decoded.length, "sampleRate": 48_000, "channels": 2,
            "firstHostPTS": times.first!, "lastHostPTS": times.last!, "maximumArrivalErrorSeconds": error]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: url.appendingPathExtension("json"))
    }
}

@main struct BrowserAudioHelperHarness {
    @MainActor static func main() async throws {
        signal(SIGPIPE, SIG_IGN)
        let report = await BrowserWidgetAudioProbe.readOnly()
        print(String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
        fflush(nil)
        precondition(!BrowserWidgetAudioIdentity.productionRouteQualified)
        try protocolChecks()
        try await inletChecks()
        guard CommandLine.arguments.contains("--qualify") else {
            print("PASS: read-only inventory and bounded helper protocol. Capture was not started.")
            return
        }
        guard report.windowServerSession, report.screenCapturePreflight, report.shareableContentAvailable, report.defaultOutputExists else {
            print("GATED: existing WindowServer, Screen Recording permission, and output device are required. No TCC/device mutation or fallback.")
            return
        }
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let build = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let artifacts = build.appendingPathComponent("qualification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let helper: HelperProcess, noise: HelperProcess
        if !CommandLine.arguments.contains("--direct-process-negative") {
            helper = try await HelperProcess.launch(applicationURL: build.appendingPathComponent("StreamBrowserAudioHelper.app"))
            noise = try await HelperProcess.launch(applicationURL: build.appendingPathComponent("StreamBrowserAudioNoiseFixture.app"), arguments: ["--native-tone", "1320"])
        } else {
            helper = try HelperProcess(executable: build.appendingPathComponent("StreamBrowserAudioHelper.app/Contents/MacOS/StreamBrowserAudioHelper"))
            noise = try HelperProcess(executable: build.appendingPathComponent("StreamBrowserAudioNoiseFixture.app/Contents/MacOS/StreamBrowserAudioNoiseFixture"), arguments: ["--native-tone", "1320"])
        }
        defer { helper.close(); noise.close() }
        print("Fixture stage: waiting for helper/noise readiness"); fflush(nil)
        try await wait { helper.has(.ready) && noise.has(.ready) }
        let left = UUID(), right = UUID()
        try helper.send(.init(action: .load, widgetID: left, html: toneHTML(frequency: 440, pan: -1)))
        try helper.send(.init(action: .load, widgetID: right, html: toneHTML(frequency: 880, pan: 1)))
        print("Fixture stage: waiting for widget navigation"); fflush(nil)
        try await wait { helper.has(.loaded, id: left) && helper.has(.loaded, id: right) }
        try helper.send(.init(action: .probe, widgetID: left)); try helper.send(.init(action: .probe, widgetID: right))
        print("Fixture stage: waiting for widget audio contexts"); fflush(nil)
        try await wait { helper.has(.probe, id: left, media: "running") && helper.has(.probe, id: right, media: "running") }
        let playingReport = await BrowserWidgetAudioProbe.readOnly()
        try JSONEncoder().encode(playingReport).write(to: artifacts.appendingPathComponent("helper-attribution-inventory.json"))

        let mixer = AudioMixEngine()
        let leaseA = UUID(), leaseB = UUID()
        let firstLease = await mixer.reserveCaptureHoldback(token: leaseA, milliseconds: 20)
        let secondLease = await mixer.reserveCaptureHoldback(token: leaseB, milliseconds: 80)
        precondition(firstLease && secondLease)
        let combinedTiming = await mixer.captureTimingSnapshot()
        precondition(combinedTiming.holdbackMilliseconds == 80 && combinedTiming.leaseCount == 2)
        await mixer.releaseCaptureHoldback(leaseB)
        let remainingTiming = await mixer.captureTimingSnapshot()
        precondition(remainingTiming.holdbackMilliseconds == 20 && remainingTiming.leaseCount == 1)
        await mixer.releaseCaptureHoldback(leaseA)
        let invalidTiming = await mixer.reserveCaptureHoldback(token: UUID(), milliseconds: .nan)
        precondition(!invalidTiming)
        let raw = AudioTrace(), program = AudioTrace(), monitorTrace = AudioTrace(), isolated = AudioTrace(), unrelated = AudioTrace()
        let capture = BrowserWidgetAudioCapture(mixer: mixer) { sample in raw.append(sample); mixer.enqueue(.application(bundleID: BrowserWidgetAudioIdentity.helperBundleID), sample) }
        let noiseCapture = AppAudioCapture()
        noiseCapture.onAudioSampleOffMain = { unrelated.append($0) }
        await noiseCapture.start(with: AppAudioSourcePayload(bundleID: "com.joeblau.StreamBrowserAudioNoiseFixture", appName: "Named noise fixture"))
        guard noiseCapture.isCapturing else { print("GATED: named independent-app capture unavailable: \(noiseCapture.errorMessage ?? "unknown")"); return }
        defer { Task { @MainActor in await noiseCapture.stop() } }
        await mixer.addChannel(capture.channel)
        await mixer.setChannelGain(capture.channel, volume: 1, isMuted: false)
        let programToken = UUID(), monitorToken = UUID(), isolatedToken = UUID()
        let monitorOutput = MonitorOutput()
        await mixer.addTap(bus: .program, token: programToken) { program.append($0) }
        await mixer.addTap(bus: .monitor, token: monitorToken) { monitorTrace.append($0); monitorOutput.play($0) }
        await mixer.addIsolatedTap(channel: capture.channel, token: isolatedToken) { isolated.append($0) }
        await mixer.run()
        do { try await capture.startForQualification(helperPID: helper.pid) }
        catch {
            await mixer.stop(); await noiseCapture.stop()
            print("GATED: helper-only capture rejected (\(type(of: error))). No substitution."); return
        }
        try await Task.sleep(for: .seconds(2.5))
        if !CommandLine.arguments.contains("--direct-process-negative") { try await stableTone(raw) }
        var leftBaseline = raw.amplitude(440, channel: 0), rightBaseline = raw.amplitude(880, channel: 1)
        print("Helper spectra: left440=\(leftBaseline), right880=\(rightBaseline), leaked1320=\(raw.amplitude(1320, channel: 0)); unrelated own1320=\(unrelated.amplitude(1320, channel: 0)); frames helper=\(raw.frameCount), unrelated=\(unrelated.frameCount); inlet \(String(decoding: try JSONEncoder().encode(capture.statistics()), as: UTF8.self))"); fflush(nil)
        let noiseBaseline = unrelated.amplitude(1320, channel: 0)
        try recordCandidate(.application, capture: capture, raw: raw, unrelated: unrelated, artifacts: artifacts)
        if leftBaseline <= 0.0005 || rightBaseline <= 0.0005 || raw.amplitude(1320, channel: 0) >= noiseBaseline * 0.02 {
            // A separate explicit public-filter experiment, never a system/global fallback.
            await capture.stop()
            do { try await capture.startForQualification(helperPID: helper.pid, style: .independentWindow) }
            catch { await noiseCapture.stop(); await mixer.stop(); print("GATED: helper-window candidate unavailable. No substitution."); return }
            try await Task.sleep(for: .seconds(1.5))
            leftBaseline = raw.amplitude(440, channel: 0); rightBaseline = raw.amplitude(880, channel: 1)
            try recordCandidate(.independentWindow, capture: capture, raw: raw, unrelated: unrelated, artifacts: artifacts)
            print("Helper-window spectra: left440=\(leftBaseline), right880=\(rightBaseline), leaked1320=\(raw.amplitude(1320, channel: 0))"); fflush(nil)
        }
        guard leftBaseline > 0.0005, rightBaseline > 0.0005, noiseBaseline > 0.0005, raw.amplitude(1320, channel: 0) < noiseBaseline * 0.02 else {
            await capture.stop(); await noiseCapture.stop(); await mixer.stop()
            try JSONEncoder().encode(capture.statistics()).write(to: artifacts.appendingPathComponent("inlet-statistics.json"))
            print("GATED: helper-only WebKit audio and isolation were not measured. Unqualified PCM is discarded; inventory alone is insufficient. Metrics: \(artifacts.path)"); return
        }
        precondition(raw.amplitude(1320, channel: 0) < noiseBaseline * 0.02,
                     "Helper capture must exclude a separately identified sounding app")
        precondition(raw.amplitude(440, channel: 1) < leftBaseline * 0.02 && raw.amplitude(880, channel: 0) < rightBaseline * 0.02, "Stereo widget identity must survive")
        print("Mixer spectra: program440=\(program.amplitude(440, channel: 0)), isolated440=\(isolated.amplitude(440, channel: 0)), raw maximum arrival error=\(raw.maximumArrivalError)"); fflush(nil)
        precondition(capture.isCapturing, "The helper capture must still be active")
        let timing = await mixer.captureTimingSnapshot()
        precondition(timing.holdbackMilliseconds == 80 && timing.leaseCount == 1)
        precondition(program.amplitude(440, channel: 0) > leftBaseline * 0.8 && isolated.amplitude(440, channel: 0) > leftBaseline * 0.8)

        // Real monitor playback stays in this process. App-pinned helper capture must not recapture it.
        monitorOutput.applyConfiguration(enabled: true, deviceUID: nil)
        precondition(monitorOutput.errorMessage == nil)
        await mixer.setBusGain(.monitor, gain: 0.25)
        // A uniquely named return tone is played through the REAL monitor path in this process.
        // Its frequency makes loopback attribution measurable independently of startup gain.
        let returnMixer = AudioMixEngine(), returnOutput = MonitorOutput(), returnTrace = AudioTrace()
        let returnChannel = AudioChannelID.guest(id: "monitor-return-1000-fixture")
        await returnMixer.setChannelGain(returnChannel, volume: 1, isMuted: false)
        await returnMixer.addTap(bus: .monitor, token: UUID()) { sample in returnTrace.append(sample); returnOutput.play(sample) }
        await returnMixer.run()
        await returnMixer.addChannel(returnChannel)
        returnOutput.applyConfiguration(enabled: true, deviceUID: nil)
        precondition(returnOutput.errorMessage == nil)
        let returnTask = Task.detached {
            while !Task.isCancelled {
                let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                if let sample = try? ProgramRecordingFixtures.audio(at: now, timestampBase: 0, constantTone: true, amplitude: 0.025) {
                    returnMixer.enqueue(returnChannel, sample)
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        try await Task.sleep(for: .seconds(1))
        print("Actual monitor counts: helperPlayed=\(monitorOutput.statistics.playedChunks), returnPlayed=\(returnOutput.statistics.playedChunks); return1000=\(returnTrace.amplitude(1000, channel: 0)), recaptured1000=\(raw.amplitude(1000, channel: 0))"); fflush(nil)
        precondition(monitorOutput.statistics.playedChunks > 0, "Actual monitor hardware playback must advance")
        precondition(returnOutput.statistics.playedChunks > 0 && returnTrace.amplitude(1000, channel: 0) > 0.01)
        precondition(raw.amplitude(1000, channel: 0) < leftBaseline * 0.02, "Actual unique monitor return must not be recaptured")
        precondition(abs(raw.amplitude(440, channel: 0) / leftBaseline - 1) < 0.15, "Program monitor return must not double helper capture")
        precondition(monitorTrace.amplitude(440, channel: 0) > leftBaseline * 0.18 && monitorTrace.amplitude(440, channel: 0) < leftBaseline * 0.4)
        await mixer.setChannelGain(capture.channel, volume: 0.5, isMuted: false)
        try await Task.sleep(for: .seconds(0.8))
        precondition(abs(program.amplitude(440, channel: 0) / leftBaseline - 0.5) < 0.12)
        precondition(abs(isolated.amplitude(440, channel: 0) / leftBaseline - 1) < 0.15)
        await mixer.setChannelGain(capture.channel, volume: 1, isMuted: true)
        try await Task.sleep(for: .seconds(0.8))
        precondition(program.amplitude(440, channel: 0) < leftBaseline * 0.02 && isolated.amplitude(440, channel: 0) > leftBaseline * 0.8)
        await mixer.setChannelGain(capture.channel, volume: 1, isMuted: false)

        // Hiding a widget in the prototype is explicit media suspension; the sibling and noise continue.
        try helper.send(.init(action: .suspend, widgetID: left))
        try await Task.sleep(for: .seconds(0.8))
        precondition(raw.amplitude(440, channel: 0) < leftBaseline * 0.02 && raw.amplitude(880, channel: 1) > rightBaseline * 0.8 && unrelated.amplitude(1320, channel: 0) > noiseBaseline * 0.8)
        try helper.send(.init(action: .resume, widgetID: left))
        try await Task.sleep(for: .seconds(0.8))
        precondition(raw.amplitude(440, channel: 0) > leftBaseline * 0.8)
        try helper.send(.init(action: .reload, widgetID: left))
        try await Task.sleep(for: .seconds(0.8))
        precondition(raw.amplitude(440, channel: 0) > leftBaseline * 0.8 && raw.amplitude(880, channel: 1) > rightBaseline * 0.8)
        try helper.send(.init(action: .stop, widgetID: left))
        try await Task.sleep(for: .seconds(0.8))
        precondition(raw.amplitude(440, channel: 0) < leftBaseline * 0.02 && raw.amplitude(880, channel: 1) > rightBaseline * 0.8 && unrelated.amplitude(1320, channel: 0) > noiseBaseline * 0.8)
        try helper.send(.init(action: .stop, widgetID: right))
        try await Task.sleep(for: .seconds(0.8))
        precondition(raw.amplitude(440, channel: 0) < leftBaseline * 0.02 && raw.amplitude(880, channel: 1) < rightBaseline * 0.02 && unrelated.amplitude(1320, channel: 0) > noiseBaseline * 0.8)
        await capture.stop(); await noiseCapture.stop(); monitorOutput.applyConfiguration(enabled: false, deviceUID: nil)
        returnTask.cancel(); await returnMixer.stop(); returnOutput.applyConfiguration(enabled: false, deviceUID: nil)
        let releasedTiming = await mixer.captureTimingSnapshot()
        precondition(releasedTiming.holdbackMilliseconds == 5 && releasedTiming.leaseCount == 0)
        await mixer.stop()
        try await Task.sleep(for: .milliseconds(100))
        let commonPTSs = Set(program.timestamps).intersection(isolated.timestamps)
        precondition(commonPTSs.count > 500 && commonPTSs.count >= min(program.timestamps.count, isolated.timestamps.count) - 1,
                     "Program/isolated outputs must retain the exact same host media timestamps")
        for (name, trace) in [("helper",raw),("program",program),("monitor",monitorTrace),("isolated",isolated),("unrelated",unrelated)] {
            try trace.export(artifacts.appendingPathComponent("\(name).caf"))
        }
        let stats = capture.statistics()
        precondition(stats.delivered > 100 && stats.maximumPendingFrames <= 9_600)
        precondition(stats.maximumPendingBytes <= 256 * 1_024 && stats.dropped == stats.discardedOnStop, "Normal native capture must not shed live inlet PCM")
        precondition(raw.maximumArrivalError < 0.3, "Capture PTS must remain on the actual host clock")
        try JSONEncoder().encode(stats).write(to: artifacts.appendingPathComponent("inlet-statistics.json"))
        print("PASS: actual ad hoc helper WebKit app attribution, stereo two-tone PCM, unrelated-app isolation, mixer gain/mute/program/ISO/monitor buses, monitor-return exclusion, suspend/resume/reload/stop sibling isolation, decoded CAF duration/channels and ordered host PTS. Production signing, full widget lifecycle, system-mix exclusion, speech and endurance remain gated. Artifacts: \(artifacts.path)")
    }
    @MainActor private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<160 { if predicate() { return }; try await Task.sleep(for: .milliseconds(50)) }
        throw CocoaError(.coderInvalidValue)
    }
    private static func stableTone(_ trace: AudioTrace) async throws {
        var previous = 0.0, stable = 0
        for _ in 0..<16 {
            let left = trace.amplitude(440, channel: 0), right = trace.amplitude(880, channel: 1)
            if left > 0.0005, right > 0.0005, abs(left / right - 1) < 0.05,
               previous > 0, abs(left / previous - 1) < 0.05 { stable += 1 } else { stable = 0 }
            if stable >= 3 { return }
            previous = left; try await Task.sleep(for: .milliseconds(500))
        }
        throw CocoaError(.coderInvalidValue)
    }
    @MainActor private static func recordCandidate(_ style: BrowserWidgetAudioCapture.FilterStyle, capture: BrowserWidgetAudioCapture, raw: AudioTrace, unrelated: AudioTrace, artifacts: URL) throws {
        struct Candidate: Codable {
            var filter: BrowserWidgetAudioCapture.FilterIdentity?
            var helperLeft440: Double; var helperRight880: Double; var leaked1320: Double; var independent1320: Double
            var capture: BrowserWidgetPCMInlet.Statistics
        }
        let record = Candidate(filter: capture.requestedFilterIdentity, helperLeft440: raw.amplitude(440, channel: 0),
                               helperRight880: raw.amplitude(880, channel: 1), leaked1320: raw.amplitude(1320, channel: 0),
                               independent1320: unrelated.amplitude(1320, channel: 0), capture: capture.statistics())
        try JSONEncoder().encode(record).write(to: artifacts.appendingPathComponent("\(style.rawValue)-candidate.json"))
    }
    private static func protocolChecks() throws {
        try BrowserWidgetAudioCommand(action: .load, widgetID: UUID(), html: "fixture").validate()
        for command in [BrowserWidgetAudioCommand(action: .load, widgetID: UUID(), html: String(repeating: "a", count: 65_537)),
                        BrowserWidgetAudioCommand(action: .load, widgetID: UUID(), url: URL(string: "http://example.com")),
                        BrowserWidgetAudioCommand(action: .load, widgetID: UUID(), url: URL(string: "https://user:secret@example.com")),
                        BrowserWidgetAudioCommand(action: .load, widgetID: nil, html: "fixture")] {
            do { try command.validate(); preconditionFailure("Invalid helper commands must fail") } catch {}
        }
        do {
            _ = try BrowserWidgetAudioCommand(action: .load, widgetID: UUID(), html: String(repeating: "\0", count: 60_000)).encodedLine()
            preconditionFailure("Encoded IPC size must also be bounded")
        } catch {}
    }
    private static func inletChecks() async throws {
        let inlet = BrowserWidgetPCMInlet { _ in Thread.sleep(forTimeInterval: 0.01) }
        let generation = inlet.begin()
        for index in 0..<100 {
            let sample = try ProgramRecordingFixtures.audio(at: Double(index) / 100, constantTone: true)
            inlet.post(sample, generation: generation)
        }
        await inlet.stop()
        inlet.post(try ProgramRecordingFixtures.audio(at: 2), generation: generation)
        let stats = inlet.statistics()
        precondition(stats.received == 100 && stats.received == stats.delivered + stats.dropped)
        precondition(stats.dropped > stats.discardedOnStop && stats.maximumPendingFrames <= 9_600 && stats.maximumPendingBytes <= 256 * 1_024 && stats.rejected == 1 && stats.pendingFrames == 0)
        print("PASS: actual PCM inlet overload accounting, bounded queue, stop drain and stale-generation rejection")
    }
    private static func toneHTML(frequency: Int, pan: Int) -> String {
        """
        <!DOCTYPE html><meta charset="utf-8"><body>Named \(frequency) Hz widget fixture<script>
        const context = new AudioContext(); const oscillator = context.createOscillator();
        const gain = context.createGain(); const panner = context.createStereoPanner();
        oscillator.frequency.value = \(frequency); gain.gain.value = 0.025; panner.pan.value = \(pan);
        oscillator.connect(gain).connect(panner).connect(context.destination); oscillator.start();
        window.__widgetAudioState = context.state; context.onstatechange = () => window.__widgetAudioState = context.state;
        context.resume();
        </script>
        """
    }
}
