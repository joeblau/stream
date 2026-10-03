import AVFoundation
import CoreMedia
import Foundation
import StreamCore

// Only opaque scene/capture identities are substituted. The receiver, leased
// sink, bounded frame store, mixer registry and factory are shipping sources.
struct CaptureSourceKey: Hashable, Sendable { let id: UUID }
struct SourceDefinitionID: Hashable, Sendable, CustomStringConvertible {
    let id: UUID
    var description: String { id.uuidString }
}
private final class ReceiverEventProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [NativeInterviewMediaEvent] = []
    func receive(_ event: NativeInterviewMediaEvent) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard values.count < 32 else { return false }; values.append(event); return true
    }
    var offered: Bool { lock.lock(); defer { lock.unlock() }; return values.contains { if case .offer = $0 { return true }; return false } }
    var ready: Bool { lock.lock(); defer { lock.unlock() }; return values.contains { if case .ready = $0 { return true }; return false } }
}
private final class ReceiverFixtureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    var isEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock(); entered = true; self.continuation = continuation; lock.unlock()
        }
    }
    func release() { lock.lock(); let held = continuation; continuation = nil; lock.unlock(); held?.resume() }
}
private final class ReceiverHeldVideo: @unchecked Sendable {
    private let lock = NSLock()
    private let released = DispatchSemaphore(value: 0)
    private var entered = false, timedOut = false
    var isEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    var expired: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
    func hold(_ frame: GuestVideoFrame) {
        lock.lock(); entered = true; lock.unlock()
        let result = released.wait(timeout: .now() + 2)
        lock.lock(); timedOut = result == .timedOut; lock.unlock()
    }
    func release() { released.signal() }
}
private final class ReceiverHeldControlSend: @unchecked Sendable {
    private let lock = NSLock(), released = DispatchSemaphore(value: 0)
    private var entered = false, timedOut = false
    var isEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    var expired: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
    func send(_ message: String) -> Bool {
        lock.lock(); entered = true; lock.unlock()
        let result = released.wait(timeout: .now() + 2)
        lock.lock(); timedOut = result == .timedOut; lock.unlock()
        return result == .success
    }
    func release() { released.signal() }
}

@main @MainActor private enum NativeInterviewReceiverHarness {
    static func log(_ value: String) { FileHandle.standardOutput.write(Data((value + "\n").utf8)) }
    static func lease(slot: UUID = UUID(), generation: UInt64 = 1) -> GuestReceiveLease {
        .init(slot: slot, peerID: UUID(), negotiation: UUID(), generation: generation)
    }
    static func context(_ lease: GuestReceiveLease) -> NativeInterviewPeerLease {
        .init(room: UUID(), hostGeneration: UUID(), guestGeneration: UUID(), receive: lease)
    }
    static func pcm() -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000, channels: 2, interleaved: false)!, frameCapacity: 480)!
        buffer.frameLength = 480
        for side in 0..<2 { for index in 0..<480 { buffer.floatChannelData![side][index] = 0.25 } }
        return buffer
    }
    static func picture(_ lease: GuestReceiveLease, mapping: UUID, role: GuestReceiveRole = .camera) -> GuestVideoFrame {
        var pixels: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &pixels) == kCVReturnSuccess)
        return .init(lease: lease, role: role, pixels: pixels!,
                     pts: CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(value: 4_800, timescale: 48_000),
                     duration: .invalid, mappingGeneration: mapping, clockQuality: .senderReportAligned)
    }
    static func sound(_ lease: GuestReceiveLease, mapping: UUID) -> GuestAudioFrame {
        .init(lease: lease, pcm: pcm(),
              pts: CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(value: 4_800, timescale: 48_000),
              duration: CMTime(value: 480, timescale: 48_000), mappingGeneration: mapping, clockQuality: .senderReportAligned)
    }
    static func relay(url: String = "turn:127.0.0.1:3478?transport=udp", lifetime: Double = 30) throws -> NativeInterviewRelayConfiguration {
        .init(servers: [.init(urls: [url], username: "owned-fixture-user",
                             credential: try .init("owned-fixture-credential"))],
              expires: Date().addingTimeInterval(lifetime), refreshAt: Date().addingTimeInterval(lifetime * 0.8))
    }
    static func register(_ lease: GuestReceiveLease, store: GuestVideoFrameStore,
                         audio: AudioMixEngine) async throws -> NativeGuestMediaSink {
        let registered = await audio.registerGuest(lease)
        guard registered, store.register(lease) else { throw NativeInterviewError.changed }
        return .init(registered: lease, video: store, audio: audio)
    }
    static func wait(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !ready() { guard ContinuousClock.now < deadline else { throw NativeInterviewError.timeout }; try await Task.sleep(for: .milliseconds(5)) }
    }
    static func main() async throws {
        try await receiverControlCompletion()
        try await eventControlCompletion()
        try await sinkBoundaries()
        try await screenControlOrdering()
        try await factoryAndSDK()
        log("PASS: actual production SDK relay constructor and leased native sink/factory; no TURN availability, remote media or application entrypoint qualification")
    }
    static func receiverControlCompletion() async throws {
        for boundary in ["control-close", "revoke", "stop"] {
            let receiver = try NativeGuestReceiver(admitted: lease(), cameraMID: "camera-mid", screenMID: "screen-mid", audioMID: "audio-mid",
                video: { _ in }, audio: { _ in }, signal: { _, _, _ in })
            defer { receiver.stop() }
            let held = ReceiverHeldControlSend()
            let grant = Task.detached { receiver.validationApproveScreen(true, send: held.send) }
            try await wait { held.isEntered }
            switch boundary {
            case "control-close": receiver.validationControlClosed()
            case "revoke": _ = receiver.validationApproveScreen(false, send: { _ in true })
            default: receiver.stop()
            }
            held.release()
            let accepted = await grant.value
            log("Held screen grant completed after actual \(boundary): accepted=\(accepted), approved=\(receiver.validationScreenApproved)")
            precondition(!held.expired && !accepted && !receiver.validationScreenApproved,
                         "Old successful control send cannot restore a closed, revoked or stopped grant")
        }
        log("PASS: actual receiver held control-send completion cannot reopen screen after control-close/revoke/stop")
    }
    static func eventControlCompletion() async throws {
        for boundary in ["control-close", "revoke", "stop"] {
            let store = GuestVideoFrameStore(), audio = AudioMixEngine(), current = lease(), mapping = UUID()
            let sink = try await register(current, store: store, audio: audio)
            let events = NativeInterviewReceiverEvents(sink: sink,
                media: try .init(audio: "audio-mid", camera: "camera-mid", screen: "screen-mid"), events: { _ in true })
            let heldIntent = events.beginApproval(true)!
            switch boundary {
            case "control-close": events.receive("control-closed", "", "")
            case "revoke": events.setApproved(false)
            default: events.close()
            }
            precondition(!events.finishApproval(true, intent: heldIntent), "An old send completion cannot restore Events approval")
            events.receive("control", "{\"type\":\"screen-state\",\"sharing\":true}", "")
            precondition(!sink.receive(picture(current, mapping: mapping, role: .screen)))
            if boundary != "stop" {
                precondition(sink.receive(picture(current, mapping: mapping)), "Screen closure preserves the healthy camera lease")
                precondition(audio.registeredGuestChannelID(slot: current.slot) != nil)
            }
            events.close(); sink.close(); await audio.stop()
        }
        log("PASS: actual Events held approval intent rejects control-close/revoke/stop before sink grant; camera/audio lease stays intact on screen revocation")
    }
    static func screenControlOrdering() async throws {
        let store = GuestVideoFrameStore(), audio = AudioMixEngine(), current = lease(), mapping = UUID()
        await audio.run()
        let registered = await audio.registerGuest(current)
        precondition(registered)
        precondition(store.register(current))
        let held = ReceiverHeldVideo(), probe = ReceiverEventProbe()
        let sink = NativeGuestMediaSink(registered: current, video: store, audio: audio, acceptedVideo: held.hold)
        let events = NativeInterviewReceiverEvents(sink: sink,
            media: try .init(audio: "audio-mid", camera: "camera-mid", screen: "screen-mid"), events: probe.receive)
        events.setApproved(true)
        let frame = picture(current, mapping: mapping)
        let video = Task.detached { sink.receive(frame) }
        try await wait { held.isEntered }
        let sharing = "{\"type\":\"screen-state\",\"sharing\":true}"
        let delayed = Task.detached { events.receive("control", sharing, "") }
        // Hold the REAL sink gate while both control paths contend. MainActor
        // remains free; revocation must finish any earlier mutation before it
        // returns, independent of which background contender acquired first.
        try await Task.sleep(for: .milliseconds(20))
        let revoke = Task.detached { events.setApproved(false) }
        try await Task.sleep(for: .milliseconds(20))
        held.release()
        let accepted = await video.value
        precondition(accepted && !held.expired)
        await delayed.value; await revoke.value
        precondition(!sink.receive(picture(current, mapping: mapping, role: .screen)),
                     "A sharing callback cannot re-enable a synchronously revoked sink")
        events.receive("control", sharing, "")
        precondition(!sink.receive(picture(current, mapping: mapping, role: .screen)),
                     "Late sharing reads current approval")
        events.setApproved(true)
        events.receive("control-closed", "", "")
        events.receive("control", sharing, "")
        precondition(!sink.receive(picture(current, mapping: mapping, role: .screen)),
                     "Control close permanently revokes this SDK channel's grant")
        events.close()
        precondition(!sink.receive(frame) && audio.registeredGuestChannelID(slot: current.slot) == nil)
        await audio.stop()
        log("PASS: actual held leased sink + sharing/approval contenders serialize revocation; late sharing/control-close cannot reopen screen; close retires media")
    }
    static func sinkBoundaries() async throws {
        let store = GuestVideoFrameStore(), audio = AudioMixEngine(), first = lease(), mapping = UUID()
        let unregistered = NativeGuestMediaSink(registered: first, video: store, audio: audio)
        precondition(!unregistered.receive(picture(first, mapping: mapping))
                     && !unregistered.receive(sound(first, mapping: mapping)))
        precondition(audio.registeredGuestChannelID(slot: first.slot) == nil && store.statistics().retainedFrames == 0)
        unregistered.close()
        await audio.run()
        let sink = try await register(first, store: store, audio: audio)
        let frame = picture(first, mapping: mapping)
        precondition(sink.receive(frame))
        precondition(store.pixels(slot: first.slot, role: .camera, at: frame.pts, program: false) != nil)
        precondition(store.pixels(slot: first.slot, role: .camera, at: frame.pts, program: true) == nil)
        let packet = sound(first, mapping: mapping)
        precondition(sink.receive(packet))
        precondition(CMTimeCompare(audio.guestAdmissionSnapshot().lastPTS, packet.pts) == 0)
        precondition(!sink.receive(sound(first, mapping: UUID())), "An audio mapping cannot disagree with its video clock")
        precondition(!sink.receive(picture(first, mapping: mapping, role: .screen)))
        sink.enableScreen(true)
        precondition(sink.receive(picture(first, mapping: mapping, role: .screen)))
        sink.enableScreen(false)
        precondition(store.pixels(slot: first.slot, role: .screen, at: packet.pts + CMTime(value: 1, timescale: 48_000), program: false) == nil)
        let next = lease(slot: first.slot, generation: 2)
        let replacement = try await register(next, store: store, audio: audio)
        sink.close()
        precondition(audio.registeredGuestChannelID(slot: next.slot) != nil)
        precondition(!sink.receive(frame), "Closed callbacks cannot re-enter a replacement")
        precondition(replacement.receive(picture(next, mapping: UUID())))
        replacement.close()
        precondition(store.statistics().retainedFrames == 0 && audio.registeredGuestChannelID(slot: next.slot) == nil)
        await audio.stop()
        log("PASS: actual sink rejects unregistered and foreign-clock receipts; original PTS, independent screen revoke, replacement and synchronous close")
    }
    static func factoryAndSDK() async throws {
        let store = GuestVideoFrameStore(), audio = AudioMixEngine(), first = lease()
        await audio.run()
        let factory = NativeInterviewReceiverFactory { context in
            try await register(context.receive, store: store, audio: audio)
        }
        let probe = ReceiverEventProbe()
        let host = try await factory.makeHost(context: context(first), relay: relay(), events: probe.receive)
        do { _ = try await factory.makeHost(context: context(first), relay: relay(), events: probe.receive); preconditionFailure("Native capacity is one") }
        catch NativeInterviewError.capacity {}
        try host.startHost()
        try await wait { probe.offered }
        precondition(!probe.ready, "A relay with no answering peer cannot report actual media ready")
        do { try host.acceptCandidate("invalid-candidate", mid: "camera-mid"); preconditionFailure("Invalid candidate must fail independently") }
        catch NativeInterviewError.transport {}
        precondition((host as? NativeInterviewReceiverAdapter)?.isRetired == false,
                     "An unusable trickled candidate cannot retire the valid offer")
        host.retire()
        precondition(audio.registeredGuestChannelID(slot: first.slot) == nil)
        do { try host.startHost(); preconditionFailure("Retired native peer cannot restart") }
        catch NativeInterviewError.closed {}
        let next = lease(slot: first.slot, generation: 2)
        do { _ = try await factory.makeHost(context: context(next), relay: relay(url: "turn:127.0.0.1:65536"), events: probe.receive); preconditionFailure("Invalid relay port must be rejected by actual SDK boundary") }
        catch NativeInterviewError.unavailable {}
        precondition(audio.registeredGuestChannelID(slot: next.slot) == nil)
        for (index, url) in ["turn:127.0.0.1:3478?transport=tcp", "turns:127.0.0.1:5349?transport=tcp"].enumerated() {
            let unsupported = lease(slot: first.slot, generation: UInt64(index + 3))
            do {
                _ = try await factory.makeHost(context: context(unsupported), relay: relay(url: url), events: probe.receive)
                preconditionFailure("Only unsupported TURN TCP/TLS cannot claim usable native relay capability")
            } catch NativeInterviewError.unavailable {}
            precondition(audio.registeredGuestChannelID(slot: unsupported.slot) == nil)
        }
        // The failed construction has consumed its explicitly registered
        // generation. A fresh attempt must receive a fresh runtime lease.
        let third = lease(slot: first.slot, generation: 5)
        let mixed = NativeInterviewRelayConfiguration(servers: [try relay(url: "turns:127.0.0.1:5349?transport=tcp").servers[0],
            try relay().servers[0]], expires: Date().addingTimeInterval(30), refreshAt: Date().addingTimeInterval(24))
        let second = try await factory.makeHost(context: context(third), relay: mixed, events: probe.receive)
        second.retire(); factory.retire()
        do { _ = try await factory.makeHost(context: context(next), relay: relay(), events: probe.receive); preconditionFailure("Closed factory cannot recreate peers") }
        catch NativeInterviewError.closed {}
        let gate = ReceiverFixtureGate()
        let late = NativeInterviewReceiverFactory { context in
            await gate.wait()
            return try await register(context.receive, store: store, audio: audio)
        }
        let fourth = lease(slot: first.slot, generation: 6)
        let task = Task { _ = try await late.makeHost(context: context(fourth), relay: relay(), events: probe.receive) }
        try await wait { gate.isEntered }
        late.retire(); gate.release()
        do { _ = try await task.value; preconditionFailure("Late sink cannot survive retired factory") }
        catch NativeInterviewError.changed {}
        precondition(audio.registeredGuestChannelID(slot: next.slot) == nil)
        await audio.stop()
        log("PASS: actual SDK creates UDP-relay host/offer; only TURN TCP/TLS unavailable, mixed UDP usable, missing peer stays unready; invalid port, capacity, fresh instance, retirement and uncooperative late factory fenced")
    }
}
