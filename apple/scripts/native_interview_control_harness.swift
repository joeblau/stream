import Foundation

private enum InterviewFixtureError: Error { case failed(String) }
private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw InterviewFixtureError.failed(message) }
}
private func receipt(_ value: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
}
private func progress(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
private struct ProbeReceipt: Sendable {
    let type: String
    let generation: UUID?
    let hostGeneration: UUID?
    let from: UUID?
    let kind: String?
    let payload: String?
}
private actor InterviewGuestProbe {
    let socket: any NativeInterviewSocketTransport
    private var messages: [ProbeReceipt] = []
    private var task: Task<Void, Never>?
    private(set) var closedCode: Int?
    init(socket: any NativeInterviewSocketTransport) { self.socket = socket }
    func start() throws {
        let text = try receipt(["type": "hello", "name": "Synthetic native service guest"])
        try require(socket.send(text, acknowledgment: false), "Guest hello was not queued")
        task = Task { [weak self, socket] in
            while !Task.isCancelled {
                do {
                    let text = try await socket.receive()
                    guard !Task.isCancelled, let self else { return }
                    try await self.received(text)
                } catch {
                    guard let self else { return }; await self.didClose(socket.closeCode); return
                }
            }
        }
    }
    private func received(_ text: String) throws {
        let object = try NativeInterviewWire.object(Data(text.utf8))
        let delivery = try NativeInterviewWire.number(object["delivery"])
        let acknowledgment = try receipt(["type": "ack", "delivery": Int64(delivery)])
        try require(socket.send(acknowledgment, acknowledgment: true), "Guest ACK queue failed")
        let value = ProbeReceipt(type: object["type"] as? String ?? "",
            generation: (object["generation"] as? String).flatMap(UUID.init(uuidString:)),
            hostGeneration: (object["hostGeneration"] as? String).flatMap(UUID.init(uuidString:)),
            from: (object["from"] as? String).flatMap(UUID.init(uuidString:)),
            kind: object["kind"] as? String, payload: object["payload"] as? String)
        try require(messages.count < 256, "Guest fixture history exceeded its bounded budget")
        messages.append(value)
    }
    private func didClose(_ code: Int?) { closedCode = code }
    func next(_ type: String, kind: String? = nil, since: Int = 0) async throws -> ProbeReceipt {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let value = messages.dropFirst(since).first(where: { $0.type == type && (kind == nil || $0.kind == kind) }) { return value }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw InterviewFixtureError.failed("Missing bounded guest \(type) receipt")
    }
    var count: Int { messages.count }
    func answer(_ offer: ProbeReceipt, negotiation: UUID? = nil) throws {
        let actual = try offerNegotiation(offer)
        try signal(offer, kind: "answer", payload: ["negotiation": (negotiation ?? actual).uuidString.lowercased(),
            "description": ["type": "answer", "sdp": "synthetic bounded answer"]])
    }
    func candidate(_ offer: ProbeReceipt, negotiation: UUID? = nil) throws {
        let actual = try offerNegotiation(offer)
        try signal(offer, kind: "candidate", payload: ["negotiation": (negotiation ?? actual).uuidString.lowercased(),
            "candidate": ["candidate": "candidate:fixture 1 udp 1 127.0.0.1 50000 typ host", "sdpMid": "camera"]])
    }
    func malformedSignal(_ offer: ProbeReceipt, negotiation: UUID? = nil) throws {
        guard let host = offer.from, let generation = offer.generation else { throw InterviewFixtureError.failed("Missing service generation") }
        let payload = try negotiation.map { try receipt(["negotiation": $0.uuidString.lowercased(), "description": ["type": "answer"]]) } ?? "{}"
        let text = try receipt(["type": "signal", "to": host.uuidString.lowercased(), "targetGeneration": generation.uuidString.lowercased(),
                                "kind": "answer", "payload": payload])
        try require(socket.send(text, acknowledgment: false), "Malformed signal test not queued")
    }
    private func offerNegotiation(_ offer: ProbeReceipt) throws -> UUID {
        guard let payload = offer.payload else { throw InterviewFixtureError.failed("Missing synthetic offer envelope") }
        return try NativeInterviewWire.id(NativeInterviewWire.object(Data(payload.utf8))["negotiation"])
    }
    private func signal(_ offer: ProbeReceipt, kind: String, payload: [String: Any]) throws {
        guard let host = offer.from, let generation = offer.generation else { throw InterviewFixtureError.failed("Missing service generation") }
        let text = try receipt(["type": "signal", "to": host.uuidString.lowercased(), "targetGeneration": generation.uuidString.lowercased(),
                                "kind": kind, "payload": try receipt(payload)])
        try require(socket.send(text, acknowledgment: false), "Synthetic signal not queued")
    }
    func stop() { task?.cancel(); socket.close() }
}

/// Only relay provisioning is injected for session authority tests. Every
/// create/invite/end/socket/ACK/admission/rejoin is the actual local Worker.
private struct InterviewFixtureRelayService: NativeInterviewService {
    let client: NativeInterviewServiceClient
    let configuration: NativeInterviewConfiguration
    init(_ client: NativeInterviewServiceClient, configuration: NativeInterviewConfiguration) {
        self.client = client; self.configuration = configuration
    }
    func createRoom() async throws -> NativeInterviewCreatedRoom { try await client.createRoom() }
    func createInvite(room: UUID) async throws -> NativeInterviewInvite { try await client.createInvite(room: room) }
    func endRoom(_ room: UUID) async throws { try await client.endRoom(room) }
    func connect(room: UUID, host: NativeInterviewInvite) async throws -> any NativeInterviewSocketTransport { try await client.connect(room: room, host: host) }
    func relay(room: UUID, host: NativeInterviewInvite) async throws -> NativeInterviewRelayConfiguration {
        .init(servers: [.init(urls: ["turn:127.0.0.1:3478?transport=udp"], username: "synthetic-session-boundary",
                             credential: try .init("synthetic-relay-not-a-running-server"))],
              expires: Date().addingTimeInterval(600), refreshAt: Date().addingTimeInterval(480))
    }
    func shutdown() async { await client.shutdown() }
}

private actor InterviewHeldRelayService: NativeInterviewService {
    let client: NativeInterviewServiceClient
    let configuration: NativeInterviewConfiguration
    private var pending: CheckedContinuation<NativeInterviewRelayConfiguration, Error>?
    private var holding = true
    private(set) var requests = 0
    init(_ client: NativeInterviewServiceClient, configuration: NativeInterviewConfiguration) { self.client = client; self.configuration = configuration }
    func createRoom() async throws -> NativeInterviewCreatedRoom { try await client.createRoom() }
    func createInvite(room: UUID) async throws -> NativeInterviewInvite { try await client.createInvite(room: room) }
    func endRoom(_ room: UUID) async throws { try await client.endRoom(room) }
    func connect(room: UUID, host: NativeInterviewInvite) async throws -> any NativeInterviewSocketTransport { try await client.connect(room: room, host: host) }
    func relay(room: UUID, host: NativeInterviewInvite) async throws -> NativeInterviewRelayConfiguration {
        requests += 1
        if !holding { return try value() }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func release() throws { holding = false; let held = pending; pending = nil; held?.resume(returning: try value()) }
    private func value() throws -> NativeInterviewRelayConfiguration {
        .init(servers: [.init(urls: ["turn:127.0.0.1:3478?transport=udp"], username: "synthetic-held-relay",
                             credential: try .init("synthetic-no-running-turn-server"))],
              expires: Date().addingTimeInterval(600), refreshAt: Date().addingTimeInterval(480))
    }
    func shutdown() async { await client.shutdown() }
}

@MainActor private final class InterviewBoundaryHost: NativeInterviewMediaHost {
    let context: NativeInterviewPeerLease
    let events: @Sendable (NativeInterviewMediaEvent) -> Bool
    let overflow: Bool
    private(set) var started = false, retired = false, answers = 0, candidates = 0, refusedEvent = false
    init(context: NativeInterviewPeerLease, overflow: Bool, events: @escaping @Sendable (NativeInterviewMediaEvent) -> Bool) {
        self.context = context; self.overflow = overflow; self.events = events
    }
    func startHost() throws {
        started = true
        let mids = try NativeInterviewMediaMIDs(audio: "audio", camera: "camera", screen: "screen")
        // Queue-before-offer exercises the session's actual candidate mailbox.
        let count = overflow ? 33 : 1
        for _ in 0..<count {
            if !events(.candidate(value: "candidate:fixture 1 udp 1 127.0.0.1 50001 typ host", mid: "camera")) {
                refusedEvent = true; retire(); return
            }
        }
        _ = events(.offer(sdp: "synthetic bounded offer", media: mids))
    }
    func acceptAnswer(_ sdp: String) throws { answers += 1; _ = events(.ready) }
    func acceptCandidate(_ value: String, mid: String) throws { candidates += 1 }
    func approveScreen(_ approved: Bool) -> Bool { !retired }
    func retire() { retired = true }
}
@MainActor private final class InterviewBoundaryFactory: NativeInterviewMediaHostFactory {
    struct Pending { let host: InterviewBoundaryHost; let continuation: CheckedContinuation<any NativeInterviewMediaHost, Error> }
    var held = false, overflow = false
    private(set) var hosts: [InterviewBoundaryHost] = [], pending: [Pending] = []
    func makeHost(context: NativeInterviewPeerLease, relay: NativeInterviewRelayConfiguration,
                  events: @escaping @Sendable (NativeInterviewMediaEvent) -> Bool) async throws -> any NativeInterviewMediaHost {
        let host = InterviewBoundaryHost(context: context, overflow: overflow, events: events); hosts.append(host)
        if !held { return host }
        return try await withCheckedThrowingContinuation { pending.append(.init(host: host, continuation: $0)) }
    }
    func release() { let active = pending; pending.removeAll(); active.forEach { $0.continuation.resume(returning: $0.host) } }
}

private final class HeldInterviewHTTP: NativeInterviewHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var waits: [CheckedContinuation<(Data, HTTPURLResponse), Error>] = []
    private var total = 0
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); total += 1; waits.append(continuation); lock.unlock()
        }
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return total }
    func release() {
        lock.lock(); let active = waits; waits.removeAll(); lock.unlock()
        let response = HTTPURLResponse(url: URL(string: "https://interviews.example.test/v1/rooms")!,
                                       statusCode: 201, httpVersion: nil, headerFields: nil)!
        active.forEach { $0.resume(returning: (Data("{}".utf8), response)) }
    }
    func shutdown() {} // Deliberately noncooperative, to prove occupied admission.
}
private final class FailedInterviewHTTP: NativeInterviewHTTPTransport, @unchecked Sendable {
    private let lock = NSLock(); private var total = 0
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.locked { total += 1 }
        throw NativeInterviewError.transport
    }
    var count: Int { lock.locked { total } }
    func shutdown() {}
}
private extension NSLock {
    func locked<Value>(_ body: () throws -> Value) rethrows -> Value { lock(); defer { unlock() }; return try body() }
}

@main @MainActor struct NativeInterviewControlHarness {
    static func wait(_ message: String, until: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !until() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try require(until(), message)
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 2, let url = URL(string: CommandLine.arguments[1]),
              let token = ProcessInfo.processInfo.environment["STREAM_NATIVE_INTERVIEW_FIXTURE_TOKEN"],
              token.hasPrefix("native-fixture-") else { throw InterviewFixtureError.failed("Explicit synthetic local service fixture required") }
        let configuration = try NativeInterviewConfiguration(serviceURL: url,
            allowedOrigin: URL(string: "https://interviews.example.test")!, allowLoopbackHTTPForValidation: true)
        let secret = try NativeInterviewSecret(token)
        try require(!String(describing: secret).contains(token), "Credential description leaked")
        let client = NativeInterviewServiceClient(configuration: configuration, credential: { secret })
        let session = NativeInterviewSession(service: client)
        defer { session.shutdown() }
        try await session.create()
        try require(session.snapshot.room != nil && session.snapshot.phase == .disconnected, "Actual operator room creation failed")
        let room = session.snapshot.room!, invite = try session.guestInvite()
        let shared = try invite.guestURL(configuration: configuration, room: room)
        try require(shared.fragment != nil && !shared.query!.contains("cap."), "Invite did not use fragment-only authority")
        try require(!String(describing: invite).contains(shared.fragment!), "Invite description leaked capability")
        try await session.connect()
        try await wait("Actual URLSession host welcome missing") { session.snapshot.phase == .connected }
        progress("PROGRESS: actual HTTP create and URLSession host welcome")
        let guest = InterviewGuestProbe(socket: try await client.connect(room: room, host: invite))
        try await guest.start()
        let welcome = try await guest.next("welcome")
        try await wait("Actual lobby guest missing") { session.snapshot.members.first?.membership == .waiting }
        try require(session.admit(invite.id), "Explicit native admission not queued")
        _ = try await guest.next("admitted")
        try await wait("Actual service admission not acknowledged") { session.snapshot.members.first?.membership == .backstage }
        try require(session.snapshot.members.first?.media == .unavailable, "Unlinked native factory claimed media readiness")
        try require(!session.approveScreen(true, guest: invite.id), "Unlinked native transport granted screen access")
        try require(session.setMembership(.onair, guest: invite.id), "Service membership action refused")
        try await wait("Service onair receipt missing") { session.snapshot.members.first?.membership == .onair }
        try require(session.reportStatus(program: false, recording: true), "Status command not queued")
        try await wait("Actual status receipt missing") { session.snapshot.recording && !session.snapshot.program }
        progress("PROGRESS: actual lobby, deliberate admission and service membership/status")
        for index in 0..<48 { try require(session.reportStatus(program: index.isMultiple(of: 2), recording: false), "Bounded status burst was refused") }
        try require(session.setLocked(true), "Lock not queued")
        do { try await wait("Prioritized ACKs failed under actual service delivery credit") { session.snapshot.locked } }
        catch {
            progress("FAILURE metadata: phase=\(session.snapshot.phase.rawValue), failure=\(session.snapshot.failure?.rawValue ?? "none"), guestClose=\(await guest.closedCode ?? 0)")
            throw error
        }
        try require(!session.snapshot.program && !session.snapshot.recording, "Actual status burst ordering failed")
        try require(session.setLocked(false), "Unlock not queued")
        try await wait("Unlock receipt missing") { !session.snapshot.locked }
        let replacement = InterviewGuestProbe(socket: try await client.connect(room: room, host: invite))
        try await replacement.start()
        let newWelcome = try await replacement.next("welcome")
        try require(welcome.generation != newWelcome.generation, "Actual service guest generation did not rotate")
        try await wait("Replacement guest did not return to waiting") { session.snapshot.members.first?.membership == .waiting }
        try require(session.admit(invite.id), "Replacement guest was not explicitly admitted")
        let admitted = try await replacement.next("admitted")
        try await wait("Replacement admission receipt missing") { session.snapshot.members.first?.membership == .backstage }
        session.disconnectForRejoin()
        _ = try await replacement.next("host-disconnected")
        try await session.connect()
        try await wait("Native host explicit rejoin failed") { session.snapshot.phase == .connected && !session.snapshot.members.isEmpty }
        let cursor = await replacement.count
        try require(session.admit(invite.id), "Host rejoin required deliberate readmission")
        let readmitted = try await replacement.next("admitted", since: cursor)
        try require(admitted.hostGeneration != readmitted.hostGeneration, "Actual host generation did not rotate")
        try await wait("Post-rejoin admission missing") { session.snapshot.members.first?.membership == .backstage }
        try require(session.remove(invite.id), "Explicit revocation not queued")
        try await wait("Revoked guest stayed in actual lobby") { session.snapshot.members.isEmpty }
        do { _ = try await client.relay(room: room, host: try session.guestInvite()); throw InterviewFixtureError.failed("Revoked guest capability obtained relay") }
        catch NativeInterviewError.authorization {}
        session.end()
        try await wait("Actual service end acknowledgment missing") { session.snapshot.phase == .ended }
        try require(session.snapshot.failure == nil, "Actual end was incorrectly labeled uncertain")
        do { _ = try session.guestInvite(); throw InterviewFixtureError.failed("Terminal session retained capability") }
        catch NativeInterviewError.expired {}
        await guest.stop(); await replacement.stop()
        progress("PASS: actual local Worker URLSession create/lobby/admit/service-state/ACK-credit/rejoin/revocation/end; no native media readiness or relay claimed")
        try await missingRelay(configuration: configuration, secret: secret)
        progress("PASS: actual unconfigured TURN response blocks the native factory before allocation")
        try await sessionBoundaries(configuration: configuration, secret: secret)
        progress("PASS: actual Worker signaling with injected media boundary checks exact negotiation/generation, waiting privacy, screen-control loss, bounded held preparations/timeouts/overflow and late-result retirement; no decoded media claimed")
        try await sharedGenerationAllocator(configuration: configuration, secret: secret)
        progress("PASS: two real service rooms retain injected native generation monotonicity; an allocator replay cannot allocate another host")
        try await heldRelayRejoin(configuration: configuration, secret: secret)
        progress("PASS: a held relay reply cannot cross actual host reconnect; occupancy stays bounded and only explicit fresh restart allocates")
        try await injectedBoundaries(configuration: configuration, secret: secret)
        progress("PASS: bounded noncooperative occupied reads, cancellation cleanup, no POST replay, malformed credential/configuration refusal")
    }

    static func missingRelay(configuration: NativeInterviewConfiguration, secret: NativeInterviewSecret) async throws {
        let client = NativeInterviewServiceClient(configuration: configuration, credential: { secret })
        let factory = InterviewBoundaryFactory(), session = NativeInterviewSession(service: client, factory: factory)
        defer { session.shutdown() }
        try await session.create(); let invite = try session.guestInvite(), room = session.snapshot.room!
        try await session.connect(); try await wait("Relay test host not connected") { session.snapshot.phase == .connected }
        let guest = InterviewGuestProbe(socket: try await client.connect(room: room, host: invite)); try await guest.start()
        _ = try await guest.next("welcome")
        try await wait("Relay test lobby missing") { !session.snapshot.members.isEmpty }
        try require(session.admit(invite.id), "Relay test admission failed")
        try await wait("Missing real TURN was not represented as unavailable") { session.snapshot.members.first?.media == .failed && session.snapshot.failure == .unavailable }
        try require(factory.hosts.isEmpty && !session.approveScreen(true, guest: invite.id), "Missing TURN allocated a fake native peer")
        session.end(); try await wait("Relay test end missing") { session.snapshot.phase == .ended }
        await guest.stop()
    }

    static func sessionBoundaries(configuration: NativeInterviewConfiguration, secret: NativeInterviewSecret) async throws {
        let client = NativeInterviewServiceClient(configuration: configuration, credential: { secret })
        let factory = InterviewBoundaryFactory()
        let session = NativeInterviewSession(service: InterviewFixtureRelayService(client, configuration: configuration), factory: factory,
                                             mediaPreparationTimeout: .milliseconds(300), negotiationTimeout: .seconds(2))
        defer { factory.release(); session.shutdown() }
        try await session.create(); let invite = try session.guestInvite(), room = session.snapshot.room!
        try await session.connect(); try await wait("Boundary host not connected") { session.snapshot.phase == .connected }
        let guest = InterviewGuestProbe(socket: try await client.connect(room: room, host: invite)); try await guest.start()
        _ = try await guest.next("welcome"); try await wait("Boundary lobby missing") { !session.snapshot.members.isEmpty }
        try require(session.admit(invite.id), "Boundary admission not queued")
        let offer = try await guest.next("signal", kind: "offer")
        try await wait("Boundary host missing") { factory.hosts.count == 1 }
        let first = factory.hosts[0]
        try await guest.candidate(offer, negotiation: UUID()); try await guest.candidate(offer)
        try await guest.malformedSignal(offer, negotiation: UUID())
        try await guest.answer(offer, negotiation: UUID()); try await guest.answer(offer)
        try await wait("Valid answer did not enable actual session readiness") { session.snapshot.members.first?.media == .ready }
        try require(first.answers == 1 && first.candidates == 1, "Stale negotiation was accepted or valid pre-answer ICE was lost")
        try require(session.readyPeerLease(for: invite.id) == first.context, "Ready full-context lookup differs from actual factory lease")
        try require(session.approveScreen(true, guest: invite.id), "Explicit synthetic boundary approval refused")
        _ = first.events(.screenSharing(true))
        try await wait("Approved screen-state metadata missing") { session.snapshot.members.first?.screenSharing == true }
        _ = first.events(.controlClosed)
        try await wait("Control closure retained screen permission") { session.snapshot.members.first?.screenApproved == false }
        try require(!first.retired && session.snapshot.members.first?.media == .ready, "Screen control closure retired healthy camera/audio authority")
        try require(session.approveScreen(true, guest: invite.id), "Second screen approval refused")
        _ = first.events(.screenSharing(true)); try await wait("Screen state not ready before rejoin") { session.snapshot.members.first?.screenSharing == true }
        let replacement = InterviewGuestProbe(socket: try await client.connect(room: room, host: invite)); try await replacement.start()
        _ = try await replacement.next("welcome")
        try await wait("Rejoined service guest did not reset waiting privacy") { session.snapshot.members.first?.membership == .waiting }
        try require(first.retired && session.snapshot.members.first?.media == .unavailable
            && session.snapshot.members.first?.screenApproved == false && session.snapshot.members.first?.screenSharing == false,
                    "Waiting roster retained previous native readiness or screen permission")
        try require(session.readyPeerLease(for: invite.id) == nil, "Rejoin retained a routable full lease")
        try require(!first.events(.ready), "Retired full lease retained callback mailbox")
        try require(session.admit(invite.id), "Boundary rejoin not admitted")
        let newOffer = try await replacement.next("signal", kind: "offer")
        try await wait("Replacement boundary host missing") { factory.hosts.count == 2 }
        let second = factory.hosts[1]
        try require(second.context.receive.slot == first.context.receive.slot && second.context.receive.generation > first.context.receive.generation
            && second.context.receive.negotiation != first.context.receive.negotiation && second.context.guestGeneration != first.context.guestGeneration,
                    "Full lease did not retain stable slot and replace all rejoin authority")
        try await replacement.answer(newOffer, negotiation: first.context.receive.negotiation)
        try await replacement.answer(newOffer)
        try await wait("Replacement answer not acknowledged") { session.snapshot.members.first?.media == .ready }
        try require(second.answers == 1, "Previous negotiation crossed actual service rejoin")
        factory.held = true
        try require(session.restartMedia(invite.id), "First held preparation not admitted")
        try await wait("Held factory not entered") { factory.pending.count == 1 }
        try await wait("Held preparation deadline missing") { session.snapshot.members.first?.media == .failed && session.snapshot.failure == .timeout }
        try require(session.occupiedMediaPreparationCount == 1, "Timeout prematurely released noncooperative native preparation")
        try require(session.restartMedia(invite.id), "Second bounded held preparation not admitted")
        try await wait("Second held factory not entered") { factory.pending.count == 2 }
        try await wait("Second held deadline missing") { session.snapshot.members.first?.media == .failed }
        try require(session.occupiedMediaPreparationCount == 2 && !session.restartMedia(invite.id), "Retried timeouts exceeded two actual occupied preparations")
        let late = factory.pending.map(\.host)
        try require(session.remove(invite.id), "Pending host removal not queued")
        try await wait("Pending guest not revoked by actual Worker") { session.snapshot.members.isEmpty }
        factory.release()
        try await wait("Late factory completions retained occupancy") { session.occupiedMediaPreparationCount == 0 }
        try require(late.allSatisfy { $0.retired && !$0.started }, "Late native host was started or published after revocation")
        factory.held = false; factory.overflow = true
        let nextInvite = try await session.createGuestInvite()
        let nextGuest = InterviewGuestProbe(socket: try await client.connect(room: room, host: nextInvite)); try await nextGuest.start()
        _ = try await nextGuest.next("welcome"); try await wait("New bounded invite lobby missing") { session.snapshot.members.first?.id == nextInvite.id }
        try require(session.admit(nextInvite.id), "Overflow boundary admission not queued")
        try await wait("Callback overflow did not close actual session host") { session.snapshot.members.first?.media == .failed && session.snapshot.failure == .capacity }
        try require(factory.hosts.last?.retired == true && factory.hosts.last?.refusedEvent == true, "Overflow callback kept active transport")
        factory.overflow = false
        try require(session.restartMedia(nextInvite.id), "Negotiation timeout preparation failed")
        _ = try await nextGuest.next("signal", kind: "offer")
        let unacknowledged = factory.hosts.last!
        try await wait("Unanswered offer stayed active past negotiation deadline") { session.snapshot.members.first?.media == .failed && session.snapshot.failure == .timeout }
        try require(unacknowledged.retired, "Negotiation deadline failed to retire actual host")
        let cursor = await nextGuest.count
        try require(session.restartMedia(nextInvite.id), "Malformed signal test restart failed")
        let malformedOffer = try await nextGuest.next("signal", kind: "offer", since: cursor)
        try await nextGuest.malformedSignal(malformedOffer)
        try await wait("Malformed peer SDP not declined") { session.snapshot.members.first?.media == .failed && session.snapshot.failure == .malformed }
        try require(session.snapshot.phase == .connected && session.setLocked(true), "Malformed peer payload destroyed the host control session")
        try await wait("Host controls stopped after malformed peer SDP") { session.snapshot.locked }
        session.end(); try await wait("Boundary room end missing") { session.snapshot.phase == .ended }
        await guest.stop(); await replacement.stop(); await nextGuest.stop()
    }

    static func sharedGenerationAllocator(configuration: NativeInterviewConfiguration, secret: NativeInterviewSecret) async throws {
        var issued: UInt64 = 400
        let allocate: @MainActor () -> UInt64? = { issued += 1; return issued }
        var contexts: [NativeInterviewPeerLease] = []
        for _ in 0..<2 {
            let client = NativeInterviewServiceClient(configuration: configuration, credential: { secret })
            let factory = InterviewBoundaryFactory()
            let session = NativeInterviewSession(service: InterviewFixtureRelayService(client, configuration: configuration),
                                                 factory: factory, nextGeneration: allocate)
            defer { session.shutdown() }
            try await session.create(); let invite = try session.guestInvite(), room = session.snapshot.room!
            try await session.connect(); try await wait("Allocator host not connected") { session.snapshot.phase == .connected }
            let guest = InterviewGuestProbe(socket: try await client.connect(room: room, host: invite)); try await guest.start()
            _ = try await guest.next("welcome"); try await wait("Allocator lobby missing") { !session.snapshot.members.isEmpty }
            try require(session.admit(invite.id), "Allocator admission failed")
            let offer = try await guest.next("signal", kind: "offer"); try await guest.answer(offer)
            try await wait("Allocator host readiness missing") { session.readyPeerLease(for: invite.id) != nil }
            contexts.append(session.readyPeerLease(for: invite.id)!)
            session.end(); try await wait("Allocator room did not end") { session.snapshot.phase == .ended }
            await guest.stop()
        }
        try require(contexts.map { $0.receive.generation } == [401, 402], "New session reset the injected runtime generation")
        let client = NativeInterviewServiceClient(configuration: configuration, credential: { secret })
        let factory = InterviewBoundaryFactory()
        let replay = NativeInterviewSession(service: InterviewFixtureRelayService(client, configuration: configuration),
                                           factory: factory, nextGeneration: { 500 })
        defer { replay.shutdown() }
        try await replay.create(); let invite = try replay.guestInvite(), room = replay.snapshot.room!
        try await replay.connect(); try await wait("Replay allocator host not connected") { replay.snapshot.phase == .connected }
        let guest = InterviewGuestProbe(socket: try await client.connect(room: room, host: invite)); try await guest.start()
        _ = try await guest.next("welcome"); try await wait("Replay allocator lobby missing") { !replay.snapshot.members.isEmpty }
        try require(replay.admit(invite.id), "Replay allocator initial admission failed")
        _ = try await guest.next("signal", kind: "offer")
        try require(!replay.restartMedia(invite.id) && replay.snapshot.failure == .capacity && factory.hosts.count == 1,
                    "Replayed injected generation allocated a new native host")
        replay.end(); try await wait("Replay allocator room did not end") { replay.snapshot.phase == .ended }
        await guest.stop()
    }

    static func heldRelayRejoin(configuration: NativeInterviewConfiguration, secret: NativeInterviewSecret) async throws {
        let client = NativeInterviewServiceClient(configuration: configuration, credential: { secret })
        let service = InterviewHeldRelayService(client, configuration: configuration)
        let factory = InterviewBoundaryFactory(), session = NativeInterviewSession(service: service, factory: factory)
        defer { session.shutdown() }
        try await session.create(); let invite = try session.guestInvite(), room = session.snapshot.room!
        try await session.connect(); try await wait("Held relay host not connected") { session.snapshot.phase == .connected }
        let guest = InterviewGuestProbe(socket: try await client.connect(room: room, host: invite)); try await guest.start()
        _ = try await guest.next("welcome"); try await wait("Held relay lobby missing") { !session.snapshot.members.isEmpty }
        try require(session.admit(invite.id), "Held relay admission refused")
        _ = try await guest.next("admitted")
        try await wait("Held relay preparation not occupied") { session.occupiedMediaPreparationCount == 1 }
        let requestDeadline = ContinuousClock.now + .seconds(5)
        while await service.requests == 0 && ContinuousClock.now < requestDeadline { try await Task.sleep(for: .milliseconds(5)) }
        let firstRequests = await service.requests
        try require(firstRequests == 1, "Held relay request did not enter before its fixture deadline")
        session.disconnectForRejoin(); _ = try await guest.next("host-disconnected")
        try await session.connect(); try await wait("Held relay host rejoin missing") { session.snapshot.phase == .connected && !session.snapshot.members.isEmpty }
        let cursor = await guest.count
        try require(session.admit(invite.id), "Held relay readmission refused")
        _ = try await guest.next("admitted", since: cursor)
        try await wait("Old occupied relay request was reused by new connection") { session.snapshot.members.first?.media == .failed && session.snapshot.failure == .busy }
        let requests = await service.requests
        try require(requests == 1 && factory.hosts.isEmpty && session.occupiedMediaPreparationCount == 1,
                    "Host rejoin accumulated held TURN requests or allocated stale native host")
        try await service.release()
        try await wait("Retired relay result kept occupancy") { session.occupiedMediaPreparationCount == 0 }
        try require(factory.hosts.isEmpty, "Late relay reply allocated after its socket epoch retired")
        let offerCursor = await guest.count
        try require(session.restartMedia(invite.id), "Explicit fresh relay restart refused")
        let offer = try await guest.next("signal", kind: "offer", since: offerCursor); try await guest.answer(offer)
        try await wait("Fresh relay restart failed to reach boundary readiness") { session.readyPeerLease(for: invite.id) != nil }
        let finalRequests = await service.requests
        try require(finalRequests == 2 && factory.hosts.count == 1, "Fresh restart replayed provisioning or accumulated native hosts")
        session.end(); try await wait("Held relay room end missing") { session.snapshot.phase == .ended }
        await guest.stop()
    }

    static func injectedBoundaries(configuration: NativeInterviewConfiguration, secret: NativeInterviewSecret) async throws {
        let held = HeldInterviewHTTP()
        let client = NativeInterviewServiceClient(configuration: configuration, credential: { secret }, http: held)
        let jobs = (0..<4).map { _ in Task { try await client.createRoom() } }
        try await wait("Held actual service transport did not occupy four requests") { held.count == 4 }
        let initial = await client.occupiedRequestCount
        try require(initial == 4, "Occupied request bookkeeping differed")
        do { _ = try await client.createRoom(); throw InterviewFixtureError.failed("Fifth held request exceeded admission") }
        catch NativeInterviewError.busy {}
        jobs.forEach { $0.cancel() }
        try await Task.sleep(for: .milliseconds(20))
        let cancelled = await client.occupiedRequestCount
        try require(cancelled == 4 && held.count == 4, "Cancellation released noncooperative occupancy")
        held.release()
        for job in jobs { do { _ = try await job.value; throw InterviewFixtureError.failed("Cancelled creation was accepted") } catch is CancellationError {} }
        let final = await client.occupiedRequestCount
        try require(final == 0, "Completed held reads did not release occupancy")
        await client.shutdown()
        let retiredHTTP = HeldInterviewHTTP(), source = NativeInterviewCredentialSource(secret)
        let retiring = NativeInterviewServiceClient(configuration: configuration, credential: { try source.current() }, http: retiredHTTP)
        let retirementJob = Task { try await retiring.createRoom() }
        try await wait("Credential lifetime request did not enter actual transport") { retiredHTTP.count == 1 }
        source.retire()
        try require(source.isRetired, "Synchronous room retirement retained the credential source")
        do { _ = try source.current(); throw InterviewFixtureError.failed("Retired source allowed a future credential read") }
        catch NativeInterviewError.closed {}
        await retiring.shutdown()
        let hasProvider = await retiring.hasCredentialProvider, remainsOccupied = await retiring.occupiedRequestCount
        try require(!hasProvider && remainsOccupied == 1, "Shutdown retained provider or released noncooperative request occupancy")
        do { _ = try await retiring.createRoom(); throw InterviewFixtureError.failed("Closed client allowed another request") }
        catch NativeInterviewError.closed {}
        try require(retiredHTTP.count == 1, "Credential retirement allocated/replayed an HTTP mutation")
        retiredHTTP.release()
        do { _ = try await retirementJob.value; throw InterviewFixtureError.failed("Retired held mutation accepted its late response") }
        catch NativeInterviewError.closed {}
        let released = await retiring.occupiedRequestCount
        try require(released == 0, "Retired actual transport did not eventually clean occupancy")
        progress("PASS: synchronous credential source retirement + closed client drops provider while actual noncooperative request stays occupied until return")
        let failed = FailedInterviewHTTP()
        let failing = NativeInterviewServiceClient(configuration: configuration, credential: { secret }, http: failed)
        do { _ = try await failing.createRoom(); throw InterviewFixtureError.failed("Failed creation appeared successful") }
        catch NativeInterviewError.transport {}
        try require(failed.count == 1, "Uncertain creation replayed its POST")
        await failing.shutdown()
        do { _ = try NativeInterviewSecret("unsafe\ncredential"); throw InterviewFixtureError.failed("Control-bearing credential accepted") }
        catch NativeInterviewError.authorization {}
        do {
            _ = try NativeInterviewConfiguration(serviceURL: URL(string: "http://interviews.example.test")!,
                allowedOrigin: URL(string: "https://interviews.example.test")!)
            throw InterviewFixtureError.failed("Production configuration accepted plaintext service")
        } catch NativeInterviewError.configuration {}
    }
}
