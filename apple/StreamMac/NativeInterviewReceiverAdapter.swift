import Foundation

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
            gate.unlock(); event = .controlClosed
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

/// One fresh SDK peer per admitted full lease. A service relay configuration is
/// mandatory here; the prototype's loopback transport is never a fallback.
@MainActor final class NativeInterviewReceiverAdapter: NativeInterviewMediaHost {
    private let sink: NativeGuestMediaSink
    private let callbacks: NativeInterviewReceiverEvents
    private let receiver: NativeGuestReceiver
    private var expiry: Task<Void, Never>?
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
        self.sink = sink
        callbacks = NativeInterviewReceiverEvents(sink: sink, media: media, events: events)
        let callbacks = callbacks
        do {
            receiver = try NativeGuestReceiver(admitted: context.receive, cameraMID: media.camera,
                screenMID: media.screen, audioMID: media.audio,
                video: { callbacks.receive($0) }, audio: { callbacks.receive($0) },
                signal: { callbacks.receive($0, $1, $2) }, transport: .relay(servers))
        } catch { sink.close(); throw NativeInterviewError.unavailable }
        callbacks.bind(receiver)
        let delay = max(0, relay.expires.timeIntervalSinceNow)
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard let self, !self.isRetired else { return }
            self.retire(); _ = events(.failed(.expired))
        }
    }
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
    func approveScreen(_ approved: Bool) -> Bool {
        guard !isRetired, let intent = callbacks.beginApproval(approved) else { return false }
        // Never hold the sink lock across receiver/output callbacks.
        let accepted = receiver.approveScreen(approved)
        return callbacks.finishApproval(accepted && approved, intent: intent) && accepted
    }
    func retire() {
        guard !isRetired else { return }
        isRetired = true; expiry?.cancel(); expiry = nil; callbacks.close()
    }
    deinit { expiry?.cancel(); callbacks.close() }
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
        current = host; return host
    }
    func retire() {
        closed = true; pending = nil; current?.retire(); current = nil
    }
}
