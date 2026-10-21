import Foundation
import CoreMedia

/// SDK callbacks already use the receiver's bounded signaling mailbox. This
/// relay converts only allowlisted state and forwards media directly to its
/// registered lease sink, without a Task per decoded frame or packet.
final class NativeInterviewReceiverEvents: @unchecked Sendable {
    private let gate = NSLock()
    private let retirement = DispatchQueue(label: "stream.interview.receiver.retirement")
    private let sink: NativeGuestMediaSink
    private let media: NativeInterviewMediaMIDs
    private let events: @Sendable (NativeInterviewMediaEvent) -> Bool
    private weak var receiver: NativeGuestReceiver?
    private var active = true, approved = false, readyReported = false, controlClosed = false
    private var approvalIntent = UUID()

    init(sink: NativeGuestMediaSink, media: NativeInterviewMediaMIDs,
         events: @escaping @Sendable (NativeInterviewMediaEvent) -> Bool) {
        self.sink = sink; self.media = media; self.events = events
    }
    func bind(_ receiver: NativeGuestReceiver) { gate.lock(); self.receiver = receiver; gate.unlock() }
    private func permittedReceiver() -> NativeGuestReceiver? {
        gate.lock(); let native = active ? receiver : nil; gate.unlock()
        guard let native else { return nil }
        guard let pair = native.selectedICEPair else { return nil }
        guard pair.local == .relay else {
            // Pinned SDK Relay policy filters advertised candidates, but a
            // checklist can still select a reflexive socket. Do not accept
            // media or announce ready on that path. Retirement is immediate;
            // the bounded event mailbox reports only the typed unavailable.
            close(failure: .unavailable); return nil
        }
        return native
    }
    #if STREAM_GUEST_VALIDATION
    var validationReturnReady = false
    #endif
    func permitsReturn(_ native: NativeGuestReceiver) -> Bool {
        gate.lock(); let permitted = active && !controlClosed; gate.unlock()
        guard permitted else { return false }
        #if STREAM_GUEST_VALIDATION
        if validationReturnReady { return true }
        #endif
        guard native.hostReady else { return false }
        return permittedReceiver() === native
    }
    func receive(_ frame: GuestVideoFrame) {
        guard let native = permittedReceiver() else { return }
        reportReady(native)
        gate.lock(); defer { gate.unlock() }
        if active { _ = sink.receive(frame) }
    }
    func receive(_ frame: GuestAudioFrame) {
        guard let native = permittedReceiver() else { return }
        reportReady(native)
        gate.lock(); defer { gate.unlock() }
        if active { _ = sink.receive(frame) }
    }
    private func reportReady(_ native: NativeGuestReceiver) {
        guard native.hostReady else { return }
        gate.lock(); let report = active && !controlClosed && !readyReported
        if report { readyReported = true }; gate.unlock()
        if report && !events(.ready) { close() }
    }
    func setApproved(_ value: Bool) {
        if let intent = beginApproval(value) { _ = finishApproval(value, intent: intent) }
    }
    func beginApproval(_ value: Bool) -> UUID? {
        gate.lock(); defer { gate.unlock() }
        guard active, !value || !controlClosed else { return nil }
        approvalIntent = UUID()
        if !value { approved = false; sink.enableScreen(false) }
        return approvalIntent
    }
    @discardableResult func finishApproval(_ value: Bool, intent: UUID) -> Bool {
        gate.lock(); defer { gate.unlock() }
        guard active, !controlClosed, approvalIntent == intent else { return false }
        approved = value
        // Gate state and the sink mutation share one ordering. Revocation
        // waits for any prior screen mutation, and later callbacks read false.
        sink.enableScreen(approved)
        return true
    }
    func receive(_ type: String, _ value: String, _ mid: String) {
        gate.lock(); let current = active, native = receiver; gate.unlock()
        guard current else { return }
        let event: NativeInterviewMediaEvent
        switch type {
        case "offer": event = .offer(sdp: value, media: media)
        case "candidate": event = .candidate(value: value, mid: mid)
        case "control-open":
            guard native?.hostReady == true, let confirmed = permittedReceiver() else { return }
            reportReady(confirmed); return
        case "control-closed":
            gate.lock()
            controlClosed = true; approvalIntent = UUID(); approved = false; sink.enableScreen(false)
            gate.unlock()
            // No further control-authorized return can be delivered. Retire
            // outside this gate because retirement reports an ordered event.
            _ = sink.allowReturnAudio(false); sink.stopProgramReturn(); event = .controlClosed
        case "private-control":
            guard let native, permittedReceiver() === native,
                  let envelope = NativeInterviewPrivateEnvelope.parse(value, negotiation: sink.lease.negotiation) else { return }
            gate.lock(); let permitted = active && !controlClosed; gate.unlock()
            guard permitted else { return }; event = .privateControl(envelope)
        case "control":
            // The receiver already validated the exact negotiation and bounds.
            guard let data = value.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sharing = object["sharing"] as? Bool else { return }
            gate.lock()
            guard active else { gate.unlock(); return }
            let permitted = approved && sharing
            sink.enableScreen(permitted)
            gate.unlock()
            event = .screenSharing(permitted)
        default: return
        }
        if !events(event) { close() }
    }
    func close(failure: NativeInterviewError? = nil) {
        gate.lock(); guard active else { gate.unlock(); return }
        active = false; approved = false; controlClosed = true; approvalIntent = UUID()
        let native = receiver; receiver = nil; gate.unlock()
        sink.close()
        let events = events
        // Exactly one retirement job after synchronous inlet revocation. The
        // decoded callback can hold outputGate; SDK teardown must run outside
        // that callback and outside every authority/C transport lock.
        retirement.async {
            native?.stop()
            if let failure { _ = events(.failed(failure)) }
        }
    }
}

/// The actual mixer mailbox supplies a single serial encoder consumer.
/// Retirement fences queued PCM/encoded packets before destroying the SDK.
private final class NativeGuestReturnSender: @unchecked Sendable {
    private let gate = NSLock()
    private var active = true
    private let token = UUID()
    private let sink: NativeGuestMediaSink
    private weak var receiver: NativeGuestReceiver?
    private let encoder: NativeGuestReturnAudioEncoder
    private let callbacks: NativeInterviewReceiverEvents
    private let events: @Sendable (NativeInterviewMediaEvent) -> Bool
    private var reportedReady = false // Owned by one return tap callback queue.
    init(sink: NativeGuestMediaSink, receiver: NativeGuestReceiver,
         encoder: NativeGuestReturnAudioEncoder, callbacks: NativeInterviewReceiverEvents,
         events: @escaping @Sendable (NativeInterviewMediaEvent) -> Bool) {
        self.sink = sink; self.receiver = receiver; self.encoder = encoder; self.callbacks = callbacks; self.events = events
    }
    func prepare() async -> Bool {
        guard await sink.installReturnAudio(token: token, sink: { [weak self] in self?.receive($0) }) else { return false }
        return activateInstalledTap()
    }
    private func activateInstalledTap() -> Bool {
        gate.lock(); defer { gate.unlock() }
        guard active, sink.allowReturnAudio(true) else {
            active = false; sink.removeReturnAudio(token: token); return false
        }
        return true
    }
    private func isActive() -> Bool { gate.lock(); defer { gate.unlock() }; return active }
    private func receive(_ frame: GuestReturnAudioFrame) {
        let age = (CMClockGetTime(CMClockGetHostTimeClock()) - frame.pts).seconds
        guard isActive(), age >= 0, age <= 0.25, let native = receiver, callbacks.permitsReturn(native) else { return }
        do {
            for packet in try encoder.encode(frame) {
                guard isActive(), callbacks.permitsReturn(native) else { return }
                let sent = sink.sendReturnIfCurrent(frame) {
                    native.sendReturnOpus(packet.data, lease: frame.lease, rtp: packet.rtp, ntp: packet.ntp)
                }
                if sent && !reportedReady {
                    reportedReady = true
                    if !events(.returnAudio(.ready)) { close() }
                }
            }
        } catch {
            close(); _ = events(.returnAudio(.failed))
        }
    }
    func close() {
        gate.lock(); let wasActive = active; active = false; gate.unlock()
        guard wasActive else { return }
        _ = sink.allowReturnAudio(false); sink.removeReturnAudio(token: token)
    }
}

final class NativeGuestReturnVideoSender: @unchecked Sendable {
    private let gate = NSLock()
    private let queue = DispatchQueue(label: "stream.interview.return.video")
    private let controls = DispatchQueue(label: "stream.interview.return.video.visibility")
    private var visibility: [Bool] = [], visibilityWorking = false
    private var token: UUID?, reportedReady = false
    private var pending: GuestReturnVideoFrame?, working = false
    private let sink: NativeGuestMediaSink, callbacks: NativeInterviewReceiverEvents
    private weak var receiver: NativeGuestReceiver?
    private let encoder: NativeGuestReturnVideoEncoder
    private var encoderToken: UUID? // Owned only by queue.
    private let events: @Sendable (NativeInterviewMediaEvent) -> Bool
    init(sink: NativeGuestMediaSink, receiver: NativeGuestReceiver,
         callbacks: NativeInterviewReceiverEvents, encoder: NativeGuestReturnVideoEncoder = .init(),
         events: @escaping @Sendable (NativeInterviewMediaEvent) -> Bool) {
        self.sink = sink; self.receiver = receiver; self.callbacks = callbacks; self.encoder = encoder; self.events = events
    }
    private func enqueueVisibilityLocked(_ enabled: Bool) {
        if visibility.count == 2 { visibility.removeFirst() }; visibility.append(enabled)
        if !visibilityWorking { visibilityWorking = true; controls.async { [self] in drainVisibility() } }
    }
    private func drainVisibility() {
        while true {
            gate.lock()
            guard !visibility.isEmpty else { visibilityWorking = false; gate.unlock(); return }
            let enabled = visibility.removeFirst(); gate.unlock()
            _ = receiver?.sendReturnVideoState(enabled)
        }
    }
    func claimPreparation() -> UUID? {
        gate.lock(); defer { gate.unlock() }
        guard token == nil else { return nil }
        let value = UUID()
        // Claim before publishing the sender token and before any suspension.
        // Stop can therefore always revoke even a not-yet-entered install.
        guard sink.claimReturnVideo(value) else { return nil }
        token = value; reportedReady = false
        _ = events(.returnVideo(.preparing)); return value
    }
    #if STREAM_GUEST_VALIDATION
    var validationBeforeInstall: (@Sendable () async -> Void)?
    #endif
    func prepare(_ current: UUID) async -> Bool {
        guard !Task.isCancelled, isActive(current) else { stop(ifCurrent: current); return false }
        #if STREAM_GUEST_VALIDATION
        await validationBeforeInstall?()
        #endif
        guard await sink.installReturnVideo(token: current, sink: { [weak self] in self?.receive($0) }) else {
            stop(ifCurrent: current, state: Task.isCancelled ? .off : .failed); return false
        }
        guard isActive(current) else {
            sink.revokeReturnVideo(token: current); sink.removeReturnVideo(token: current); return false
        }
        return true
    }
    private func isActive(_ current: UUID) -> Bool { gate.lock(); defer { gate.unlock() }; return token == current }
    var isEnabled: Bool { gate.lock(); defer { gate.unlock() }; return token != nil }
    private func receive(_ frame: GuestReturnVideoFrame) {
        gate.lock()
        guard token == frame.token else { gate.unlock(); return }
        pending = frame // Latest only: at most one pending frame plus one encode.
        let start = !working; working = true; gate.unlock()
        if start { queue.async { [self] in drain() } }
    }
    private func take() -> GuestReturnVideoFrame? {
        gate.lock(); defer { gate.unlock() }
        guard let frame = pending else { working = false; return nil }
        pending = nil; return frame
    }
    private func drain() {
        while let frame = take() { encode(frame) }
    }
    private func encode(_ frame: GuestReturnVideoFrame) {
        // Relay rejection can synchronously close this sink. No token gate or
        // codec wait is held while that path invokes its retirement hook.
        guard isActive(frame.token), let native = receiver, callbacks.permitsReturn(native) else { return }
        let age = (CMClockGetTime(CMClockGetHostTimeClock()) - frame.pts).seconds
        guard age >= 0, age <= 0.25 else { return }
        if encoderToken != frame.token { encoder.close(); encoderToken = frame.token }
        let encoded: NativeGuestReturnH264Frame?
        do { encoded = try encoder.encode(frame) }
        catch { stop(ifCurrent: frame.token, state: .failed); return }
        guard let encoded, callbacks.permitsReturn(native) else { return }
        gate.lock()
        guard token == frame.token else { gate.unlock(); return }
        let fresh = (CMClockGetTime(CMClockGetHostTimeClock()) - frame.pts).seconds <= 0.25
        let sent = fresh && sink.sendReturnVideoIfCurrent(frame) {
            native.sendReturnH264(encoded.data, lease: frame.lease, rtp: encoded.rtp, ntp: encoded.ntp)
        }
        if !sent { encoder.requestKeyframe() }
        var accepted = true
        if sent && !reportedReady {
            reportedReady = true; enqueueVisibilityLocked(true)
            accepted = events(.returnVideo(.ready))
        }
        gate.unlock()
        if !accepted { stop(ifCurrent: frame.token) }
    }
    @discardableResult func stop(ifCurrent expected: UUID? = nil, state: NativeInterviewReturnVideoState = .off) -> Bool {
        gate.lock()
        if let expected, token != expected { gate.unlock(); return false }
        let previous = token; token = nil; pending = nil
        if previous != nil { enqueueVisibilityLocked(false); _ = events(.returnVideo(state)) }
        gate.unlock()
        guard let previous else { return false }
        sink.revokeReturnVideo(token: previous)
        // Only short authority revocation is synchronous. UI/other outputs
        // never wait for a codec drain or a transport control send.
        queue.async { [self] in
            if encoderToken == previous { encoder.close(); encoderToken = nil }
            // Actual invalidation precedes removing this reservation. A held
            // encode keeps its budget while all later sends are already denied.
            sink.removeReturnVideo(token: previous)
        }
        return true
    }
    deinit { encoder.close() }
    #if STREAM_GUEST_VALIDATION
    func validationFailNextAccessUnit(after packets: Int32) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard isEnabled, let native = receiver else { continuation.resume(returning: false); return }
                encoder.requestKeyframe()
                continuation.resume(returning: native.validationFailReturnVideo(after: packets))
            }
        }
    }
    #endif
}

/// One fresh SDK peer per admitted full lease. A service relay configuration is
/// mandatory here; the prototype's loopback transport is never a fallback.
@MainActor final class NativeInterviewReceiverAdapter: NativeInterviewMediaHost {
    private let sink: NativeGuestMediaSink
    private let callbacks: NativeInterviewReceiverEvents
    private let receiver: NativeGuestReceiver
    private let returnSender: NativeGuestReturnSender?
    private let returnVideoSender: NativeGuestReturnVideoSender?
    private var expiry: Task<Void, Never>?
    private var videoPreparation: Task<Void, Never>?
    private var videoPreparationID: UUID?
    private var videoPreparationJobs: Set<UUID> = []
    private(set) var isRetired = false
    var selectedICEPair: NativeGuestReceiver.ICEPair? { isRetired ? nil : receiver.selectedICEPair }

    init(context: NativeInterviewPeerLease, relay: NativeInterviewRelayConfiguration,
         sink: NativeGuestMediaSink, events: @escaping @Sendable (NativeInterviewMediaEvent) -> Bool) throws {
        guard sink.lease == context.receive, relay.expires > Date(), !relay.servers.isEmpty,
              relay.servers.count <= 8 else { throw NativeInterviewError.expired }
        let media = try NativeInterviewMediaMIDs(audio: "audio-mid", camera: "camera-mid", screen: "screen-mid")
        var servers: [NativeGuestRelayServer] = []
        for server in relay.servers {
            guard !server.urls.isEmpty, server.urls.count <= 8 else { throw NativeInterviewError.malformed }
            let credential = server.credential?.withCredentialValue { $0 }
            for url in server.urls {
                servers.append(.init(url: url, username: server.username, credential: credential))
            }
        }
        self.sink = sink; videoState = events
        callbacks = NativeInterviewReceiverEvents(sink: sink, media: media, events: events)
        let callbacks = callbacks
        let returnEncoder = try? NativeGuestReturnAudioEncoder()
        do {
            receiver = try NativeGuestReceiver(admitted: context.receive, cameraMID: media.camera,
                screenMID: media.screen, audioMID: media.audio,
                video: { callbacks.receive($0) }, audio: { callbacks.receive($0) },
                signal: { callbacks.receive($0, $1, $2) }, transport: .relay(servers), returnAudioEnabled: returnEncoder != nil,
                returnVideoEnabled: sink.supportsProgramReturn)
        } catch { sink.close(); throw NativeInterviewError.unavailable }
        callbacks.bind(receiver)
        let returnNative = receiver
        returnSender = returnEncoder.map {
            NativeGuestReturnSender(sink: sink, receiver: returnNative, encoder: $0, callbacks: callbacks, events: events)
        }
        returnVideoSender = sink.supportsProgramReturn ? NativeGuestReturnVideoSender(sink: sink, receiver: returnNative, callbacks: callbacks, events: events) : nil
        _ = events(.returnAudio(returnSender == nil ? .unavailable : .preparing))
        if let sender = returnVideoSender { sink.bindVideoRetirement { [weak sender] in sender?.stop() } }
        _ = events(.returnVideo(returnVideoSender == nil ? .unavailable : .off))
        let delay = max(0, relay.expires.timeIntervalSinceNow)
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard let self, !self.isRetired else { return }
            self.retire(); _ = events(.failed(.expired))
        }
    }
    func prepareReturnAudio() async {
        if let returnSender, !isRetired, !(await returnSender.prepare()) { returnSender.close() }
    }
    var supportsProgramReturn: Bool { !isRetired && returnVideoSender != nil && callbacks.permitsReturn(receiver) }
    private func cancelVideoPreparation() {
        videoPreparation?.cancel(); videoPreparation = nil; videoPreparationID = nil
    }
    func setProgramReturnEnabled(_ enabled: Bool) -> Bool {
        guard supportsProgramReturn, let sender = returnVideoSender else { return false }
        if !enabled {
            cancelVideoPreparation(); sender.stop(); _ = videoState(.returnVideo(.off)); return true
        }
        if sender.isEnabled { return true }
        cancelVideoPreparation()
        // At most one entered old install and one deliberate replacement.
        // Stop can revoke this claim before the task gets its first turn.
        guard videoPreparationJobs.count < 2, let claimed = sender.claimPreparation() else { return false }
        let ticket = UUID(); videoPreparationID = ticket; videoPreparationJobs.insert(ticket)
        videoPreparation = Task { [weak self] in
            _ = await sender.prepare(claimed)
            guard let self else { sender.stop(ifCurrent: claimed); return }
            self.videoPreparationJobs.remove(ticket)
            guard self.videoPreparationID == ticket else { sender.stop(ifCurrent: claimed); return }
            self.videoPreparation = nil; self.videoPreparationID = nil
        }
        return true
    }
    func selectReturnVideoSource(_ source: NativeInterviewReturnVideoSource) -> Bool {
        guard supportsProgramReturn, let sender = returnVideoSender else { return false }
        if sink.returnVideoSource == source { return true }
        // Changing the source is an Off action. It never replays an earlier On.
        cancelVideoPreparation(); sender.stop()
        guard sink.selectReturnVideoSource(source) else { return false }
        _ = videoState(.returnVideoSource(source)); return true
    }
    private let videoState: @Sendable (NativeInterviewMediaEvent) -> Bool
    #if STREAM_GUEST_VALIDATION
    func validationCloseReturnAudio() { returnSender?.close() }
    func validationPermitReturn() { callbacks.validationReturnReady = true }
    var validationPendingVideoPreparations: Int { videoPreparationJobs.count }
    var validationVideoEnabled: Bool { returnVideoSender?.isEnabled == true }
    func validationFailReturnVideo(after packets: Int32) async -> Bool {
        await returnVideoSender?.validationFailNextAccessUnit(after: packets) == true
    }
    var validationReturnVideoFault: SGReturnVideoFaultReceipt { receiver.validationReturnVideoFault }
    #endif
    func startHost() throws {
        guard !isRetired else { throw NativeInterviewError.closed }
        guard receiver.startHost() else { retire(); throw NativeInterviewError.transport }
    }
    func acceptAnswer(_ sdp: String) throws {
        guard !isRetired else { throw NativeInterviewError.closed }
        guard !sdp.isEmpty, sdp.utf8.count <= 58_000, receiver.answer(sdp) else {
            retire(); throw NativeInterviewError.malformed
        }
    }
    func acceptCandidate(_ value: String, mid: String) throws {
        guard !isRetired else { throw NativeInterviewError.closed }
        let candidate = try NativeInterviewICECandidate(value: value, mid: mid)
        // One unusable trickled candidate is independently reported. It
        // cannot retire an otherwise valid answer or healthy media peer.
        guard receiver.candidate(candidate.value, mid: candidate.mid) else {
            throw NativeInterviewError.transport
        }
    }
    var supportsPrivateMessages: Bool { !isRetired && callbacks.permitsReturn(receiver) }
    func sendPrivateControl(_ envelope: NativeInterviewPrivateEnvelope) -> Bool {
        guard supportsPrivateMessages else { return false }
        return receiver.sendPrivateControl(envelope)
    }
    var supportsPublicChat: Bool { !isRetired && callbacks.permitsReturn(receiver) }
    func sendPublicChat(_ envelope: GuestPublicChatEnvelope, lowPriority: Bool) -> Bool {
        guard supportsPublicChat else { return false }
        return receiver.sendPublicChat(envelope, lowPriority: lowPriority)
    }
    func approveScreen(_ approved: Bool) -> Bool {
        guard !isRetired, let intent = callbacks.beginApproval(approved) else { return false }
        // Never hold the sink lock across receiver/output callbacks.
        let accepted = receiver.approveScreen(approved)
        return callbacks.finishApproval(accepted && approved, intent: intent) && accepted
    }
    func retire() {
        guard !isRetired else { return }
        isRetired = true; videoPreparation?.cancel(); expiry?.cancel(); expiry = nil; returnSender?.close(); returnVideoSender?.stop(); callbacks.close()
    }
    deinit { videoPreparation?.cancel(); expiry?.cancel(); returnSender?.close(); returnVideoSender?.stop(); callbacks.close() }
}

/// The runtime supplies admission and its controller-issued sink. The factory
/// has one active peer and consumes no credentials until that binding succeeds.
@MainActor final class NativeInterviewReceiverFactory: NativeInterviewMediaHostFactory {
    typealias SinkFactory = @MainActor (NativeInterviewPeerLease) async throws -> NativeGuestMediaSink
    private let sinkFactory: SinkFactory
    private weak var current: NativeInterviewReceiverAdapter?
    private var pending: UUID?
    private var closed = false
    init(sinkFactory: @escaping SinkFactory) { self.sinkFactory = sinkFactory }
    var selectedICEPair: NativeGuestReceiver.ICEPair? { closed ? nil : current?.selectedICEPair }
    func makeHost(context: NativeInterviewPeerLease, relay: NativeInterviewRelayConfiguration,
                  events: @escaping @Sendable (NativeInterviewMediaEvent) -> Bool) async throws -> any NativeInterviewMediaHost {
        guard !closed, !Task.isCancelled else { throw NativeInterviewError.closed }
        guard current?.isRetired != false, pending == nil else { throw NativeInterviewError.capacity }
        guard relay.expires > Date() else { throw NativeInterviewError.expired }
        let ticket = UUID(); pending = ticket
        defer { if pending == ticket { pending = nil } }
        let sink = try await sinkFactory(context)
        guard !closed, !Task.isCancelled, pending == ticket, sink.lease == context.receive else {
            sink.close(); throw NativeInterviewError.changed
        }
        let host: NativeInterviewReceiverAdapter
        do { host = try NativeInterviewReceiverAdapter(context: context, relay: relay, sink: sink, events: events) }
        catch { sink.close(); throw error }
        await host.prepareReturnAudio()
        guard !closed, !Task.isCancelled, pending == ticket, !host.isRetired else {
            host.retire(); throw NativeInterviewError.changed
        }
        current = host; return host
    }
    func retire() {
        closed = true; pending = nil; current?.retire(); current = nil
    }
    #if STREAM_GUEST_VALIDATION
    func validationFailReturnVideo(after packets: Int32) async -> Bool {
        await current?.validationFailReturnVideo(after: packets) == true
    }
    var validationReturnVideoFault: SGReturnVideoFaultReceipt? { current?.validationReturnVideoFault }
    #endif
}
