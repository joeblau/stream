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
private func sample() -> CMSampleBuffer {
    var pixels: CVPixelBuffer?
    require(CVPixelBufferCreate(nil, 64, 36, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels) == kCVReturnSuccess, "Owned pixels")
    let image = pixels!
    CVPixelBufferLockBaseAddress(image, [])
    let bytes = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<36 { for x in 0..<64 {
        let offset = y * CVPixelBufferGetBytesPerRow(image) + x * 4
        bytes[offset] = 0; bytes[offset + 1] = 180; bytes[offset + 2] = 0; bytes[offset + 3] = 255
    }}
    CVPixelBufferUnlockBaseAddress(image, [])
    var format: CMVideoFormatDescription?, result: CMSampleBuffer?
    require(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format) == noErr, "Owned video format")
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
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
        let hold = EncodeHold(), encoder = NativeGuestReturnVideoEncoder()
        encoder.validationBeforeCompletion = hold.wait
        let sender = NativeGuestReturnVideoSender(sink: sink, receiver: receiver, callbacks: callbacks, encoder: encoder, events: { _ in true })
        sink.bindVideoRetirement { [weak sender] in sender?.stop() }
        require(await sender.prepare(), "Actual owned source installed")
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
        let first = Task { await nextSender.prepare() }
        require(await Task.detached { wait(nextSource.entered, seconds: 3) }.value, "Held first source install")
        let oldToken = nextSource.tokens[0]
        nextSender.stop()
        require(nextSink.selectReturnVideoSource(.secondary), "Select a distinct source while old installation held")
        require(await nextSender.prepare(), "Fresh explicit enable while old installation held")
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
        let beforeInstall = Task { await nextSender.prepare() }
        require(await Task.detached { wait(entry.entered, seconds: 3) }.value, "Held before source install entry")
        require(nextSource.tokens.isEmpty && secondarySource.tokens.isEmpty, "No source reservation before install entry")
        nextSender.stop()
        require(nextSink.selectReturnVideoSource(.program), "Replacement source selected during old pre-install suspension")
        require(await nextSender.prepare(), "Replacement can claim during old pre-install suspension")
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
    }
}
