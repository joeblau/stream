import AppKit
import AVFoundation
import CoreMedia
import StreamCore

@MainActor enum BrowserLifecycleCaptureReceipts {
    static var screenPrivacy: [EffectiveCapturePrivacy] = []
    static var appExclusions: [Set<String>] = []
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
    }
    func releaseStart() { startContinuation?.resume(); startContinuation = nil }
    func invalidateInput() { inlet.invalidate() }
    func stop() async { isCapturing = false; stops += 1; await inlet.stop() }
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
    static func main() async throws {
        setbuf(stdout, nil); signal(SIGPIPE, SIG_IGN)
        guard CGSessionCopyCurrentDictionary() != nil else { print("UNQUALIFIED: owned helper IPC needs WindowServer"); exit(77) }
        NSApplication.shared.setActivationPolicy(.accessory)
        precondition(!BrowserWidgetAudioIdentity.productionRouteQualified)
        let application = URL(fileURLWithPath: CommandLine.arguments[1])
        try await queuedISOChecks()
        try await canceledLoadChecks(application)
        try await sessionChecks(application)
        try await controllerChecks(application)
        print("PASS: actual helper IPC/Program leases + controller capture demand + native mixer retirement. Captured PCM is synthetic; no SCK capture, audible page, permission request, signing/install operation or production activation.")
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
        try await Task.sleep(for: .milliseconds(180))
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
}
