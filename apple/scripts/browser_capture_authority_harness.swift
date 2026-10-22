import AppKit
import CoreMedia
import AudioToolbox
import Foundation
import StreamCore

/// No SCK stream, WebAudio, output device or user media is opened here. Only
/// the external producer's async edges are held; the capture owner, PCM inlet,
/// mixer holdbacks and (in --ipc) real helper protocol remain production code.
@MainActor private final class Gate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor private final class Producer: BrowserWidgetAudioProducer {
    var starts = 0, stops = 0
    var active = false
    var startGate: Gate?, stopGate: Gate?
    var failsStart = false
    func start() async throws {
        starts += 1
        if let startGate { await startGate.wait() }
        if failsStart { throw CocoaError(.fileReadUnknown) }
        active = true
    }
    func stop() async {
        stops += 1; active = false
        if let stopGate { self.stopGate = nil; await stopGate.wait() }
    }
}

@main private struct BrowserCaptureAuthorityHarness {
    @MainActor static func until(_ label: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Deadline: \(label)")
    }
    @MainActor static func prepared(_ producer: Producer, pid: Int32) -> BrowserWidgetAudioCapture.PreparedCapture {
        .init(producer: producer, identity: .init(style: .application, helperPID: pid,
            bundleID: BrowserWidgetAudioIdentity.helperBundleID))
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let selected = CommandLine.arguments.dropFirst().first ?? "all"
        if selected == "late-preparation" || selected == "all" {
            let mixer = AudioMixEngine(), producer = Producer(), gate = Gate()
            let capture = BrowserWidgetAudioCapture(mixer: mixer, validationPreparation: { pid, _, _, _ in
                await gate.wait(); return prepared(producer, pid: pid)
            }, sink: { _ in preconditionFailure("No PCM generated in this resource case") })
            let pending = Task { try await capture.start(helperPID: 42) }
            try await until("held source discovery") { gate.entered }
            var stopCompleted = false
            let stopping = Task { await capture.stop(); stopCompleted = true }
            try await Task.sleep(for: .milliseconds(30))
            precondition(!stopCompleted, "Stop returned before pending discovery retired")
            gate.release(); await stopping.value
            let result = await pending.result
            let leases = await mixer.captureTimingSnapshot().leaseCount
            print("TRACE late preparation: starts=\(producer.starts), stops=\(producer.stops), capturing=\(capture.isCapturing), leases=\(leases), result=\(result)")
            precondition(producer.starts == 0 && !capture.isCapturing && leases == 0,
                "A capture start acquired resources after Stop")
            print("PASS stopped discovery cannot start a producer or reserve a holdback")
        }
        if selected == "replacement-token" || selected == "all" {
            let mixer = AudioMixEngine(), first = Producer(), second = Producer(), gate = Gate()
            let capture = BrowserWidgetAudioCapture(mixer: mixer, validationPreparation: { pid, _, _, _ in
                prepared(pid == 42 ? first : second, pid: pid)
            }, sink: { _ in preconditionFailure("No PCM generated in this resource case") })
            try await capture.start(helperPID: 42)
            first.stopGate = gate
            let oldStop = Task { await capture.stop() }
            try await until("old producer stop") { gate.entered }
            try await capture.start(helperPID: 43)
            let before = await mixer.captureTimingSnapshot().leaseCount
            gate.release(); await oldStop.value
            let after = await mixer.captureTimingSnapshot().leaseCount
            print("TRACE replacement token: beforeOldCleanup=\(before), after=\(after), Bactive=\(second.active), Bstops=\(second.stops), capturing=\(capture.isCapturing)")
            precondition(after == 1 && capture.isCapturing && second.active && second.stops == 0,
                "Old Stop released the replacement capture's holdback")
            await capture.stop(); let finalLeases = await mixer.captureTimingSnapshot().leaseCount; precondition(finalLeases == 0)
            print("PASS old cleanup owns only its stream and holdback")
        }
        if selected == "initial-retirement" || selected == "all" {
            let mixer = AudioMixEngine(), original = Producer(), first = Producer(), second = Producer(), gate = Gate()
            let capture = BrowserWidgetAudioCapture(mixer: mixer, validationPreparation: { pid, _, _, _ in
                prepared(pid == 41 ? original : (pid == 42 ? first : second), pid: pid)
            }, sink: { _ in preconditionFailure("No PCM generated in this resource case") })
            try await capture.start(helperPID: 41); original.stopGate = gate
            let older = Task { try await capture.start(helperPID: 42) }
            try await until("initial retirement") { gate.entered }
            try await capture.start(helperPID: 43)
            gate.release(); _ = await older.result
            let leases = await mixer.captureTimingSnapshot().leaseCount
            print("TRACE initial await: Astarts=\(first.starts), Bstops=\(second.stops), leases=\(leases)")
            precondition(first.starts == 0 && second.active && second.stops == 0 && leases == 1,
                "Start A regained authority after its initial awaited cleanup")
            await capture.stop()
            print("PASS start intent predates initial cleanup await")
        }
        for fail in [false, true] where selected == "all" || (selected == "held-start" && !fail) || (selected == "held-failure" && fail) {
            let mixer = AudioMixEngine(), first = Producer(), second = Producer(), gate = Gate()
            first.startGate = gate; first.failsStart = fail
            var failures = 0
            let capture = BrowserWidgetAudioCapture(mixer: mixer, validationPreparation: { pid, _, _, _ in
                prepared(pid == 42 ? first : second, pid: pid)
            }, sink: { _ in preconditionFailure("No PCM generated in this resource case") })
            capture.onFailure = { _ in failures += 1 }
            let older = Task { try await capture.start(helperPID: 42) }
            try await until("pending actual start completion") { gate.entered }
            var stopCompleted = false
            let stopping = Task { await capture.stop(); stopCompleted = true }
            try await until("pending producer stopped before start unwinds") { first.stops >= 1 }
            precondition(!stopCompleted, "Stop returned before pending producer start unwound")
            try await capture.start(helperPID: 43)
            gate.release(); await stopping.value; _ = await older.result
            let leases = await mixer.captureTimingSnapshot().leaseCount
            print("TRACE stale start fail=\(fail): Aactive=\(first.active), Astops=\(first.stops), Bactive=\(second.active), Bstops=\(second.stops), leases=\(leases)")
            precondition(!first.active && second.active && second.stops == 0 && capture.isCapturing && leases == 1 && capture.failure == nil && failures == 0,
                "A stale start completion/failure revived A or retired B")
            await capture.stop()
        }
        if selected == "pending-retirement" || selected == "all" {
            let mixer = AudioMixEngine(), first = Producer(), second = Producer(), gate = Gate()
            let capture = BrowserWidgetAudioCapture(mixer: mixer, validationPreparation: { pid, _, _, _ in
                prepared(pid == 42 ? first : second, pid: pid)
            }, sink: { _ in preconditionFailure("No PCM generated in this resource case") })
            try await capture.start(helperPID: 42); first.stopGate = gate
            let oldStop = Task { await capture.stop() }
            try await until("old asynchronous cleanup") { gate.entered }
            try await capture.start(helperPID: 43)
            var finalStopCompleted = false
            let finalStop = Task { await capture.stop(); finalStopCompleted = true }
            try await until("replacement producer retired") { second.stops > 0 }
            precondition(!finalStopCompleted, "Stop failed to wait prior owned cleanup")
            gate.release(); await oldStop.value; await finalStop.value
            let leases = await mixer.captureTimingSnapshot().leaseCount
            precondition(leases == 0 && !first.active && !second.active && !capture.isCapturing)
            print("PASS concurrent final Stop waits all previously detached run cleanup before returning")
        }
        if selected == "pcm-retirement" || selected == "all" {
            let mixer = AudioMixEngine(), first = Producer(), second = Producer(), gate = Gate()
            let receipts = PCMReceipts()
            var inputs: [(BrowserWidgetPCMInlet, UUID)] = []
            let capture = BrowserWidgetAudioCapture(mixer: mixer, validationPreparation: { pid, _, inlet, generation in
                inputs.append((inlet, generation)); return prepared(inputs.count == 1 ? first : second, pid: pid)
            }, sink: { receipts.append($0) })
            try await capture.start(helperPID: 42)
            inputs[0].0.post(try sentinel(1), generation: inputs[0].1)
            await inputs[0].0.waitUntilDrained()
            first.stopGate = gate
            let stopped = Task { await capture.stop() }
            try await until("held inlet retirement") { gate.entered }
            try await capture.start(helperPID: 43)
            inputs[0].0.post(try sentinel(2), generation: inputs[0].1)
            inputs[1].0.post(try sentinel(3), generation: inputs[1].1)
            await inputs[0].0.waitUntilDrained(); await inputs[1].0.waitUntilDrained()
            gate.release(); await stopped.value
            inputs[0].0.post(try sentinel(4), generation: inputs[0].1)
            inputs[1].0.post(try sentinel(5), generation: inputs[1].1)
            await inputs[0].0.waitUntilDrained(); await inputs[1].0.waitUntilDrained()
            precondition(receipts.values == [1, 3, 5])
            precondition(inputs[0].0.statistics().rejected == 2 && inputs[1].0.statistics().delivered == 2)
            await capture.stop()
            print("PASS exact retired callback generation rejects both late sentinels; replacement inlet survives old cleanup")
        }
        if selected == "ipc" {
            precondition(CommandLine.arguments.count == 3, "ipc requires the exact owned helper app path")
            try await ipc(helperURL: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
        precondition(!BrowserWidgetAudioIdentity.productionRouteQualified)
        print("PASS capture ownership qualification only; no WebKit/SCK audio attribution or product enablement claim")
    }
    /// Actual helper IPC/ACK/page lifetime, with only the SCK producer boundary held.
    @MainActor static func ipc(helperURL: URL) async throws {
        let mixer = AudioMixEngine(), gate = Gate(), first = Producer(), second = Producer()
        first.startGate = gate
        var producers = 0
        let capture = BrowserWidgetAudioCapture(mixer: mixer, validationPreparation: { pid, _, _, _ in
            precondition(pid > 0 && NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == BrowserWidgetAudioIdentity.helperBundleID)
            producers += 1; return prepared(producers == 1 ? first : second, pid: pid)
        }, sink: { _ in preconditionFailure("Silent IPC pages must not generate PCM") })
        let session = BrowserWidgetHelperSession(applicationURL: helperURL, mixer: mixer, validationAudioDriver: capture)
        session.prepareMixerForAudio = { [weak session] in
            guard let session else { return nil }
            let prepared = await mixer.prepareClosedApplicationMixer(session.channel, mixer: MixerSettings())
            return prepared ? .init(isCurrent: { true }) : nil
        }
        let a = BrowserWidgetPageLease(widgetID: UUID(), generation: UUID())
        let b = BrowserWidgetPageLease(widgetID: UUID(), generation: UUID())
        var loaded = Set<UUID>()
        func callbacks(_ id: UUID) -> BrowserWidgetHelperSession.Callbacks {
            .init(state: { if case .ready = $0 { loaded.insert(id) } }, frame: { _, _ in }, snapshotFailed: {})
        }
        for lease in [a, b] {
            try await session.loadForQualification(id: lease.widgetID, generation: lease.generation,
                html: "<html><body><script>window.ownedCaptureLifecycle = 'alive'</script>Silent owned lifecycle page</body></html>",
                options: .init(width: 64, height: 64, hidden: true), callbacks: callbacks(lease.widgetID))
        }
        try await until("both real helper pages loaded") { loaded.count == 2 }
        guard let pid = session.helperPID else { preconditionFailure("Missing owned helper PID") }
        print("TRACE owned helper PID=\(pid), app=\(helperURL.path)")
        session.setProgramAudioDemand([a, b], applyingExclusions: session.requiredSystemAudioExclusions)
        try await until("real session held in actual capture start") { gate.entered }
        session.release(a.widgetID)
        precondition(session.audibleLeases.isEmpty)
        gate.release()
        try await until("sibling resumes after actual retired-page ACK") { session.audibleLeases == [b] }
        let retiredDOM = await session.evaluate(id: a.widgetID, generation: a.generation, expression: "window.ownedCaptureLifecycle")
        let siblingDOM = await session.evaluate(id: b.widgetID, generation: b.generation, expression: "window.ownedCaptureLifecycle")
        precondition(retiredDOM == nil && siblingDOM == "alive")
        let leases = await mixer.captureTimingSnapshot().leaseCount
        precondition(producers == 2 && !first.active && first.stops >= 1 && second.active && leases == 1)
        session.release(b.widgetID)
        await session.waitUntilStopped()
        let finalLeases = await mixer.captureTimingSnapshot().leaseCount
        precondition(finalLeases == 0 && session.audibleLeases.isEmpty && !capture.isCapturing && !second.active)
        try await until("owned helper process exit") { NSRunningApplication(processIdentifier: pid)?.isTerminated != false }
        print("PASS real exact-PID helper IPC, suspended load/retirement ACK, sibling DOM lifetime, final helper exit and exact mixer lease cleanup")
        print("IPC qualification is unsandboxed prototype only; no signed shared-container provenance or real WebKit audio attribution claimed")
    }

}


private final class PCMReceipts: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [Int] = []
    var values: [Int] { lock.withLock { received } }
    func append(_ sample: CMSampleBuffer) { lock.withLock { received.append(Int(sample.presentationTimeStamp.seconds)) } }
}
/// Controlled external-callback sentinel, not a WebKit audio source.
private func sentinel(_ marker: Int64) throws -> CMSampleBuffer {
    let frames = 512
    let values = [Float](repeating: 0.125, count: frames * 2)
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: values.count * 4, blockAllocator: nil,
        customBlockSource: nil, offsetToData: 0, dataLength: values.count * 4, flags: 0, blockBufferOut: &block) == noErr else { throw CocoaError(.fileWriteUnknown) }
    _ = values.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: $0.count) }
    var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
        mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: CMTime(value: marker, timescale: 1), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?, size = 8
    guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { throw CocoaError(.fileWriteUnknown) }
    return sample!
}
