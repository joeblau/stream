import Combine
import Foundation

/// Service control is separate from Program admission. A server "onair" flag
/// never registers a source, opens an audio gate or starts a publisher.
@MainActor final class NativeInterviewSession: ObservableObject {
    @Published private(set) var snapshot = NativeInterviewSnapshot()
    private let service: any NativeInterviewService
    private let factory: (any NativeInterviewMediaHostFactory)?
    private let clock: @Sendable () -> Date
    private let mediaPreparationTimeout: Duration, negotiationTimeout: Duration
    private let nextGeneration: (@MainActor () -> UInt64?)?
    private var room: NativeInterviewCreatedRoom?
    private var socket: (any NativeInterviewSocketTransport)?
    private var epoch = UUID(), hostGeneration: UUID?
    private var receiveTask: Task<Void, Never>?, expiryTask: Task<Void, Never>?
    private var connectionDeadline: Task<Void, Never>?, endingDeadline: Task<Void, Never>?
    private var relayRefreshTask: Task<Void, Never>?
    private var relayRequest: Task<NativeInterviewRelayConfiguration, Error>?
    private var relayRequestEpoch: UUID?
    private var relay: NativeInterviewRelayConfiguration?
    private var peers: [UUID: Peer] = [:], slots: [UUID: UUID] = [:], admittedGenerations: [UUID: UUID] = [:]
    private var pendingAdmission: UUID?, revoked: Set<UUID> = []
    private var localGeneration: UInt64 = 0
    private var occupiedMedia: Set<UUID> = []
    private var occupiedRequests: Set<UUID> = []
    private var closed = false

    @MainActor private final class Peer {
        let context: NativeInterviewPeerLease
        let mailbox: NativeInterviewMediaMailbox
        var host: (any NativeInterviewMediaHost)?
        var preparation: Task<Void, Never>?, expiry: Task<Void, Never>?, deadline: Task<Void, Never>?
        var incoming: [(NativeInterviewSignal, Int)] = []
        var incomingBytes = 0
        var candidates: [NativeInterviewICECandidate] = [], outbound: [NativeInterviewICECandidate] = []
        var candidateBytes = 0, outboundBytes = 0
        var offered = false, answered = false
        var media: NativeInterviewMediaMIDs?
        init(context: NativeInterviewPeerLease, mailbox: NativeInterviewMediaMailbox) {
            self.context = context; self.mailbox = mailbox
        }
        func retire() {
            mailbox.close(); preparation?.cancel(); expiry?.cancel(); deadline?.cancel()
            host?.retire(); host = nil
            incoming.removeAll(); candidates.removeAll(); outbound.removeAll()
        }
    }

    init(service: any NativeInterviewService, factory: (any NativeInterviewMediaHostFactory)? = nil,
         clock: @escaping @Sendable () -> Date = { Date() },
         mediaPreparationTimeout: Duration = .seconds(15), negotiationTimeout: Duration = .seconds(20),
         nextGeneration: (@MainActor () -> UInt64?)? = nil) {
        self.service = service; self.factory = factory; self.clock = clock
        self.mediaPreparationTimeout = mediaPreparationTimeout; self.negotiationTimeout = negotiationTimeout
        self.nextGeneration = nextGeneration
    }

    func create() async throws {
        guard !closed, room == nil, snapshot.phase == .idle || snapshot.phase == .failed,
              occupiedRequests.isEmpty else { throw NativeInterviewError.busy }
        let attempt = UUID(), current = epoch
        occupiedRequests.insert(attempt); defer { occupiedRequests.remove(attempt) }
        snapshot.phase = .creating; snapshot.failure = nil
        do {
            let created = try await service.createRoom()
            try requireCurrent(current)
            room = created; snapshot.room = created.id; snapshot.expires = created.expires
            snapshot.phase = .disconnected
            scheduleExpiry()
        } catch {
            if current == epoch && !closed { snapshot.phase = .failed; snapshot.failure = safe(error) }
            throw safe(error)
        }
    }

    /// Only an explicit share action obtains a private invite/link.
    func guestInvite() throws -> NativeInterviewInvite {
        guard !closed, let room, room.expires > clock() else { throw NativeInterviewError.expired }
        return room.guest
    }
    func createGuestInvite() async throws -> NativeInterviewInvite {
        guard !closed, let room, room.expires > clock(), occupiedRequests.count < 2 else { throw NativeInterviewError.busy }
        let attempt = UUID(), current = epoch
        occupiedRequests.insert(attempt); defer { occupiedRequests.remove(attempt) }
        let invite = try await service.createInvite(room: room.id)
        try requireCurrent(current)
        guard invite.expires == room.expires else { throw NativeInterviewError.malformed }
        return invite
    }

    /// Rejoin is deliberate. No disconnect automatically reconnects or
    /// replays admission, screen approval, status, offers or room mutations.
    func connect() async throws {
        guard !closed, let room, room.expires > clock(), snapshot.phase != .ending else { throw NativeInterviewError.expired }
        retireConnection(wipe: false)
        let current = epoch
        snapshot.phase = .connecting; snapshot.failure = nil
        do {
            let next = try await service.connect(room: room.id, host: room.host)
            guard current == epoch && !closed else { next.close(); throw NativeInterviewError.changed }
            socket = next
            receiveTask = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        let message = try await next.receive()
                        guard !Task.isCancelled, let self, self.epoch == current else { return }
                        try self.receive(message, epoch: current)
                    } catch {
                        guard !Task.isCancelled, let self, self.epoch == current else { return }
                        self.disconnected(code: next.closeCode, failure: self.safe(error))
                        return
                    }
                }
            }
            guard send(["type": "hello", "name": "Stream native host"], connecting: true) else {
                throw NativeInterviewError.transport
            }
            connectionDeadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self, self.epoch == current, self.snapshot.phase == .connecting else { return }
                self.disconnected(code: nil, failure: .timeout)
            }
            scheduleExpiry()
        } catch {
            if epoch == current { disconnected(code: nil, failure: safe(error)) }
            throw safe(error)
        }
    }
    func disconnectForRejoin() {
        guard !closed else { return }
        retireConnection(wipe: false); snapshot.phase = .disconnected; scheduleExpiry()
    }
    func leave() {
        guard !closed else { return }
        retireConnection(wipe: true); snapshot.phase = .ended
    }
    func shutdown() {
        guard !closed else { return }
        closed = true; retireConnection(wipe: true); snapshot.phase = .closed
        Task { [service] in await service.shutdown() }
    }

    @discardableResult func admit(_ id: UUID) -> Bool {
        guard snapshot.phase == .connected, !revoked.contains(id), pendingAdmission == nil,
              snapshot.members.contains(where: { $0.id == id }), peers[id] == nil,
              peers.isEmpty else { return false }
        guard send(["type": "admit", "id": id.uuidString.lowercased()]) else { return false }
        pendingAdmission = id; return true
    }
    @discardableResult func setMembership(_ membership: NativeInterviewMembership, guest id: UUID) -> Bool {
        guard membership != .waiting, peers[id] != nil else { return false }
        return send(["type": membership == .onair ? "stage" : "backstage", "id": id.uuidString.lowercased()])
    }
    @discardableResult func remove(_ id: UUID) -> Bool {
        guard snapshot.phase == .connected, snapshot.members.contains(where: { $0.id == id }) else { return false }
        // Authority closes synchronously even if the server acknowledgment is
        // late or absent. An old admitted/SDP response cannot resurrect it.
        revoked.insert(id); admittedGenerations[id] = nil; if pendingAdmission == id { pendingAdmission = nil }
        dropPeer(id)
        return send(["type": "revoke", "id": id.uuidString.lowercased()])
    }
    @discardableResult func setLocked(_ value: Bool) -> Bool { send(["type": "lock", "locked": value]) }
    @discardableResult func reportStatus(program: Bool, recording: Bool) -> Bool {
        send(["type": "status", "program": program, "recording": recording])
    }
    @discardableResult func approveScreen(_ approved: Bool, guest id: UUID) -> Bool {
        guard let peer = peers[id], let host = peer.host else { return false }
        if approved {
            guard snapshot.phase == .connected,
                  snapshot.members.first(where: { $0.id == id })?.media == .ready else { return false }
        }
        let sent = host.approveScreen(approved)
        updateMember(id) { $0.screenApproved = sent && approved; if !$0.screenApproved { $0.screenSharing = false } }
        return sent
    }
    /// The UI/manager must compare the entire returned context immediately
    /// before granting local routing. Service membership alone grants nothing.
    func readyPeerLease(for guest: UUID) -> NativeInterviewPeerLease? {
        guard snapshot.phase == .connected, let peer = peers[guest], peer.host != nil,
              snapshot.members.first(where: { $0.id == guest })?.media == .ready else { return nil }
        return peer.context
    }
    @discardableResult func restartMedia(_ id: UUID) -> Bool {
        guard snapshot.phase == .connected, let generation = admittedGenerations[id], !revoked.contains(id),
              occupiedMedia.count < 2 else { return false }
        dropPeer(id)
        _ = send(["type": "signal", "to": id.uuidString.lowercased(),
                  "targetGeneration": generation.uuidString.lowercased(), "kind": "reset", "payload": "{}"])
        return beginPeer(id, generation: generation)
    }

    /// Stop local media first, then observe the service's actual ended receipt.
    func end() {
        guard snapshot.phase == .connected else { return }
        for id in Array(peers.keys) { dropPeer(id) }
        let sent = send(["type": "end"])
        snapshot.phase = .ending
        if !sent { retireConnection(wipe: true); snapshot.phase = .ended; snapshot.failure = .uncertainMutation; return }
        let current = epoch
        endingDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.epoch == current, self.snapshot.phase == .ending else { return }
            self.retireConnection(wipe: true); self.snapshot.phase = .ended; self.snapshot.failure = .uncertainMutation
        }
    }
    func endUsingOperatorAuthorization() async throws {
        guard !closed, let id = snapshot.room, occupiedRequests.count < 2 else { throw NativeInterviewError.busy }
        let attempt = UUID(); occupiedRequests.insert(attempt); defer { occupiedRequests.remove(attempt) }
        retireConnection(wipe: true); let current = epoch; snapshot.phase = .ending
        do {
            try await service.endRoom(id); try requireCurrent(current)
            snapshot.phase = .ended; snapshot.failure = nil
        } catch {
            if epoch == current && !closed { snapshot.phase = .ended; snapshot.failure = safe(error) }
            throw safe(error)
        }
    }

    private func receive(_ text: String, epoch current: UUID) throws {
        guard current == epoch, let data = text.data(using: .utf8) else { return }
        let object = try NativeInterviewWire.object(data)
        let delivery = try NativeInterviewWire.number(object["delivery"])
        guard delivery > 0, delivery.rounded() == delivery, delivery <= 9_007_199_254_740_991 else {
            throw NativeInterviewError.malformed
        }
        // ACK before any asynchronous factory, TURN, SDP or candidate work.
        guard send(["type": "ack", "delivery": Int64(delivery)], acknowledgment: true, connecting: true) else {
            throw NativeInterviewError.capacity
        }
        guard let type = object["type"] as? String else { throw NativeInterviewError.malformed }
        if type == "ended" {
            retireConnection(wipe: true); snapshot.phase = .ended; snapshot.failure = nil; return
        }
        if snapshot.phase == .ending { return }
        switch type {
        case "welcome":
            guard snapshot.phase == .connecting, hostGeneration == nil,
                  let room, object["role"] as? String == "host",
                  try NativeInterviewWire.id(object["id"]) == room.host.id,
                  try NativeInterviewWire.number(object["expires"]) / 1_000 == room.expires.timeIntervalSince1970,
                  room.expires > clock() else { throw NativeInterviewError.authorization }
            hostGeneration = try NativeInterviewWire.id(object["generation"])
            snapshot.phase = .connected; connectionDeadline?.cancel(); scheduleExpiry()
        case "roster":
            guard let values = object["peers"] as? [[String: Any]], values.count <= 11 else { throw NativeInterviewError.malformed }
            let locked = try NativeInterviewWire.boolean(object["locked"])
            let program = try NativeInterviewWire.boolean(object["program"])
            let recording = try NativeInterviewWire.boolean(object["recording"])
            var members: [NativeInterviewMember] = [], seen: Set<UUID> = []
            for value in values {
                let id = try NativeInterviewWire.id(value["id"])
                guard seen.insert(id).inserted, let role = value["role"] as? String, ["host", "guest"].contains(role),
                      let name = value["name"] as? String, name.utf16.count <= 80,
                      let text = value["state"] as? String, let state = NativeInterviewMembership(rawValue: text) else {
                    throw NativeInterviewError.malformed
                }
                if role == "guest" {
                    var member = snapshot.members.first { $0.id == id } ?? .init(id: id, name: name, membership: state)
                    member = .init(id: id, name: name, membership: state, media: member.media,
                                   screenApproved: member.screenApproved, screenSharing: member.screenSharing)
                    if state == .waiting {
                        member.media = .unavailable; member.screenApproved = false; member.screenSharing = false
                    }
                    members.append(member)
                }
            }
            for id in Array(peers.keys) where !members.contains(where: { $0.id == id && $0.membership != .waiting }) { dropPeer(id) }
            for id in Array(admittedGenerations.keys) where !members.contains(where: { $0.id == id && $0.membership != .waiting }) {
                admittedGenerations[id] = nil
            }
            if let pendingAdmission, !members.contains(where: { $0.id == pendingAdmission }) { self.pendingAdmission = nil }
            snapshot.members = members
            snapshot.locked = locked; snapshot.program = program; snapshot.recording = recording
        case "admitted":
            guard snapshot.phase == .connected else { return }
            let id = try NativeInterviewWire.id(object["guest"]), generation = try NativeInterviewWire.id(object["guestGeneration"])
            guard !revoked.contains(id), snapshot.members.contains(where: { $0.id == id }),
                  let state = object["state"] as? String, let membership = NativeInterviewMembership(rawValue: state),
                  membership != .waiting else { return }
            if pendingAdmission == id { pendingAdmission = nil }
            admittedGenerations[id] = generation
            updateMember(id) { $0.membership = membership }
            if peers[id]?.context.guestGeneration != generation {
                dropPeer(id); _ = beginPeer(id, generation: generation)
            }
        case "signal":
            let id = try NativeInterviewWire.id(object["from"])
            guard let peer = peers[id], !revoked.contains(id),
                  try NativeInterviewWire.id(object["generation"]) == peer.context.guestGeneration,
                  try NativeInterviewWire.id(object["targetGeneration"]) == hostGeneration,
                  let kind = object["kind"] as? String, let payload = object["payload"] as? String else { return }
            let signal: NativeInterviewSignal
            do {
                guard let decoded = try NativeInterviewWire.signal(kind: kind, payload: payload,
                    expectedNegotiation: peer.context.receive.negotiation) else { return }
                signal = decoded
            }
            catch { failPeer(id, safe(error)); return }
            if peer.host == nil {
                guard peer.incoming.count < 32, peer.incomingBytes + payload.utf8.count <= 196_608 else {
                    failPeer(id, .capacity); return
                }
                peer.incoming.append((signal, payload.utf8.count)); peer.incomingBytes += payload.utf8.count
            } else { accept(signal, peer: peer) }
        case "error":
            pendingAdmission = nil; snapshot.failure = .authorization
        case "pong": break
        default: throw NativeInterviewError.malformed
        }
    }

    private func beginPeer(_ id: UUID, generation: UUID) -> Bool {
        guard peers.isEmpty, let room, let hostGeneration, snapshot.phase == .connected,
              occupiedMedia.count < 2, slots.count < 128 || slots[id] != nil,
              localGeneration < UInt64.max else { updateMember(id) { $0.media = .failed }; return false }
        let issuedGeneration: UInt64
        if let nextGeneration {
            guard let allocated = nextGeneration(), allocated > localGeneration else {
                updateMember(id) { $0.media = .failed }; snapshot.failure = .capacity; return false
            }
            issuedGeneration = allocated
        } else { issuedGeneration = localGeneration + 1 }
        localGeneration = issuedGeneration
        let slot = slots[id] ?? UUID(); slots[id] = slot
        let context = NativeInterviewPeerLease(room: room.id, hostGeneration: hostGeneration, guestGeneration: generation,
            receive: .init(slot: slot, peerID: id, negotiation: UUID(), generation: localGeneration))
        let current = epoch
        let mailbox = NativeInterviewMediaMailbox { [weak self] events, overflow in
            guard let self, self.epoch == current, self.peers[id]?.context == context else { return }
            if overflow { self.failPeer(id, .capacity); return }
            for event in events { self.media(event, id: id, context: context) }
        }
        let peer = Peer(context: context, mailbox: mailbox); peers[id] = peer
        guard let factory else { updateMember(id) { $0.media = .unavailable }; return true }
        updateMember(id) { $0.media = .preparing }
        let attempt = UUID(); occupiedMedia.insert(attempt)
        setMediaDeadline(peer, after: mediaPreparationTimeout, epoch: current)
        peer.preparation = Task { [weak self] in
            guard let self else { return }
            defer { self.occupiedMedia.remove(attempt) }
            do {
                let relay = try await self.relayConfiguration(epoch: current)
                try self.requireCurrent(current)
                guard self.peers[id] === peer else { throw NativeInterviewError.changed }
                let host = try await factory.makeHost(context: context, relay: relay, events: { mailbox.append($0) })
                guard current == self.epoch, !self.closed, self.peers[id] === peer, !Task.isCancelled else {
                    host.retire(); throw NativeInterviewError.changed
                }
                peer.host = host; try host.startHost()
                self.updateMember(id) { $0.media = .negotiating }
                self.setMediaDeadline(peer, after: self.negotiationTimeout, epoch: current)
                let queued = peer.incoming; peer.incoming.removeAll(); peer.incomingBytes = 0
                for (signal, _) in queued { self.accept(signal, peer: peer) }
                peer.expiry = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(max(0, relay.expires.timeIntervalSince(self?.clock() ?? Date()))))
                    guard !Task.isCancelled, let self, self.epoch == current, self.peers[id] === peer else { return }
                    self.failPeer(id, .expired)
                }
            } catch {
                if self.epoch == current, self.peers[id] === peer { self.failPeer(id, self.safe(error)) }
            }
        }
        return true
    }
    private func media(_ event: NativeInterviewMediaEvent, id: UUID, context: NativeInterviewPeerLease) {
        guard let peer = peers[id], peer.context == context, snapshot.phase == .connected else { return }
        switch event {
        case .offer(let sdp, let media):
            guard !peer.offered, NativeInterviewWire.validSDP(sdp) else { failPeer(id, .malformed); return }
            peer.media = media
            guard signal(peer, kind: "offer", payload: ["description": ["type": "offer", "sdp": sdp],
                "media": ["audio": media.audio, "camera": media.camera, "screen": media.screen]]) else { failPeer(id, .capacity); return }
            peer.offered = true
            let candidates = peer.outbound; peer.outbound.removeAll(); peer.outboundBytes = 0
            for candidate in candidates { outbound(candidate, peer: peer) }
        case .candidate(let value, let mid):
            guard let candidate = try? NativeInterviewICECandidate(value: value, mid: mid) else { failPeer(id, .malformed); return }
            if peer.offered { outbound(candidate, peer: peer) }
            else {
                guard peer.outbound.count < 128, peer.outboundBytes + value.utf8.count + mid.utf8.count <= 196_608 else { failPeer(id, .capacity); return }
                peer.outbound.append(candidate); peer.outboundBytes += value.utf8.count + mid.utf8.count
            }
        case .ready:
            guard peer.offered, peer.answered else { failPeer(id, .malformed); return }
            peer.deadline?.cancel(); peer.deadline = nil
            updateMember(id) { $0.media = .ready }
        case .screenSharing(let value): updateMember(id) { $0.screenSharing = value && $0.screenApproved }
        case .controlClosed: updateMember(id) { $0.screenApproved = false; $0.screenSharing = false }
        case .failed(let failure): failPeer(id, failure)
        }
    }
    private func setMediaDeadline(_ peer: Peer, after timeout: Duration, epoch current: UUID) {
        peer.deadline?.cancel()
        peer.deadline = Task { [weak self, weak peer] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, let peer, self.epoch == current,
                  self.peers[peer.context.receive.peerID] === peer else { return }
            self.failPeer(peer.context.receive.peerID, .timeout)
        }
    }
    private func accept(_ signal: NativeInterviewSignal, peer: Peer) {
        guard peers[peer.context.receive.peerID] === peer, let host = peer.host else { return }
        switch signal {
        case .reset: failPeer(peer.context.receive.peerID, .changed)
        case .answer(let negotiation, let sdp):
            guard negotiation == peer.context.receive.negotiation, peer.offered, !peer.answered else { return }
            do {
                try host.acceptAnswer(sdp); peer.answered = true
                let candidates = peer.candidates; peer.candidates.removeAll(); peer.candidateBytes = 0
                for candidate in candidates { apply(candidate, host: host) }
            } catch { failPeer(peer.context.receive.peerID, safe(error)) }
        case .candidate(let negotiation, let candidate):
            guard negotiation == peer.context.receive.negotiation, peer.offered else { return }
            if peer.answered { apply(candidate, host: host) }
            else {
                guard peer.candidates.count < 128, peer.candidateBytes + candidate.value.utf8.count + candidate.mid.utf8.count <= 196_608 else {
                    failPeer(peer.context.receive.peerID, .capacity); return
                }
                peer.candidates.append(candidate); peer.candidateBytes += candidate.value.utf8.count + candidate.mid.utf8.count
            }
        }
    }
    private func apply(_ candidate: NativeInterviewICECandidate, host: any NativeInterviewMediaHost) {
        do { try host.acceptCandidate(candidate.value, mid: candidate.mid) }
        catch { snapshot.failure = safe(error) } // Candidate failure cannot suppress a valid answer.
    }
    private func outbound(_ candidate: NativeInterviewICECandidate, peer: Peer) {
        if !signal(peer, kind: "candidate", payload: ["candidate": ["candidate": candidate.value, "sdpMid": candidate.mid]]) {
            failPeer(peer.context.receive.peerID, .capacity)
        }
    }
    private func signal(_ peer: Peer, kind: String, payload: [String: Any]) -> Bool {
        guard peers[peer.context.receive.peerID] === peer else { return false }
        var payload = payload; payload["negotiation"] = peer.context.receive.negotiation.uuidString.lowercased()
        guard let data = try? JSONSerialization.data(withJSONObject: payload), data.count <= 60_000,
              let text = String(data: data, encoding: .utf8) else { return false }
        return send(["type": "signal", "to": peer.context.receive.peerID.uuidString.lowercased(),
                     "targetGeneration": peer.context.guestGeneration.uuidString.lowercased(), "kind": kind, "payload": text])
    }

    private func relayConfiguration(epoch current: UUID) async throws -> NativeInterviewRelayConfiguration {
        if let relay, relay.expires > clock(), relay.refreshAt > clock() { return relay }
        if let relayRequest {
            guard relayRequestEpoch == current else { throw NativeInterviewError.busy }
            let value = try await relayRequest.value; try requireCurrent(current); return value
        }
        guard let room, snapshot.phase == .connected else { throw NativeInterviewError.changed }
        let task = Task { [service] in try await service.relay(room: room.id, host: room.host) }
        relayRequest = task; relayRequestEpoch = current
        defer { relayRequest = nil; relayRequestEpoch = nil }
        let value = try await task.value; try requireCurrent(current)
        guard value.expires > clock(), value.refreshAt > clock() else { throw NativeInterviewError.expired }
        relay = value
        relayRefreshTask?.cancel()
        relayRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, value.refreshAt.timeIntervalSince(self?.clock() ?? Date()))))
            guard !Task.isCancelled, let self, self.epoch == current, self.snapshot.phase == .connected else { return }
            do { _ = try await self.relayConfiguration(epoch: current) }
            catch { if self.epoch == current { self.snapshot.failure = self.safe(error) } }
        }
        return value
    }
    private func send(_ object: [String: Any], acknowledgment: Bool = false, connecting: Bool = false) -> Bool {
        guard !closed, connecting || snapshot.phase == .connected, let socket,
              let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 60_000,
              let text = String(data: data, encoding: .utf8) else { return false }
        return socket.send(text, acknowledgment: acknowledgment)
    }
    private func scheduleExpiry() {
        expiryTask?.cancel(); guard let room else { return }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, room.expires.timeIntervalSince(self?.clock() ?? Date()))))
            guard !Task.isCancelled, let self, self.room?.id == room.id else { return }
            self.retireConnection(wipe: true); self.snapshot.phase = .expired; self.snapshot.failure = .expired
        }
    }
    private func disconnected(code: Int?, failure: NativeInterviewError) {
        let terminal = [4000, 4001, 4003].contains(code ?? 0)
        retireConnection(wipe: terminal); snapshot.phase = terminal ? .ended : .disconnected
        snapshot.failure = failure
        if !terminal { scheduleExpiry() }
    }
    private func retireConnection(wipe: Bool) {
        epoch = UUID(); receiveTask?.cancel(); connectionDeadline?.cancel(); endingDeadline?.cancel()
        expiryTask?.cancel(); relayRefreshTask?.cancel(); relayRequest?.cancel()
        socket?.close(); socket = nil; hostGeneration = nil; pendingAdmission = nil; admittedGenerations.removeAll()
        for id in Array(peers.keys) { dropPeer(id) }
        snapshot.members.removeAll(); snapshot.program = false; snapshot.recording = false; snapshot.locked = false
        if wipe { room = nil; relay = nil; slots.removeAll(); revoked.removeAll() }
        // The actual relay read remains retained until its task returns.
    }
    private func dropPeer(_ id: UUID) {
        peers.removeValue(forKey: id)?.retire()
        updateMember(id) { $0.media = .unavailable; $0.screenApproved = false; $0.screenSharing = false }
    }
    private func failPeer(_ id: UUID, _ failure: NativeInterviewError) {
        dropPeer(id); updateMember(id) { $0.media = .failed }; snapshot.failure = failure
    }
    private func updateMember(_ id: UUID, _ update: (inout NativeInterviewMember) -> Void) {
        if let index = snapshot.members.firstIndex(where: { $0.id == id }) { update(&snapshot.members[index]) }
    }
    private func requireCurrent(_ current: UUID) throws {
        guard current == epoch, !closed, !Task.isCancelled else { throw NativeInterviewError.changed }
    }
    private func safe(_ error: any Error) -> NativeInterviewError {
        if let error = error as? NativeInterviewError { return error }
        return error is CancellationError ? .cancelled : .transport
    }
    var occupiedMediaPreparationCount: Int { occupiedMedia.count }
}

/// Native callback threads retain bounded work and schedule one actor drain.
/// They never create an unbounded Task for each SDP/ICE/control callback.
private final class NativeInterviewMediaMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [NativeInterviewMediaEvent] = []
    private var bytes = 0, working = false, closed = false, overflow = false
    private let consume: @MainActor @Sendable ([NativeInterviewMediaEvent], Bool) -> Void
    init(consume: @escaping @MainActor @Sendable ([NativeInterviewMediaEvent], Bool) -> Void) { self.consume = consume }
    func append(_ event: NativeInterviewMediaEvent) -> Bool {
        lock.lock()
        guard !closed else { lock.unlock(); return false }
        let accepted = events.count < 32 && bytes + event.byteCount <= 196_608
        if accepted { events.append(event); bytes += event.byteCount } else { overflow = true }
        let start = !working; working = true; lock.unlock()
        if start { Task { @MainActor [weak self] in self?.drain() } }
        return accepted
    }
    @MainActor private func drain() {
        let batch = take()
        consume(batch.0, batch.1)
    }
    private func take() -> ([NativeInterviewMediaEvent], Bool) {
        lock.lock(); defer { lock.unlock() }
        let result = (events, overflow)
        events.removeAll(); bytes = 0; working = false; overflow = false
        return closed ? ([], false) : result
    }
    func close() { lock.lock(); closed = true; events.removeAll(); bytes = 0; lock.unlock() }
}
