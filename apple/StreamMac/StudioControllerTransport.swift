import CoreMIDI
import Foundation
import Network

/// CoreMIDI callbacks copy bounded values into one mailbox. No rendering,
/// command dispatch, or unbounded task queue runs on its real-time thread.
private final class StudioMIDIMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [StudioMIDIEvent] = []
    private var scheduled = false
    private var active = true
    let receive: @MainActor @Sendable ([StudioMIDIEvent]) -> Void
    init(receive: @escaping @MainActor @Sendable ([StudioMIDIEvent]) -> Void) { self.receive = receive }
    func append(_ values: [StudioMIDIEvent]) {
        lock.lock()
        guard active else { lock.unlock(); return }
        events.append(contentsOf: values.prefix(max(0, 256 - events.count)))
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        if schedule { Task { @MainActor in self.receive(self.drain()) } }
    }
    private func drain() -> [StudioMIDIEvent] {
        lock.lock(); defer { lock.unlock() }
        let result = active ? events : []
        events.removeAll(keepingCapacity: true); scheduled = false
        return result
    }
    func cancel() { lock.lock(); active = false; events.removeAll(); lock.unlock() }
}

@MainActor final class StudioMIDITransport {
    struct Endpoint: Identifiable, Equatable { var id: Int32; var name: String; var ref: MIDIEndpointRef }
    private var client = MIDIClientRef(), input = MIDIPortRef(), output = MIDIPortRef()
    private var connected = MIDIEndpointRef()
    private var mailbox: StudioMIDIMailbox?
    private var sourceID: Int32 = 0
    private var destinationID: Int32 = 0
    private(set) var status = "Disabled"
    var receive: ([StudioMIDIEvent]) -> Void = { _ in }
    nonisolated private static func notificationBlock() -> MIDINotifyBlock { { _ in } }
    nonisolated private static func receiveBlock(mailbox: StudioMIDIMailbox, sourceID: Int32) -> MIDIReceiveBlock {
        // Construct this legacy callback outside MainActor isolation. Merely
        // capturing Sendable values inside start() otherwise inserts a Swift
        // executor assertion on CoreMIDI's real-time thread.
        { list, _ in
            guard list.pointee.protocol == ._1_0 else { return }
            let packets = UnsafeRawPointer(list).advanced(by: MemoryLayout<MIDIEventList>.offset(of: \MIDIEventList.packet)!).assumingMemoryBound(to: MIDIEventPacket.self)
            var packet = packets
            for _ in 0..<min(list.pointee.numPackets, 256) {
                let words = UnsafeRawPointer(packet).advanced(by: MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words)!).assumingMemoryBound(to: UInt32.self)
                let copied = Array(UnsafeBufferPointer(start: words, count: min(Int(packet.pointee.wordCount), 1024)))
                mailbox.append(StudioMIDIEvent.decode(words: copied, sourceID: sourceID))
                packet = UnsafePointer(MIDIEventPacketNext(packet))
            }
        }
    }
    static func endpoints(destinations: Bool = false) -> [Endpoint] {
        let count = destinations ? MIDIGetNumberOfDestinations() : MIDIGetNumberOfSources()
        var result: [Endpoint] = []
        for index in 0..<count {
            let endpoint = destinations ? MIDIGetDestination(index) : MIDIGetSource(index)
            var uniqueID: Int32 = 0, name: Unmanaged<CFString>?
            guard MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID) == noErr, uniqueID != 0 else { continue }
            MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
            result.append(.init(id: uniqueID, name: name?.takeRetainedValue() as String? ?? "MIDI \(uniqueID)", ref: endpoint))
        }
        return result
    }
    func start(sourceID: Int32, destinationID: Int32 = 0) {
        stop(); self.sourceID = sourceID; self.destinationID = destinationID
        guard sourceID != 0 else { status = "Choose a MIDI source"; return }
        guard MIDIClientCreateWithBlock("Stream Controllers" as CFString, &client, Self.notificationBlock()) == noErr else { status = "Could not create MIDI client"; return }
        let mailbox = StudioMIDIMailbox { [weak self] values in self?.receive(values) }
        self.mailbox = mailbox
        let result = MIDIInputPortCreateWithProtocol(client, "Stream Input" as CFString, ._1_0, &input, Self.receiveBlock(mailbox: mailbox, sourceID: sourceID))
        guard result == noErr else { stop(); status = "Could not create MIDI input (\(result))"; return }
        if destinationID != 0 { MIDIOutputPortCreate(client, "Stream Feedback" as CFString, &output) }
        status = "Disconnected · waiting for source \(sourceID)"
        refresh()
    }
    @discardableResult func refresh() -> Bool {
        guard client != 0 else { return false }
        let source = Self.endpoints().first { $0.id == sourceID }?.ref ?? 0
        guard source != connected else { return false }
        if connected != 0 { MIDIPortDisconnectSource(input, connected) }
        connected = 0
        if source != 0, MIDIPortConnectSource(input, source, nil) == noErr { connected = source }
        status = connected == 0 ? "Disconnected · waiting for source \(sourceID)" : "Connected · \(Self.endpoints().first { $0.id == sourceID }?.name ?? "MIDI")"
        return true
    }
    func send(address: StudioMIDIAddress, channel: UInt8, value: UInt8) {
        guard output != 0, destinationID != 0, destinationID != sourceID,
              let destination = Self.endpoints(destinations: true).first(where: { $0.id == destinationID })?.ref else { return }
        let status: UInt32 = address.kind == .note ? 9 : 11
        var word = UInt32(2) << 28 | UInt32(address.group) << 24 | status << 20 | UInt32(channel) << 16 | UInt32(address.number) << 8 | UInt32(value)
        let capacity = max(1024, MemoryLayout<MIDIEventList>.size)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<MIDIEventList>.alignment)
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: MIDIEventList.self, capacity: 1)
        let packet = MIDIEventListInit(list, ._1_0)
        MIDIEventListAdd(list, capacity, packet, 0, 1, &word)
        MIDISendEventList(output, destination, list)
    }
    func stop() {
        mailbox?.cancel(); mailbox = nil
        if input != 0 { MIDIPortDispose(input) }; if output != 0 { MIDIPortDispose(output) }
        if client != 0 { MIDIClientDispose(client) }
        input = 0; output = 0; client = 0; connected = 0; status = "Disabled"
    }
}

@MainActor final class StudioOSCTransport {
    private struct Peer { let connection: NWConnection; var lastSeen: TimeInterval; var count = 0; var window: TimeInterval = 0 }
    private var listener: NWListener?
    private var generation = UUID()
    private var peers: [UUID: Peer] = [:]
    private var feedback: NWConnection?
    private var pendingFeedback = 0
    private(set) var listeningPort: UInt16?
    private(set) var status = "Disabled"
    var receive: ([StudioOSC.Message]) -> Void = { _ in }
    var rejected: (String) -> Void = { _ in }
    func start(port: UInt16, feedbackPort: UInt16 = 0) {
        stop()
        let current = generation
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        do {
            let listener = try NWListener(using: parameters)
            self.listener = listener; status = "Starting local OSC"
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self, self.generation == current else { return }
                    switch state {
                    case .ready: self.listeningPort = listener.port?.rawValue; self.status = "Listening · 127.0.0.1:\(self.listeningPort ?? port)"
                    case .failed(let error): self.stop(); self.status = "OSC unavailable: \(error.localizedDescription)"
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated {
                    guard let self, self.generation == current, self.peers.count < 8,
                          case .hostPort(let host, _) = connection.endpoint, host == .ipv4(.loopback) else { connection.cancel(); return }
                    let id = UUID()
                    self.peers[id] = Peer(connection: connection, lastSeen: ProcessInfo.processInfo.systemUptime)
                    connection.start(queue: .main); self.read(id, generation: current)
                }
            }
            listener.start(queue: .main)
            if feedbackPort != 0, feedbackPort != port {
                feedback = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: feedbackPort)!, using: .udp)
                feedback?.start(queue: .main)
            }
        } catch { status = "OSC unavailable: \(error.localizedDescription)" }
    }
    private func read(_ id: UUID, generation: UUID) {
        guard let peer = peers[id] else { return }
        peer.connection.receiveMessage { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation, var peer = self.peers[id] else { return }
                guard error == nil else { self.peers.removeValue(forKey: id)?.connection.cancel(); return }
                let now = ProcessInfo.processInfo.systemUptime
                if now - peer.window >= 1 { peer.window = now; peer.count = 0 }
                peer.lastSeen = now; peer.count += 1; self.peers[id] = peer
                if peer.count <= 30, let data {
                    do { self.receive(try StudioOSC.decode(data)) }
                    catch { self.rejected(error.localizedDescription) }
                }
                self.read(id, generation: generation)
            }
        }
    }
    func refresh() {
        let now = ProcessInfo.processInfo.systemUptime
        for (id, peer) in peers where now - peer.lastSeen > 10 { peer.connection.cancel(); peers.removeValue(forKey: id) }
    }
    @discardableResult func send(address: String, value: Double) -> Bool {
        guard let feedback, pendingFeedback < 32 else { return false }
        pendingFeedback += 1
        let current = generation
        feedback.send(content: StudioOSC.encode(address: address, value: value), completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.pendingFeedback -= 1
            }
        })
        return true
    }
    func stop() {
        generation = UUID(); listener?.cancel(); listener = nil; listeningPort = nil
        peers.values.forEach { $0.connection.cancel() }; peers.removeAll()
        feedback?.cancel(); feedback = nil; pendingFeedback = 0; status = "Disabled"
    }
}
