import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import StreamCore

// Opaque scene identities only; mixer/sink/codec/sender are shipping sources.
struct CaptureSourceKey: Hashable, Sendable { let id: UUID }
struct SourceDefinitionID: Hashable, Sendable, CustomStringConvertible {
    let id: UUID
    var description: String { id.uuidString }
}

private func require(_ value: Bool, _ message: String) { precondition(value, message) }
private func wait(_ semaphore: DispatchSemaphore, seconds: Double) -> Bool { semaphore.wait(timeout: .now() + seconds) == .success }
private final class VideoSource: @unchecked Sendable {
    private let lock = NSLock()
    private var consumers: [UUID: NativeGuestProgramReturnSource.Consumer] = [:]
    private var held = false
    let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
    func holdNext() { lock.lock(); held = true; lock.unlock() }
    func install(_ token: UUID, _ consume: @escaping NativeGuestProgramReturnSource.Consumer) async -> Bool {
        let pause = register(token, consume)
        if pause {
            entered.signal()
            require(await Task.detached { wait(self.resume, seconds: 5) }.value, "Held installation resumed")
        }
        return true
    }
    private func register(_ token: UUID, _ consume: @escaping NativeGuestProgramReturnSource.Consumer) -> Bool {
        lock.lock(); defer { lock.unlock() }; consumers[token] = consume; let pause = held; held = false; return pause
    }
    func remove(_ token: UUID) { lock.lock(); consumers[token] = nil; lock.unlock() }
    var tokens: [UUID] { lock.lock(); defer { lock.unlock() }; return Array(consumers.keys) }
    func emit(_ sample: CMSampleBuffer) {
        lock.lock(); let copies = Array(consumers.values); lock.unlock()
        for consume in copies { consume(sample) }
    }
}
private final class EncodeHold: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
    func wait() { entered.signal(); require(resume.wait(timeout: .now() + 5) == .success, "Actual VT submission resumed") }
}
private final class InstallEntryHold: @unchecked Sendable {
    private let lock = NSLock()
    private var first = true
    let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
    private func takeFirst() -> Bool { lock.lock(); defer { lock.unlock() }; let value = first; first = false; return value }
    func pause() async {
        guard takeFirst() else { return }
        entered.signal()
        require(await Task.detached { wait(self.resume, seconds: 5) }.value, "Pre-install suspension resumed")
    }
}
private func sample(width: Int = 64, height: Int = 36, pts: CMTime? = nil) -> CMSampleBuffer {
    var pixels: CVPixelBuffer?
    require(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels) == kCVReturnSuccess, "Owned pixels")
    let image = pixels!
    CVPixelBufferLockBaseAddress(image, [])
    let bytes = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height { for x in 0..<width {
        let offset = y * CVPixelBufferGetBytesPerRow(image) + x * 4
        bytes[offset] = 0; bytes[offset + 1] = 180; bytes[offset + 2] = 0; bytes[offset + 3] = 255
    }}
    CVPixelBufferUnlockBaseAddress(image, [])
    var format: CMVideoFormatDescription?, result: CMSampleBuffer?
    require(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format) == noErr, "Owned video format")
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts ?? CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
    require(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &result) == noErr, "Owned video sample")
    return result!
}

@main struct ReturnVideoLifecycleHarness {
    @MainActor static func main() async throws {
        let lease = GuestReceiveLease(slot: UUID(), peerID: UUID(), negotiation: UUID(), generation: 1)
        let audio = AudioMixEngine(), video = GuestVideoFrameStore()
        require(await audio.registerGuest(lease), "Actual mixer lease")
        require(video.register(lease), "Actual video lease")
        let sink = NativeGuestMediaSink(registered: lease, video: video, audio: audio)
        let authority = NativeGuestProgramReturnAuthority(), source = VideoSource()
        authority.change(active: true)
        sink.bindProgramReturn(.init(authority: authority, install: source.install, remove: { source.remove($0) }))
        let callbacks = NativeInterviewReceiverEvents(sink: sink, media: try .init(audio: "audio", camera: "camera", screen: "screen"), events: { _ in true })
        callbacks.validationReturnReady = true // Only the readiness seam is controlled; the actual VT encoder and sink remain real.
        let receiver = try NativeGuestReceiver(admitted: lease, cameraMID: "camera", screenMID: "screen", audioMID: "audio", video: { _ in }, audio: { _ in }, signal: { _, _, _ in })
        let reconfigured = NativeGuestReturnVideoEncoder()
        reconfigured.setProfile(.high)
        let highFrame = sample(width: 640, height: 360)
        let highEncoded = try reconfigured.encode(.init(lease: lease, token: UUID(), sample: highFrame))
        require(highEncoded != nil && reconfigured.validationSessionActive
            && reconfigured.validationDimensions == (640, 360), "Actual high-target VT session never upscales its source")
        require(highEncoded!.rtp == UInt32(truncatingIfNeeded: CMTimeConvertScale(highFrame.presentationTimeStamp,
            timescale: 90_000, method: .roundHalfAwayFromZero).value), "High profile keeps original source RTP PTS")
        reconfigured.setProfile(.low)
        require(!reconfigured.validationSessionActive, "Actual old VT session invalidated before lower replacement")
        let lowFrame = sample(width: 640, height: 360, pts: highFrame.presentationTimeStamp + CMTime(value: 1, timescale: 30))
        let lowEncoded = try reconfigured.encode(.init(lease: lease, token: UUID(), sample: lowFrame))
        require(lowEncoded != nil && reconfigured.validationSessionActive && reconfigured.validationDimensions == (320, 180),
            "Actual lower VT replacement enforces320x180 without simultaneous sessions")
        require(lowEncoded!.rtp == UInt32(truncatingIfNeeded: CMTimeConvertScale(lowFrame.presentationTimeStamp,
            timescale: 90_000, method: .roundHalfAwayFromZero).value), "Profile replacement never rebases source RTP PTS")
        reconfigured.close()
        print("PASS actual VT high→low replacement: old session invalidated before new allocation, source dimensions never upscaled and original90kPTS preserved")
        let hold = EncodeHold(), encoder = NativeGuestReturnVideoEncoder()
        encoder.validationBeforeCompletion = hold.wait
        let sender = NativeGuestReturnVideoSender(sink: sink, receiver: receiver, callbacks: callbacks, encoder: encoder, events: { _ in true })
        sink.bindVideoRetirement { [weak sender] in sender?.stop() }
        let initialClaim = sender.claimPreparation()!
        require(await sender.prepare(initialClaim), "Actual owned source installed")
        let token = source.tokens[0], original = sample()
        source.emit(original)
        require(await Task.detached { wait(hold.entered, seconds: 5) }.value, "Real VT frame submitted and held before completion")
        require(encoder.validationSessionActive, "Actual VT session exists during hold")
        let began = ContinuousClock.now
        sender.stop()
        let elapsed = began.duration(to: .now)
        require(elapsed < .milliseconds(100), "Off must not wait on a held codec drain")
        require(!sink.sendReturnVideoIfCurrent(.init(lease: lease, token: token, sample: original)) { true }, "Off synchronously fences an already submitted frame")
        sink.close()
        require(source.tokens == [token] && encoder.validationSessionActive, "Sink close retains reservation until actual codec teardown")
        hold.resume.signal()
        for _ in 0..<200 {
            if source.tokens.isEmpty { break }; try await Task.sleep(for: .milliseconds(10))
        }
        require(source.tokens.isEmpty && !encoder.validationSessionActive, "Actual VT invalidation precedes reservation removal")
        receiver.stop()
        print("PASS: actual VT submission held; Off returns under100ms and fences late send; sink close retains reservation until actual VT invalidation")

        let replacement = GuestReceiveLease(slot: lease.slot, peerID: UUID(), negotiation: UUID(), generation: 2)
        require(await audio.registerGuest(replacement) && video.register(replacement), "Replacement lease")
        let nextSink = NativeGuestMediaSink(registered: replacement, video: video, audio: audio), nextSource = VideoSource(), secondarySource = VideoSource()
        nextSink.bindProgramReturn(.init(authority: authority, install: nextSource.install, remove: { nextSource.remove($0) }))
        nextSink.bindSecondaryReturn(.init(authority: authority, install: secondarySource.install, remove: { secondarySource.remove($0) }))
        let nextCallbacks = NativeInterviewReceiverEvents(sink: nextSink, media: try .init(audio: "audio", camera: "camera", screen: "screen"), events: { _ in true })
        let nextReceiver = try NativeGuestReceiver(admitted: replacement, cameraMID: "camera", screenMID: "screen", audioMID: "audio", video: { _ in }, audio: { _ in }, signal: { _, _, _ in })
        let nextSender = NativeGuestReturnVideoSender(sink: nextSink, receiver: nextReceiver, callbacks: nextCallbacks, events: { _ in true })
        nextSink.bindVideoRetirement { [weak nextSender] in nextSender?.stop() }
        nextSource.holdNext()
        let firstClaim = nextSender.claimPreparation()!
        let first = Task { await nextSender.prepare(firstClaim) }
        require(await Task.detached { wait(nextSource.entered, seconds: 3) }.value, "Held first source install")
        let oldToken = nextSource.tokens[0]
        nextSender.stop()
        require(nextSink.selectReturnVideoSource(.secondary), "Select a distinct source while old installation held")
        let secondaryClaim = nextSender.claimPreparation()!
        require(await nextSender.prepare(secondaryClaim), "Fresh explicit enable while old installation held")
        let current = secondarySource.tokens[0]
        nextSource.resume.signal()
        require(await first.value == false, "Late old installation rejected")
        for _ in 0..<100 {
            if nextSource.tokens.isEmpty { break }; try await Task.sleep(for: .milliseconds(10))
        }
        require(nextSender.isEnabled && nextSource.tokens.isEmpty && secondarySource.tokens == [current], "Old failure cannot stop the replacement or release its reservation")
        require(nextSink.sendReturnVideoIfCurrent(.init(lease: replacement, token: current, sample: sample())) { true }, "Fresh token retains outbound authority")
        require(!nextSink.sendReturnVideoIfCurrent(.init(lease: lease, token: oldToken, sample: original)) { true }, "Old full lease/token cannot send")
        print("PASS: held Program installA→Off→Secondary installB→lateA failure preserves B token/reservation and rejects old full-lease sends")
        nextSender.stop()
        for _ in 0..<100 { if nextSource.tokens.isEmpty && secondarySource.tokens.isEmpty { break }; try await Task.sleep(for: .milliseconds(10)) }
        let entry = InstallEntryHold()
        nextSender.validationBeforeInstall = entry.pause
        let beforeClaim = nextSender.claimPreparation()!
        let beforeInstall = Task { await nextSender.prepare(beforeClaim) }
        require(await Task.detached { wait(entry.entered, seconds: 3) }.value, "Held before source install entry")
        require(nextSource.tokens.isEmpty && secondarySource.tokens.isEmpty, "No source reservation before install entry")
        nextSender.stop()
        require(nextSink.selectReturnVideoSource(.program), "Replacement source selected during old pre-install suspension")
        let replacementClaim = nextSender.claimPreparation()!
        require(await nextSender.prepare(replacementClaim), "Replacement can claim during old pre-install suspension")
        let replacementToken = nextSource.tokens[0]
        entry.resume.signal()
        require(await beforeInstall.value == false, "Old canceled token cannot begin late source installation")
        try await Task.sleep(for: .milliseconds(100))
        require(nextSender.isEnabled && nextSource.tokens == [replacementToken] && secondarySource.tokens.isEmpty, "Late entry neither leaks a reservation nor retires replacement")
        nextCallbacks.receive("control-closed", "", "")
        for _ in 0..<100 { if nextSource.tokens.isEmpty { break }; try await Task.sleep(for: .milliseconds(10)) }
        require(!nextSender.isEnabled && nextSource.tokens.isEmpty, "Control close retires return subscription and reservation")
        nextSink.close(); nextReceiver.stop()
        print("PASS: held before-Secondary-installA→Off→Program-installB→lateA cannot allocate or retire B; control close releases the active return")

        let hostLease = GuestReceiveLease(slot: lease.slot, peerID: UUID(), negotiation: UUID(), generation: 3)
        require(await audio.registerGuest(hostLease) && video.register(hostLease), "Actual host lifecycle lease")
        let hostSink = NativeGuestMediaSink(registered: hostLease, video: video, audio: audio)
        let hostProgram = VideoSource(), hostSecondary = VideoSource()
        hostSink.bindProgramReturn(.init(authority: authority, install: hostProgram.install, remove: { hostProgram.remove($0) }))
        hostSink.bindSecondaryReturn(.init(authority: authority, install: hostSecondary.install, remove: { hostSecondary.remove($0) }))
        let context = NativeInterviewPeerLease(room: UUID(), hostGeneration: UUID(), guestGeneration: UUID(), receive: hostLease)
        let relay = NativeInterviewRelayConfiguration(servers: [.init(urls: ["turn:127.0.0.1:3478?transport=udp"], username: "owned-fixture-user", credential: try .init("owned-fixture-credential"))],
            expires: Date().addingTimeInterval(30), refreshAt: Date().addingTimeInterval(24))
        let host = try NativeInterviewReceiverAdapter(context: context, relay: relay, sink: hostSink, events: { _ in true })
        host.validationPermitReturn()
        require(host.setProgramReturnEnabled(true), "Actual host accepts deliberate Start")
        // No actor yield: the host's preparation task has not entered at all.
        hostSink.stopProgramReturn(); authority.change(active: false); authority.change(active: true)
        try await Task.sleep(for: .milliseconds(100))
        require(!host.validationVideoEnabled && hostProgram.tokens.isEmpty && host.validationPendingVideoPreparations == 0,
            "Start→synchronous privacy stop→restore before first task turn cannot replay old Start")
        hostProgram.holdNext()
        require(host.setProgramReturnEnabled(true), "Fresh explicit Start after privacy")
        require(await Task.detached { wait(hostProgram.entered, seconds: 3) }.value, "Actual host installA entered and held")
        let heldToken = hostProgram.tokens[0]
        hostSink.stopProgramReturn() // The controller privacy/pipeline/source-loss hook, not Host Off.
        require(host.selectReturnVideoSource(.secondary), "Actual host selects replacement source while old install held")
        require(host.setProgramReturnEnabled(true), "Deliberate replacement Start cannot be blocked by retired old install")
        for _ in 0..<100 { if hostSecondary.tokens.count == 1 && host.validationPendingVideoPreparations == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
        require(hostSecondary.tokens.count == 1 && host.validationVideoEnabled, "Actual host replacementB installed while A held")
        let hostCurrent = hostSecondary.tokens[0]
        hostProgram.resume.signal()
        for _ in 0..<100 { if hostProgram.tokens.isEmpty && host.validationPendingVideoPreparations == 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
        require(hostProgram.tokens.isEmpty && hostSecondary.tokens == [hostCurrent] && host.validationVideoEnabled,
            "Actual host stale completion cannot stop replacement or retain old source")
        require(!hostSink.sendReturnVideoIfCurrent(.init(lease: hostLease, token: heldToken, sample: sample())) { true }, "Old actual-host source token fenced")
        require(hostSink.sendReturnVideoIfCurrent(.init(lease: hostLease, token: hostCurrent, sample: sample())) { true }, "Replacement actual-host token remains current")
        require(host.setProgramReturnEnabled(false), "Actual host Off")
        for _ in 0..<100 { if hostSecondary.tokens.isEmpty { break }; try await Task.sleep(for: .milliseconds(10)) }
        require(host.setProgramReturnEnabled(true), "Queued StartA")
        require(host.setProgramReturnEnabled(false), "Off before queued StartA enters")
        require(host.setProgramReturnEnabled(true), "Explicit StartB before canceled StartA completion")
        try await Task.sleep(for: .milliseconds(100))
        require(host.validationVideoEnabled && hostSecondary.tokens.count == 1 && host.validationPendingVideoPreparations == 0,
            "No-yield explicit Off/On preserves only B and bounds pending jobs")
        host.retire()
        for _ in 0..<100 { if hostSecondary.tokens.isEmpty { break }; try await Task.sleep(for: .milliseconds(10)) }
        require(hostSecondary.tokens.isEmpty, "Actual host retirement releases replacement source")
        print("PASS actual host: no-yield Start→privacyStop→restore cannot replay; held ProgramA→controllerStop→explicit SecondaryB→lateA preserves B; no-yield Off/On preserves B with bounded preparation jobs")

    }
}
