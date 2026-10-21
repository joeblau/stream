import AppKit
import AVFoundation
import CoreMedia
import StreamCore
import SwiftUI

@MainActor enum BrowserLifecycleCaptureReceipts {
    static var screenPrivacy: [EffectiveCapturePrivacy] = []
    static var appExclusions: [Set<String>] = []
}
@MainActor enum BrowserOperatorSeedGate {
    static var armed = false, held = false
    private static var continuation: CheckedContinuation<Void, Never>?
    static func pause() async {
        guard armed else { return }
        armed = false; held = true
        await withCheckedContinuation { continuation = $0 }
        held = false
    }
    static func release() { continuation?.resume(); continuation = nil }
}
private func require(_ value: Bool, _ message: String) { precondition(value, message) }
private func hostNow() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }
private func pcm(_ pts: CMTime, value: Float) -> CMSampleBuffer {
    let values = [Float](repeating: value, count: 1_024)
    var block: CMBlockBuffer?
    values.withUnsafeBytes { bytes in
        require(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0,
            blockBufferOut: &block) == noErr, "Owned PCM allocation")
        _ = CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes.count)
    }
    var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
        mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?, sample: CMSampleBuffer?
    require(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, "Owned PCM format")
    require(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!,
        formatDescription: format!, sampleCount: 512, presentationTimeStamp: pts, packetDescriptions: nil,
        sampleBufferOut: &sample) == noErr, "Owned timed PCM")
    return sample!
}
private struct AudioPacket: Sendable { var pts: Double; var values: [Float] }
private final class Trace: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [AudioPacket] = []
    func append(_ sample: CMSampleBuffer) {
        let block = sample.dataBuffer!
        var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
        values.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        lock.withLock { packets.append(.init(pts: sample.presentationTimeStamp.seconds, values: values)) }
    }
    func mean(from: Double, to: Double) -> Float {
        let values = lock.withLock { packets.filter { $0.pts >= from && $0.pts < to }.flatMap(\.values) }
        require(values.count >= 4_096, "Actual mixer did not deliver enough timed PCM")
        return values.reduce(0, +) / Float(values.count)
    }
    func firstNonzero(after: Double) -> Double? {
        lock.withLock {
            for packet in packets where packet.pts >= after {
                if let index = packet.values.firstIndex(where: { abs($0) > 0.001 }) {
                    return packet.pts + Double(index / 2) / 48_000
                }
            }
            return nil
        }
    }
    func maxAbs(after: Double) -> Float {
        lock.withLock { packets.filter { $0.pts >= after }.flatMap(\.values).map(abs).max() ?? 0 }
    }
}
private final class Insert: @unchecked Sendable {
    private let lock = NSLock()
    private var processed = 0, resets = 0
    private var tail: Float = 0
    private var armed = false
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    func arm() { lock.withLock { armed = true } }
    func waitEntered() -> Bool { entered.wait(timeout: .now() + 1) == .success }
    func process(_ sample: CMSampleBuffer) -> CMSampleBuffer {
        let hold = lock.withLock { let value = armed; armed = false; return value }
        if hold {
            entered.signal()
            require(release.wait(timeout: .now() + 3) == .success, "Owned held insert cleanup exceeded bound")
        }
        var first: Float = 0
        _ = CMBlockBufferCopyDataBytes(sample.dataBuffer!, atOffset: 0, dataLength: 4, destination: &first)
        let held = lock.withLock { processed += 1; if first != 0 { tail = first }; return tail }
        // An actual stateful insert tail: silence would reveal retained signal
        // after reopening unless the existing processor's reset hook was called.
        return first == 0 && held != 0 ? pcm(sample.presentationTimeStamp, value: held) : sample
    }
    func reset() { lock.withLock { resets += 1; tail = 0 } }
    func counts() -> (Int, Int) { lock.withLock { (processed, resets) } }
}
private final class QueuedISO: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let trace = Trace()
    private var first = true // Owned by the actual mailbox's one serial consumer.
    func receive(_ sample: CMSampleBuffer) {
        if first {
            first = false; entered.signal()
            require(release.wait(timeout: .now() + 3) == .success, "Owned ISO hold cleanup exceeded bound")
            return // An already-entered consumer owns this first frame.
        }
        trace.append(sample)
    }
    func waitEntered() -> Bool { entered.wait(timeout: .now() + 1) == .success }
}
@MainActor private final class SyntheticCapture: BrowserWidgetAudioDriver {
    let requiresScreenCaptureAccess = false
    var onFailure: (@MainActor (String) -> Void)?
    private(set) var isCapturing = false
    private(set) var starts = 0, stops = 0
    let inlet: BrowserWidgetPCMInlet
    var holdNextStart = false
    private(set) var startIsHeld = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private(set) var generation = UUID()
    var generatedAmplitude: Float?
    private var generatedTask: Task<Void, Never>?
    init(mixer: AudioMixEngine) {
        inlet = BrowserWidgetPCMInlet { mixer.enqueue(.application(bundleID: BrowserWidgetAudioIdentity.helperBundleID), $0) }
    }
    func start(helperPID: Int32) async throws {
        require(helperPID > 0, "Synthetic driver must still be paired to an actual owned helper PID")
        starts += 1
        if holdNextStart {
            holdNextStart = false; startIsHeld = true
            await withCheckedContinuation { startContinuation = $0 }
            startIsHeld = false
        }
        generation = inlet.begin(); isCapturing = true
        if let value = generatedAmplitude {
            let inlet = self.inlet, generation = self.generation
            generatedTask = Task.detached(priority: .userInitiated) {
                var pts = hostNow() - CMTime(value: 512, timescale: 48_000)
                while !Task.isCancelled {
                    inlet.post(pcm(pts, value: value), generation: generation)
                    pts = pts + CMTime(value: 512, timescale: 48_000)
                    try? await Task.sleep(for: .seconds(max(0, (pts + CMTime(value: 512, timescale: 48_000) - hostNow()).seconds)))
                }
            }
        }
    }
    func releaseStart() { startContinuation?.resume(); startContinuation = nil }
    func invalidateInput() { inlet.invalidate() }
    func stop() async {
        isCapturing = false; stops += 1
        generatedTask?.cancel(); await generatedTask?.value; generatedTask = nil
        await inlet.stop()
    }
    func post(_ sample: CMSampleBuffer, generation: UUID? = nil) { inlet.post(sample, generation: generation ?? self.generation) }
}
@main @MainActor struct BrowserWidgetLifecycleHarness {
    private static weak var inspectedSession: BrowserWidgetHelperSession?
    static func wait(_ reason: String, _ ready: () -> Bool) async throws {
        for _ in 0..<800 { if ready() { return }; try await Task.sleep(for: .milliseconds(10)) }
        if let session = inspectedSession {
            print("Timeout state: demands=\(session.demandCount), audible=\(session.audibleLeases.count), capturing=\(session.audioIsCapturing), failure=\(session.failure ?? "none"), reason=\(session.audioUnavailableReason ?? "none")")
        }
        throw NSError(domain: "BrowserLifecycle", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
    }
    static func main() {
        setbuf(stdout, nil); signal(SIGPIPE, SIG_IGN)
        guard CGSessionCopyCurrentDictionary() != nil else { print("UNQUALIFIED: owned helper IPC needs WindowServer"); exit(77) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch {
                let unqualified = (error as NSError).code == 77
                print("\(unqualified ? "UNQUALIFIED" : "FAIL"): \(error.localizedDescription)")
                exit(unqualified ? 77 : 1)
            }
        }
        app.run()
    }
    static func run() async throws {
        try await BrowserHelperLifecycleChecks.run()
        precondition(!BrowserWidgetAudioIdentity.productionRouteQualified)
        let application = URL(fileURLWithPath: CommandLine.arguments[1])
        try await queuedISOChecks()
        try await canceledLoadChecks(application)
        try await sessionChecks(application)
        try await controllerChecks(application)
        try await operatorChecks(application)
        print("PASS: actual helper IPC/Program leases + controller capture demand + native mixer retirement. Captured PCM is synthetic; no SCK capture, audible page, permission request, signing/install operation or production activation.")
        if let path = ProcessInfo.processInfo.environment["BROWSER_LIFECYCLE_COMPLETION"] {
            try Data("PASS".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
    static func queuedISOChecks() async throws {
        let mixer = AudioMixEngine(), channel = AudioChannelID.application(bundleID: BrowserWidgetAudioIdentity.helperBundleID)
        let queued = QueuedISO()
        await mixer.run(); await mixer.setChannelGain(channel, volume: 1, isMuted: false)
        await mixer.addIsolatedTap(channel: channel, token: UUID(), capacity: 256, sink: queued.receive)
        let producer = Task { @MainActor in
            var pts = hostNow() - CMTime(value: 512, timescale: 48_000)
            while !Task.isCancelled {
                mixer.enqueue(channel, pcm(pts, value: 0.25)); pts = pts + CMTime(value: 512, timescale: 48_000)
                try? await Task.sleep(for: .seconds(max(0, (pts + CMTime(value: 512, timescale: 48_000) - hostNow()).seconds)))
            }
        }
        let entered = await Task.detached { queued.waitEntered() }.value
        require(entered, "Actual ISO mailbox did not enter its owned hold")
        try await Task.sleep(for: .milliseconds(120))
        let levels = await mixer.levelsSnapshot()
        require((levels.channels[channel]?.peak ?? 0) > 0.2, "Held ISO fixture never queued actual source PCM")
        mixer.setCaptureRouteAllowed(channel, allowed: false)
        producer.cancel(); await producer.value
        await mixer.resetCaptureRouteHistory(channel)
        mixer.setCaptureRouteAllowed(channel, allowed: true)
        queued.release.signal()
        try await Task.sleep(for: .milliseconds(100))
        require(queued.trace.maxAbs(after: 0) == 0, "Retained old ISO frames became audible when the capture gate reopened")
        await mixer.stop()
        print("PASS: real256-frame ISO mailbox retains old PCM across close→reset→reopen; original-PTS authority rejects every queued old frame")
    }
    static func canceledLoadChecks(_ application: URL) async throws {
        let mixer = AudioMixEngine(), driver = SyntheticCapture(mixer: mixer)
        let session = BrowserWidgetHelperSession(applicationURL: application, mixer: mixer, validationAudioDriver: driver)
        var loadingTask: Task<Bool, Never>?
        loadingTask = Task { @MainActor in
            do {
                try await session.loadForQualification(id: UUID(), generation: UUID(), html: "<body>Never installed canceled load</body>", options: .init(),
                    callbacks: .init(state: { if $0 == .loading { loadingTask?.cancel() } }, frame: { _, _ in }, snapshotFailed: {}))
                return true
            } catch { return false }
        }
        let returnedSuccess = await loadingTask!.value
        loadingTask = nil
        await session.waitUntilStopped()
        require(!returnedSuccess && session.demandCount == 0 && session.helperPID == nil && !driver.isCapturing,
                "Cancel-only load during launch leaked demand/helper or returned success")
        print("PASS: cancel-only actual load after demand insertion retires owned launch/connection without a separate release")
    }
    static func sessionChecks(_ application: URL) async throws {
        let mixer = AudioMixEngine(), driver = SyntheticCapture(mixer: mixer)
        let session = BrowserWidgetHelperSession(applicationURL: application, mixer: mixer, validationAudioDriver: driver)
        inspectedSession = session
        let channel = session.channel, insert = Insert()
        let program = Trace(), monitor = Trace(), aux = Trace(), pre = Trace(), post = Trace()
        await mixer.run()
        await mixer.addChannel(channel, resetInsert: insert.reset, insert: insert.process)
        await mixer.setChannelGain(channel, volume: 0.6, isMuted: false)
        await mixer.setChannelAuxSend(channel, gain: 0.3)
        await mixer.setChannelDelays([channel.label: 140])
        await mixer.addTap(bus: .program, token: UUID(), sink: program.append)
        await mixer.addTap(bus: .monitor, token: UUID(), sink: monitor.append)
        await mixer.addTap(bus: .aux, token: UUID(), sink: aux.append)
        await mixer.addIsolatedTap(channel: channel, token: UUID(), processing: .beforeEffects, sink: pre.append)
        await mixer.addIsolatedTap(channel: channel, token: UUID(), processing: .afterEffects, sink: post.append)
        let a = BrowserWidgetPageLease(widgetID: UUID(), generation: UUID())
        let b = BrowserWidgetPageLease(widgetID: UUID(), generation: UUID())
        var ready = Set<UUID>()
        let callbacks: (UUID) -> BrowserWidgetHelperSession.Callbacks = { id in
            .init(state: { if $0 == .ready { ready.insert(id) } }, frame: { _, _ in }, snapshotFailed: {})
        }
        try await session.loadForQualification(id: a.widgetID, generation: a.generation, html: "<body>Silent Program A</body>", options: .init(), callbacks: callbacks(a.widgetID))
        try await session.loadForQualification(id: b.widgetID, generation: b.generation, html: "<body>Silent Preview B</body>", options: .init(), callbacks: callbacks(b.widgetID))
        try await wait("Silent pages did not load") { ready.count == 2 }
        try await Task.sleep(for: .milliseconds(150))
        require(driver.starts == 0 && !mixer.captureRouteIsAllowed(channel), "Loading/Preview alone authorized capture")
        session.setProgramAudioDemand([a], applyingExclusions: session.requiredSystemAudioExclusions)
        session.setProgramAudioDemand([], applyingExclusions: session.requiredSystemAudioExclusions)
        try await Task.sleep(for: .milliseconds(100))
        require(driver.starts == 0 && session.audibleLeases.isEmpty, "Queued pre-begin Program demand replayed after removal")
        session.setProgramAudioDemand([a], applyingExclusions: [])
        try await wait("Missing exclusion did not remain unavailable") { session.audioUnavailableReason?.contains("exclude") == true }
        require(driver.starts == 0, "Capture started without helper exclusion contract")
        session.setProgramAudioDemand([a], applyingExclusions: session.requiredSystemAudioExclusions)
        try await wait("Actual helper resume ACK did not authorize only Program A") { session.audibleLeases == [a] && mixer.captureRouteIsAllowed(channel) }
        let oldGeneration = driver.generation
        let producer = Task { @MainActor in
            var pts = hostNow() - CMTime(value: 512, timescale: 48_000)
            while !Task.isCancelled {
                driver.post(pcm(pts, value: 0.25))
                pts = pts + CMTime(value: 512, timescale: 48_000)
                try? await Task.sleep(for: .seconds(max(0, (pts + CMTime(value: 512, timescale: 48_000) - hostNow()).seconds)))
            }
        }
        try await Task.sleep(for: .milliseconds(450))
        let before = hostNow().seconds
        try await Task.sleep(for: .milliseconds(120))
        require(abs(program.mean(from: before, to: hostNow().seconds) - 0.15) < 0.002, "Actual Program fader changed")
        require(abs(aux.mean(from: before, to: hostNow().seconds) - 0.075) < 0.002, "Actual Aux send changed")
        require(abs(pre.mean(from: before, to: hostNow().seconds) - 0.25) < 0.002 && abs(post.mean(from: before, to: hostNow().seconds) - 0.25) < 0.002, "Actual ISO sample path changed")
        producer.cancel(); await producer.value
        insert.arm()
        driver.post(pcm(hostNow(), value: 0.9))
        let entered = await Task.detached { insert.waitEntered() }.value
        require(entered, "Actual opaque channel insert did not enter its owned hold")
        // The actual mixer tick now waits on the channel lock held by that
        // insert. MainActor retirement must not wait on either lock.
        try await Task.sleep(for: .milliseconds(30))
        let boundaryStart = ProcessInfo.processInfo.systemUptime
        session.setProgramAudioDemand([], applyingExclusions: session.requiredSystemAudioExclusions)
        let boundaryMilliseconds = (ProcessInfo.processInfo.systemUptime - boundaryStart) * 1_000
        require(boundaryMilliseconds < 50, "MainActor retirement waited on the opaque insert/mix lock")
        print("Held opaque insert + actual mixer tick: synchronous revoke returned in \(boundaryMilliseconds)ms")
        require(!mixer.captureRouteIsAllowed(channel) && session.audibleLeases.isEmpty, "Program removal did not synchronously close authority")
        let closed = hostNow().seconds
        driver.post(pcm(hostNow(), value: 0.9), generation: oldGeneration)
        mixer.enqueue(channel, pcm(hostNow() - CMTime(value: 512, timescale: 48_000), value: 0.9))
        session.setProgramAudioDemand([b], applyingExclusions: session.requiredSystemAudioExclusions)
        require(!mixer.captureRouteIsAllowed(channel), "New Program demand reopened before old inlet drain")
        insert.release.signal()
        try await wait("Fresh Program B did not wait for held inlet drain") { session.audibleLeases == [b] }
        try await Task.sleep(for: .milliseconds(220))
        for trace in [program, monitor, aux, pre, post] { require(trace.maxAbs(after: closed + 0.025) == 0, "Retired helper escaped into a bus, delayed history or ISO") }
        require(insert.counts().0 > 0 && insert.counts().1 >= 2, "Actual inserted processor was replaced instead of reset")
        // A held capture-start completion must never reopen an obsolete Program lease.
        driver.holdNextStart = true
        session.setProgramAudioDemand([a], applyingExclusions: session.requiredSystemAudioExclusions)
        try await wait("Synthetic driver did not hold its actual start await") { driver.startIsHeld }
        session.setProgramAudioDemand([b], applyingExclusions: session.requiredSystemAudioExclusions)
        require(!mixer.captureRouteIsAllowed(channel) && session.audibleLeases.isEmpty, "Held stale start retained audio authority")
        driver.releaseStart()
        try await wait("Stale start completion did not yield to fresh Program B") { session.audibleLeases == [b] }
        driver.post(pcm(CMTime(seconds: closed - 0.02, preferredTimescale: 48_000), value: 0.9))
        let freshStart = hostNow().seconds
        try await Task.sleep(for: .milliseconds(200))
        driver.post(pcm(hostNow() - CMTime(value: 512, timescale: 48_000), value: 0))
        try await Task.sleep(for: .milliseconds(240))
        for trace in [program, monitor, aux, pre, post] { require(trace.maxAbs(after: freshStart + 0.025) == 0, "Fresh inlet accepted old PTS or retained insert FX tail") }
        let origin = hostNow() - CMTime(value: 512, timescale: 48_000)
        let freshProducer = Task { @MainActor in
            var pts = origin
            while !Task.isCancelled {
                driver.post(pcm(pts, value: 0.25))
                pts = pts + CMTime(value: 512, timescale: 48_000)
                try? await Task.sleep(for: .seconds(max(0, (pts + CMTime(value: 512, timescale: 48_000) - hostNow()).seconds)))
            }
        }
        try await Task.sleep(for: .milliseconds(500))
        freshProducer.cancel(); await freshProducer.value
        let first = program.firstNonzero(after: freshStart)!
        require(abs(first - origin.seconds - 0.140) < 0.012, "Capture retirement changed original source PTS or saved140ms delay")
        let end = hostNow().seconds
        require(abs(program.mean(from: end - 0.150, to: end) - 0.15) < 0.002 && abs(aux.mean(from: end - 0.150, to: end) - 0.075) < 0.002, "Reopen lost saved fader/Aux configuration")
        session.setSuspended(id: a.widgetID, generation: UUID(), suspended: true)
        require(session.audibleLeases == [b], "Old-generation suspension disrupted current Program")
        let gate = application.deletingLastPathComponent().appendingPathComponent("retirement-gate")
        let enteredFile = gate.appendingPathExtension("entered"), releaseFile = gate.appendingPathExtension("release")
        for file in [gate, enteredFile, releaseFile] { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: gate)
        let startsBeforeRetirement = driver.starts
        session.release(a.widgetID)
        try await wait("Actual helper retirement completion was not held") { FileManager.default.fileExists(atPath: enteredFile.path) }
        try await Task.sleep(for: .milliseconds(120))
        require(session.audibleLeases.isEmpty && !mixer.captureRouteIsAllowed(channel) && driver.starts == startsBeforeRetirement,
                "Shared capture reopened before retired-page suspension acknowledgment")
        let superseded = UUID(), replacement = UUID()
        var replacementReady = false
        let firstLoad = Task { @MainActor in
            do {
                try await session.loadForQualification(id: a.widgetID, generation: superseded, html: "<body>Superseded quiet page</body>", options: .init(), callbacks: callbacks(a.widgetID))
                return true
            } catch { return false }
        }
        await Task.yield()
        let latestLoad = Task { @MainActor in
            do {
                try await session.loadForQualification(id: a.widgetID, generation: replacement, html: "<body>Latest quiet page</body><script>window.__lifecycle='latest'</script>", options: .init(),
                    callbacks: .init(state: { if $0 == .ready { replacementReady = true } }, frame: { _, _ in }, snapshotFailed: {}))
                return true
            } catch { return false }
        }
        await Task.yield()
        try Data().write(to: releaseFile)
        let staleLoadInstalled = await firstLoad.value, latestLoadInstalled = await latestLoad.value
        require(!staleLoadInstalled && latestLoadInstalled, "Concurrent loads returning from retirement overwrote their per-widget claim")
        try await wait("Latest replacement page did not load") { replacementReady }
        let latestDOM = await session.evaluate(id: a.widgetID, generation: replacement, expression: "window.__lifecycle")
        let staleDOM = await session.evaluate(id: a.widgetID, generation: superseded, expression: "window.__lifecycle")
        require(latestDOM == "latest" && staleDOM == nil, "Superseded load owns the actual replacement page")
        try await wait("Releasing Preview A lost Program B") { session.audibleLeases == [b] }
        require(session.demandedAudioChannels == [channel], "One remaining page lost shared helper channel")
        for file in [gate, enteredFile, releaseFile] { try? FileManager.default.removeItem(at: file) }
        session.release(a.widgetID)
        session.release(b.widgetID); await session.waitUntilStopped()
        require(session.demandedAudioChannels.isEmpty && !mixer.captureRouteIsAllowed(channel), "Last page did not retire shared authority")
        await mixer.stop()
        print("PASS: real helper load/suspend/resume ACKs; Preview silent; exclusion required; Program-only lease; all5buses/ISO/delay zero after held opaque insert+mix retirement; retired-page ACK barrier held; concurrent replacement claims fenced with actual latest DOM; queued + held stale starts fenced; old generation/PTS and real insert tail rejected; exact fader/Aux/140ms original-grid delay restored; last-page shutdown")
    }
    static func controllerChecks(_ application: URL) async throws {
        let mixer = AudioMixEngine(), driver = SyntheticCapture(mixer: mixer)
        let session = BrowserWidgetHelperSession(applicationURL: application, mixer: mixer, validationAudioDriver: driver)
        inspectedSession = session
        BrowserOverlayHelperBackend.qualificationSession = session
        defer { BrowserOverlayHelperBackend.qualificationSession = nil }
        let store = SceneStore(directory: GuestFixtureStorage.machineDirectory.appendingPathComponent("BrowserScenes"))
        func web(_ name: String) -> LayerNode {
            let config = BrowserOverlayConfiguration(urlString: "https://lifecycle.invalid/\(name)", audioRoute: .helperApp)
            return LayerNode(name: name, payload: .web(.init(configuration: config)), transform: .fullscreen)
        }
        let sceneA = Scene(name: "Program A", layers: [web("A")])
        let sceneB = Scene(name: "Preview B", layers: [web("B")])
        store.scenes = [sceneA, sceneB]
        let model = PreviewProgramModel(selected: sceneA)
        let controller = StreamController(sceneStore: store, previewProgram: model, permissions: PermissionsManager(), audioEngine: mixer)
        await mixer.run(); controller.startPreview()
        let unrelated = Trace(), unrelatedChannel = AudioChannelID.microphone(deviceUID: nil)
        await mixer.setChannelGain(unrelatedChannel, volume: 1, isMuted: false)
        await mixer.addTap(bus: .program, token: UUID(), sink: unrelated.append)
        let unrelatedProducer = Task { @MainActor in
            var pts = hostNow() - CMTime(value: 512, timescale: 48_000)
            while !Task.isCancelled {
                mixer.enqueue(unrelatedChannel, pcm(pts, value: 0.2)); pts = pts + CMTime(value: 512, timescale: 48_000)
                try? await Task.sleep(for: .seconds(max(0, (pts + CMTime(value: 512, timescale: 48_000) - hostNow()).seconds)))
            }
        }
        try await wait("Actual Controller Program A did not become audible") { session.audibleLeases.count == 1 }
        let a = session.audibleLeases
        model.stage(sceneB)
        try await wait("Actual Preview source did not share helper") { session.demandCount == 2 }
        try await Task.sleep(for: .milliseconds(150))
        require(session.audibleLeases == a && controller.capturePool.browserAudioChannels == [session.channel], "Preview audio leaked or shared channel keep uses wrong identity")
        _ = model.take()
        try await wait("Actual Take did not replace Program lease") { session.audibleLeases.count == 1 && session.audibleLeases != a }
        let oldB = session.audibleLeases
        let bKey = CaptureSourceKey.demanded(layers: sceneB.layers, sources: store.sources).first!
        let host = controller.capturePool.webHost(for: bKey)!
        host.reload()
        require(session.audibleLeases.isEmpty && !mixer.captureRouteIsAllowed(session.channel), "Reload did not revoke old page before replacement Task entered")
        try await wait("Actual helper reload did not install a fresh Program generation") { session.audibleLeases.count == 1 && session.audibleLeases != oldB }
        require(session.audibleLeases.count == 1, "Reload lost current Program lease")
        // Opaque screen-audio route must consume required exclusion configuration and
        // refuse the optional helper. The generated boundary records this actual start
        // request instead of opening the system picker/capturing the desktop.
        let screen = ScreenSourcePayload()
        var blocked = sceneB
        blocked.layers.append(.init(name: "Opaque screen audio", payload: .screen(screen), transform: .fullscreen))
        model.stage(blocked)
        try await wait("Overlapping capture did not close helper audio") { session.audioUnavailableReason?.contains("overlapping") == true && !driver.isCapturing }
        require(!mixer.captureRouteIsAllowed(session.channel), "Overlapping capture left helper mixer open")
        let independentStart = hostNow().seconds
        try await Task.sleep(for: .milliseconds(120))
        require(abs(unrelated.mean(from: independentStart, to: hostNow().seconds) - 0.2) < 0.002,
                "Optional helper exclusion failure muted or reset unrelated native Program PCM")
        require(BrowserLifecycleCaptureReceipts.screenPrivacy.last?.excludedBundleIDs.contains(BrowserWidgetAudioIdentity.helperBundleID) == true, "Actual screen-start settings did not consume helper exclusion")
        model.stage(sceneB)
        try await Task.sleep(for: .milliseconds(150))
        require(session.audibleLeases.isEmpty && session.audioUnavailableReason?.contains("fully stopped") == true,
                "Demand removal silently treated an unacknowledged broad capture stop as exclusion proof")
        // Broad app capture has the same conservative unavailable state and keeps its
        // own source demand; no capture is performed by this isolated fixture boundary.
        let broad = SourceDefinition(name: "System audio", payload: .appAudio(.init(mode: .system)))
        store.addSource(broad)
        model.stage(sceneA)
        try await wait("Broad app audio did not consume helper exclusion while helper remained unavailable") {
            session.audioUnavailableReason?.contains("overlapping") == true &&
                BrowserLifecycleCaptureReceipts.appExclusions.last?.contains(BrowserWidgetAudioIdentity.helperBundleID) == true
        }
        require(BrowserLifecycleCaptureReceipts.appExclusions.last?.contains(BrowserWidgetAudioIdentity.helperBundleID) == true, "System audio start did not consume helper exclusion")
        store.removeSource(broad.id); model.stage(sceneB)
        try await Task.sleep(for: .milliseconds(150))
        require(session.audibleLeases.isEmpty && !mixer.captureRouteIsAllowed(session.channel), "Removed broad route silently bypassed latched exclusion gate")
        unrelatedProducer.cancel(); await unrelatedProducer.value
        controller.capturePool.stopAll(); await session.waitUntilStopped(); await mixer.stop()
        require(session.demandCount == 0 && !driver.isCapturing && !mixer.captureRouteIsAllowed(session.channel), "Controller stop retained helper capture authority")
        print("PASS: actual Controller Program/Preview/Take and shared application-channel retention; opaque screen + system-audio conflicts explicit/latched unavailable until real stop qualification, required exclusions consumed, unrelated native Program PCM stays0.2; stop retires allpages")
    }
    private struct OperatorNode: Decodable, Sendable {
        let role: String, label: String, value: String
        let enabled: Bool
    }
    private static func operatorClient(_ arguments: [String] = []) async throws -> [OperatorNode] {
        let parent = String(getpid())
        guard let path = ProcessInfo.processInfo.environment["STREAM_ACCESSIBILITY_CLIENT"] else {
            throw NSError(domain: "BrowserOperator", code: 77, userInfo: [NSLocalizedDescriptionKey: "Use lifecycle runner for the owned-process AX client"])
        }
        return try await Task.detached {
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: path); process.arguments = [parent] + arguments
            process.standardOutput = output; process.standardError = errors
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "BrowserOperator", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)])
            }
            return try JSONDecoder().decode([OperatorNode].self, from: data)
        }.value
    }
    static func operatorChecks(_ application: URL) async throws {
        let mixer = AudioMixEngine(), driver = SyntheticCapture(mixer: mixer)
        let session = BrowserWidgetHelperSession(applicationURL: application, mixer: mixer, validationAudioDriver: driver)
        inspectedSession = session
        BrowserOverlayHelperBackend.qualificationSession = session
        defer { BrowserOverlayHelperBackend.qualificationSession = nil }
        let channel = session.channel, label = channel.label, target = "channel." + label
        let store = SceneStore(directory: GuestFixtureStorage.machineDirectory.appendingPathComponent("BrowserOperatorScenes"))
        let config = BrowserOverlayConfiguration(urlString: "https://lifecycle.invalid/operator", audioRoute: .helperApp)
        let scene = Scene(name: "Operator helper", layers: [.init(name: "Helper", payload: .web(.init(configuration: config)), transform: .fullscreen)])
        let blank = Scene(name: "No helper", layers: [])
        store.scenes = [scene, blank]
        let model = PreviewProgramModel(selected: scene)
        let controller = StreamController(sceneStore: store, previewProgram: model, permissions: PermissionsManager(), audioEngine: mixer)
        let settings = SettingsSession(controller: controller), recorder = RecordingController()
        recorder.loadPreferences(directory: GuestFixtureStorage.machineDirectory.appendingPathComponent("BrowserOperatorRecordings"))
        var saved = settings.activeSettings.mixer
        saved.channelVolumes[label] = 0.8; saved.channelMutes[label] = false
        saved.soloedChannels = []; saved.channelAuxSends[label] = 0.8
        settings.persistMixer(saved)
        let dispatcher = StudioCommandDispatcher(controller: controller, sceneStore: store, session: settings, recorder: recorder, previewProgram: model)
        let unavailable = await controller.recordingAudioSources()
        require(!unavailable.contains { $0.id == target }, "Saved mixer state fabricated helper ISO capability without demand")
        require(controller.addRecordingAudioTap(targetID: target, processing: .afterEffects, sink: { _ in }) == nil,
                "Stale helper ISO selection started a tap before qualification demand")
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 330), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Owned Browser Operator Proof"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: VStack {
            MixerPanelView().environmentObject(dispatcher).environmentObject(controller).environmentObject(store).environmentObject(model)
            RecordingOptionsView(recorder: recorder).environmentObject(controller)
        }.frame(width: 1000, height: 330))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        require(!(try await operatorClient()).contains { $0.label.contains(BrowserWidgetAudioIdentity.channelTitle) }, "Dormant saved helper strip was exposed")
        let wrongModel = PreviewProgramModel(selected: scene)
        let wrong = StreamController(sceneStore: store, previewProgram: wrongModel, permissions: PermissionsManager(), audioEngine: AudioMixEngine())
        wrong.startPreview()
        require(wrong.capturePool.sourceErrors.values.contains { $0.contains("different runtime mixer") }, "Replacement runtime reused old qualification mixer")
        require(wrong.browserAudioChannels.isEmpty && session.demandCount == 0 && session.helperPID == nil,
                "Wrong runtime fabricated helper capability or launched a page")
        require(wrong.addRecordingAudioTap(targetID: target, processing: .afterEffects, sink: { _ in }) == nil,
                "Wrong runtime installed a helper tap on its different mixer")
        wrong.capturePool.stopAll()
        let program = Trace(), monitor = Trace(), aux = Trace(), iso = Trace()
        // Match the real driver's existing bounded 80ms capture holdback; source
        // workers preserve original host PTS and run independently of UI/AX work.
        let holdback = UUID()
        require(await mixer.reserveCaptureHoldback(token: holdback, milliseconds: BrowserWidgetAudioCapture.qualificationHoldbackMilliseconds), "Owned operator fixture holdback unavailable")
        driver.generatedAmplitude = 0.3
        await mixer.run()
        await mixer.setChannelGain(.microphone(deviceUID: nil), volume: 1, isMuted: false)
        await mixer.setBusGain(.program, gain: 1); await mixer.setBusGain(.monitor, gain: 1); await mixer.setBusGain(.aux, gain: 1)
        await mixer.addTap(bus: .program, token: UUID(), sink: program.append)
        await mixer.addTap(bus: .monitor, token: UUID(), sink: monitor.append)
        await mixer.addTap(bus: .aux, token: UUID(), sink: aux.append)
        let producer = Task.detached(priority: .userInitiated) {
            var pts = hostNow() - CMTime(value: 512, timescale: 48_000)
            while !Task.isCancelled {
                mixer.enqueue(.microphone(deviceUID: nil), pcm(pts, value: 0.2))
                pts = pts + CMTime(value: 512, timescale: 48_000)
                try? await Task.sleep(for: .seconds(max(0, (pts + CMTime(value: 512, timescale: 48_000) - hostNow()).seconds)))
            }
        }
        BrowserOperatorSeedGate.armed = true
        let admissionStart = hostNow().seconds
        controller.startPreview()
        try await wait("Actual Controller did not hold the old mixer seed") { BrowserOperatorSeedGate.held }
        _ = dispatcher.execute(.setChannelVolume(channel, 0.5))
        _ = dispatcher.execute(.setChannelMuted(channel, true))
        _ = dispatcher.execute(.setChannelSolo(channel, true))
        _ = dispatcher.execute(.setChannelAuxSend(channel, 0.25))
        try await Task.sleep(for: .milliseconds(40))
        _ = await mixer.statsSnapshot() // Newer live pushes reach the real actor before releasing the stale seed.
        require(!mixer.captureRouteIsAllowed(channel), "Held mixer seed admitted PCM before validation")
        BrowserOperatorSeedGate.release()
        try await wait("Operator helper did not complete actual Program media ACKs") { session.audibleLeases.count == 1 }
        let initial = hostNow().seconds
        try await Task.sleep(for: .milliseconds(160))
        require(program.maxAbs(after: admissionStart) <= 0.201, "Saved helper mute leaked unity PCM on first route admission")
        require(abs(monitor.mean(from: initial, to: hostNow().seconds)) < 0.001, "Saved muted helper solo was not restored before admission")
        require(aux.maxAbs(after: admissionStart) <= 0.0751, "Stale saved Aux send leaked before current preparation")
        print("PASS: actual held stale mixer seed revalidates newer gain/mute/solo/Aux before first-buffer admission; wrong-runtime mixer session rejected without launch or tap")
        let discovered = await controller.recordingAudioSources()
        require(discovered.filter { $0.id == target }.count == 1 && discovered.first { $0.id == target }?.name == BrowserWidgetAudioIdentity.channelTitle,
                "Shared helper ISO discovery duplicated or mislabeled the actual application channel")
        require(discovered.first { $0.id == target }?.isAvailable == true, "Actual helper PCM remained falsely unavailable")
        let nodes = try await operatorClient()
        require(nodes.contains { $0.label == "Unmute " + BrowserWidgetAudioIdentity.channelTitle && $0.enabled }, "Actual SwiftUI helper strip did not expose restored mute")
        require(nodes.contains { $0.label == "Clear solo for " + BrowserWidgetAudioIdentity.channelTitle }, "Actual SwiftUI helper strip lost monitor-only solo")
        _ = try await operatorClient(["increment", BrowserWidgetAudioIdentity.channelTitle + " volume"])
        try await wait("Actual native helper fader did not dispatch its value") { (dispatcher.state.mixer.channelVolumes[label] ?? 0) > 0.5 }
        _ = dispatcher.execute(.setChannelVolume(channel, 0.5))
        _ = try await operatorClient(["press", "Unmute " + BrowserWidgetAudioIdentity.channelTitle])
        try await wait("Native helper mute button did not dispatch unmute") { dispatcher.state.mixer.channelMutes[label] != true }
        guard let tap = controller.addRecordingAudioTap(targetID: target, processing: .afterEffects, sink: iso.append) else { preconditionFailure("Actual qualified helper ISO tap unavailable") }
        let loud = hostNow().seconds + 0.04
        try await Task.sleep(for: .milliseconds(240))
        print("Operator PCM: Program=\(program.mean(from: loud, to: hostNow().seconds)), Monitor=\(monitor.mean(from: loud, to: hostNow().seconds)), Aux=\(aux.mean(from: loud, to: hostNow().seconds)), ISO=\(iso.mean(from: loud, to: hostNow().seconds)); mixer=\(dispatcher.state.mixer.channelVolumes[label] ?? -1), muted=\(dispatcher.state.mixer.channelMutes[label] == true)")
        require(abs(program.mean(from: loud, to: hostNow().seconds) - 0.35) < 0.003, "Helper fader did not change actual Program PCM")
        require(abs(monitor.mean(from: loud, to: hostNow().seconds) - 0.15) < 0.003, "Helper solo affected Program or failed to isolate Monitor")
        require(abs(aux.mean(from: loud, to: hostNow().seconds) - 0.075) < 0.003, "Saved helper Aux send did not initialize actual channel")
        require(abs(iso.mean(from: loud, to: hostNow().seconds) - 0.3) < 0.003, "Helper isolated tap used Program mix or fader gain")
        _ = try await operatorClient(["press", "Clear solo for " + BrowserWidgetAudioIdentity.channelTitle])
        _ = try await operatorClient(["press", BrowserWidgetAudioIdentity.channelTitle + " aux send"])
        let clear = hostNow().seconds + 0.04
        try await Task.sleep(for: .milliseconds(240))
        require(abs(monitor.mean(from: clear, to: hostNow().seconds) - 0.35) < 0.003 && aux.maxAbs(after: clear) < 0.001,
                "Native helper monitor/Aux buttons did not route actual PCM")
        _ = try await operatorClient(["press", "Mute " + BrowserWidgetAudioIdentity.channelTitle])
        try await wait("Native helper mute did not persist") { dispatcher.state.mixer.channelMutes[label] == true }
        print("PASS: actual external AX fader/mute/solo/Aux actions reached shared channel PCM; opening existing Recording Options")
        _ = try await operatorClient(["press", "Recording Options"])
        try await Task.sleep(for: .milliseconds(240))
        _ = try await operatorClient(["press", BrowserWidgetAudioIdentity.channelTitle])
        require(recorder.preferences.isolatedTracks.contains { $0.targetID == target }, "Actual recording options did not select the shared helper ISO track")
        require(recorder.preferences.isolatedTracks.count <= 8, "Helper selection bypassed existing track capacity")
        window.makeFirstResponder(nil)
        // Close the owned popover by its native escape before changing demand.
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        NSApp.sendEvent(escape)
        model.stage(blank); _ = model.take()
        try await wait("Last helper page did not retire despite saved ISO selection") { session.demandCount == 0 && !driver.isCapturing }
        await session.waitUntilStopped()
        try await Task.sleep(for: .milliseconds(150))
        require(!(await controller.recordingAudioSources()).contains { $0.id == target }, "Retired helper retained ISO capability through its old tap")
        require(controller.addRecordingAudioTap(targetID: target, processing: .afterEffects, sink: { _ in }) == nil, "Saved retired helper ISO restarted capture")
        let retired = hostNow().seconds
        try await Task.sleep(for: .milliseconds(120))
        require(iso.maxAbs(after: retired) == 0, "Retired helper ISO emitted queued or retained PCM")
        require(!(try await operatorClient()).contains { $0.label == "Mute " + BrowserWidgetAudioIdentity.channelTitle || $0.label == "Unmute " + BrowserWidgetAudioIdentity.channelTitle }, "Retired helper retained enabled mixer controls")
        require(settings.activeSettings.mixer.channelMutes[label] == true && settings.activeSettings.mixer.channelVolumes[label] == 0.5,
                "Retirement erased the operator's saved mixer intent")
        controller.removeAudioTap(tap)
        settings.flushPendingWrites()
        let reloaded = SettingsSession(controller: controller)
        require(reloaded.activeSettings.mixer.channelMutes[label] == true && reloaded.activeSettings.mixer.channelVolumes[label] == 0.5,
                "Helper mixer intent did not survive actual owned settings persistence")
        let restored = hostNow().seconds
        model.stage(scene); _ = model.take()
        try await wait("Fresh demanded helper did not return") { session.audibleLeases.count == 1 }
        try await Task.sleep(for: .milliseconds(130))
        require(program.maxAbs(after: restored) <= 0.201, "Demand restart forgot saved helper mute")
        BrowserOperatorSeedGate.armed = true
        let currentKey = CaptureSourceKey.demanded(layers: scene.layers, sources: store.sources).first!
        controller.capturePool.webHost(for: currentKey)!.reload()
        try await wait("Reload did not hold final mixer preparation") { BrowserOperatorSeedGate.held }
        model.stage(blank); _ = model.take()
        try await wait("Retired held preparation retained page demand") { session.demandCount == 0 }
        BrowserOperatorSeedGate.release()
        await session.waitUntilStopped()
        require(session.audibleLeases.isEmpty && !mixer.captureRouteIsAllowed(channel) && !driver.isCapturing,
                "Late held mixer preparation reopened retired source")
        producer.cancel(); await producer.value
        controller.capturePool.stopAll(); await session.waitUntilStopped()
        await mixer.releaseCaptureHoldback(holdback); await mixer.stop()
        require(!BrowserWidgetAudioIdentity.productionRouteQualified, "Operator controls enabled production helper selection")
        print("PASS: actual shared helper + installed SwiftUI mixer/recording UI via owned external public AX; native fader/mute/monitor-only solo/Aux dispatch to exact Program0.35/Monitor0.15/Aux0.075/ISO0.3 PCM; saved first-buffer mute and real settings persistence; no dormant/stale ISO authority, saved track never starts a page, last-demand retirement removes controls and zeroes held ISO; restart restores saved mute. No physical capture or permission change.")
    }
}
