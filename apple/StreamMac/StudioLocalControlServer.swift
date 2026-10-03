import Combine
import Foundation
import Network

@MainActor final class StudioLocalControlServer: ObservableObject {
    static let port: UInt16 = 32145
    @Published private(set) var enabled: Bool
    @Published private(set) var status = "Disabled"
    @Published private(set) var connectedClients = 0
    @Published private(set) var listeningPort: UInt16?
    private let configuredPort: UInt16
    let pairingStore: StudioControlPairingStore
    private let defaults: UserDefaults
    private var listener: NWListener?
    private var listenerID: UUID?
    private var peers: [UUID: Peer] = [:]
    private var stateObservation: AnyCancellable?
    private var eventTask: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var lastBroadcastRevision: UInt64 = 0
    private var lastSnapshot: StudioControlSnapshot?
    private var lastCapabilities: [StudioControlCapability] = []
    private var snapshot: () -> StudioControlSnapshot = { .init(projectID: "", stream: "idle", recording: "idle", preview: "idle", pendingStagedEdits: false, layerVisibility: [:], macroProgress: .init()) }
    private var capabilities: () -> [StudioControlCapability] = { [] }
    private var execute: (String, Double?, Double?, Int?, String?) -> StudioControlCommandResult = { id, _, _, _, _ in .init(commandID: id, succeeded: false, error: .init(code: "unavailable", message: "No studio is bound.")) }
    private var cancelledRemoteRun: (UUID) -> Void = { _ in }
    private var currentRunID: () -> UUID? = { nil }
    var interactionBlocked: () -> Bool = { false }
    /// Optional external-adapter grants, checked after authentication and
    /// before every command. Returning nil leaves normal paired clients alone.
    var clientAuthorization: (UUID, String?) -> StudioControlProtocolError? = { _, _ in nil }
    var authenticatedClientIDs: Set<UUID> { Set(peers.values.compactMap { $0.session.clientID }) }
    private final class Peer {
        let id = UUID()
        let connection: NWConnection
        var session = StudioControlSession()
        var buffer = StudioControlFrameBuffer()
        var subscribed = false
        var closing = false
        var pendingSends = 0
        var ownedMacroRun: UUID?
        var rateWindowStart = ProcessInfo.processInfo.systemUptime
        var requestsInWindow = 0
        var handshakeTimeout: Task<Void, Never>?
        init(_ connection: NWConnection) { self.connection = connection }
    }
    init(defaults: UserDefaults = .standard, pairingStore: StudioControlPairingStore? = nil, port: UInt16 = 32145) {
        self.defaults = defaults
        self.configuredPort = port
        self.pairingStore = pairingStore ?? StudioControlPairingStore()
        enabled = defaults.bool(forKey: "studio.localControl.enabled")
    }
    func bind(to dispatcher: StudioCommandDispatcher) {
        let boundProjectDirectory = DesktopStorage.projectDirectory
        capabilities = { [weak dispatcher] in
            var result: [StudioControlCapability] = dispatcher?.catalogueActions().map { .init(id: $0.id, title: $0.title, category: $0.category,
                                                      available: $0.command != nil && $0.unavailableReason == nil,
                                                      unavailableReason: $0.unavailableReason, kind: "command",
                                                      argument: $0.id == "output.record.marker" ? "text" : $0.id.hasPrefix("pdf.") && $0.id.hasSuffix(".goto") ? "page" : nil) } ?? []
            for target in dispatcher?.controllerTargets() ?? [] where target.kind == .value {
                result.append(.init(id: target.id, title: target.title, category: "Audio Levels", available: target.unavailableReason == nil, unavailableReason: target.unavailableReason, kind: "value"))
            }
            return result
        }
        snapshot = { [weak dispatcher] in
            guard let dispatcher else { return .init(projectID: "", stream: "idle", recording: "idle", preview: "idle", pendingStagedEdits: false, layerVisibility: [:], macroProgress: .init()) }
            let state = dispatcher.state
            return .init(projectID: boundProjectDirectory.lastPathComponent,
                         stream: Self.streamLabel(state.stream), recording: Self.recordingLabel(state.recording),
                         preview: state.preview == .active ? "active" : "idle", stagedSceneID: state.stagedSceneID?.rawValue,
                         programSceneID: state.programSceneID?.rawValue, pendingStagedEdits: state.hasPendingStagedEdits,
                         layerVisibility: Dictionary(uniqueKeysWithValues: state.layerVisibility.map { ($0.key.rawValue.uuidString, $0.value) }),
                         macroProgress: dispatcher.macros.progress, values: dispatcher.controllerValueSnapshot(), mutes: dispatcher.controllerMuteSnapshot(),
                         playback: dispatcher.controllerPlaybackSnapshot(), programLayerVisibility: dispatcher.controllerProgramVisibility(),
                         groupVisibility: dispatcher.controllerGroupVisibility(),
                         overlayVisibility: Dictionary(uniqueKeysWithValues: dispatcher.controllerOverlays().map { ($0.id.rawValue.uuidString, $0.isVisible) }),
                         directLiveEditing: state.directLiveEditing, chat: dispatcher.controllerChatSnapshot(),
                         interview: .init(phase: state.interview.snapshot.phase.rawValue, room: state.interview.snapshot.room,
                            locked: state.interview.snapshot.locked, members: state.interview.snapshot.members.map { member in
                                let route = state.interview.routes[member.id]
                                return .init(id: member.id, name: member.name, membership: member.membership.rawValue,
                                    media: member.media.rawValue, slot: route?.slot, programAllowed: route?.programAllowed ?? false,
                                    monitorAllowed: route?.monitorAllowed ?? false, screenApproved: member.screenApproved, screenSharing: member.screenSharing)
                            }))
        }
        execute = { [weak self, weak dispatcher] id, value, delta, page, text in
            guard let self, let dispatcher else { return .init(commandID: id, succeeded: false, error: .init(code: "unavailable", message: "The studio is unavailable.")) }
            guard DesktopStorage.projectDirectory == boundProjectDirectory, !self.interactionBlocked() else { return .init(commandID: id, succeeded: false, error: .init(code: "unavailable", message: "Complete the studio's setup or permission choice before running remote commands.")) }
            if let target = dispatcher.controllerTargets().first(where: { $0.id == id && $0.kind == .value }) {
                guard value != nil || delta != nil else { return .init(commandID: id, succeeded: false, error: .init(code: "invalidValue", message: "This numeric target needs a normalized value or delta.")) }
                if let error = target.unavailableReason { return .init(commandID: id, succeeded: false, error: .init(code: "unavailable", message: error)) }
                let normalized = value ?? max(0, min(1, target.normalizedValue + delta!))
                let error = target.execute(normalized)
                return .init(commandID: id, succeeded: error == nil, error: error.map { .init(code: "unavailable", message: $0) })
            }
            guard value == nil, delta == nil else {
                let exists = dispatcher.catalogueActions().contains(where: { $0.id == id })
                return .init(commandID: id, succeeded: false, error: .init(code: exists ? "invalidValue" : "invalidTarget", message: "Numeric arguments require an existing typed value target."))
            }
            guard let action = dispatcher.catalogueActions().first(where: { $0.id == id }) else {
                return .init(commandID: id, succeeded: false, error: .init(code: "invalidTarget", message: "The stable command/resource ID no longer exists."))
            }
            guard var command = action.command else { return .init(commandID: id, succeeded: false, error: .init(code: "unavailable", message: action.unavailableReason ?? "This action is unavailable.")) }
            if let page {
                guard id.hasPrefix("pdf."), id.hasSuffix(".goto"), case .pdfGoToPage(let sourceID, _) = command else { return .init(commandID: id, succeeded: false, error: .init(code: "invalidValue", message: "A page argument requires a PDF jump target.")) }
                command = .pdfGoToPage(sourceID, page: page)
            }
            if let text {
                guard id == "output.record.marker", case .addRecordingMarker = command else { return .init(commandID: id, succeeded: false, error: .init(code: "invalidValue", message: "A text argument requires the recording marker command.")) }
                command = .addRecordingMarker(text)
            }
            let result = dispatcher.execute(command)
            if case .rejected(let error) = result.outcome {
                let code: String
                switch error { case .unavailable: code = "unavailable"; case .invalidTarget: code = "invalidTarget"; case .invalidValue: code = "invalidValue" }
                return .init(commandID: id, succeeded: false, error: .init(code: code, message: error.description))
            }
            return .init(commandID: id, succeeded: true)
        }
        currentRunID = { [weak dispatcher] in dispatcher?.macros.isRunning == true ? dispatcher?.macros.progress.runID : nil }
        cancelledRemoteRun = { [weak dispatcher] runID in
            if dispatcher?.macros.progress.runID == runID { dispatcher?.macros.cancel() }
        }
        stateObservation = dispatcher.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleEvent() }
        }
        if enabled { start() }
    }
    func setEnabled(_ value: Bool) {
        enabled = value; defaults.set(value, forKey: "studio.localControl.enabled")
        if value { start() } else { stop() }
    }
    func revoke(_ clientID: UUID) {
        guard pairingStore.revoke(clientID) else { return }
        disconnectClient(clientID)
    }
    func disconnectClient(_ clientID: UUID) {
        for peer in Array(peers.values) where peer.session.clientID == clientID { disconnect(peer) }
    }
    func stop() {
        listener?.cancel(); listener = nil; listenerID = nil; listeningPort = nil
        eventTask?.cancel(); eventTask = nil
        for peer in Array(peers.values) { disconnect(peer) }
        status = enabled ? "Stopped" : "Disabled"
    }
    func shutdown() {
        stop(); stateObservation = nil
        capabilities = { [] }; interactionBlocked = { true }
        currentRunID = { nil }; cancelledRemoteRun = { _ in }
    }
    private func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: configuredPort)!)
            parameters.includePeerToPeer = false
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: configuredPort)!)
            let listenerID = UUID()
            self.listener = listener; self.listenerID = listenerID; status = "Starting"
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, self.listenerID == listenerID else { return }
                    switch state {
                    case .ready:
                        self.listeningPort = self.listener?.port?.rawValue
                        self.status = "Listening on 127.0.0.1:\(self.listeningPort ?? self.configuredPort)"
                    case .failed(let error): self.stop(); self.status = "Local controller failed: \(error.localizedDescription)"
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    guard let self, self.listenerID == listenerID else { connection.cancel(); return }
                    self.accept(connection)
                }
            }
            listener.start(queue: .main)
        } catch { status = "Could not start local controller: \(error.localizedDescription)" }
    }
    private func accept(_ connection: NWConnection) {
        guard listener != nil, peers.count < 8,
              case .hostPort(let host, _) = connection.endpoint, host == .ipv4(.loopback) else { connection.cancel(); return }
        let peer = Peer(connection); peers[peer.id] = peer; connectedClients = peers.count
        let peerID = peer.id
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, let current = self.peers[peerID] else { return }
                switch state {
                case .ready: self.receive(current)
                case .failed, .cancelled: self.disconnect(current)
                default: break
                }
            }
        }
        peer.handshakeTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            if let self, let current = self.peers[peerID], current.session.clientID == nil { self.disconnect(current) }
        }
        connection.start(queue: .main)
    }
    private func receive(_ peer: Peer) {
        guard !peer.closing else { return }
        let peerID = peer.id
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, let peer = self.peers[peerID] else { return }
                if let data {
                    do {
                        for frame in try peer.buffer.append(data) {
                            guard self.peers[peerID] != nil else { return }
                            do { self.handle(try JSONDecoder().decode(StudioControlRequest.self, from: frame), peer: peer) }
                            catch { self.sendError(.init(code: "malformedMessage", message: "Send one versioned JSON request per line."), peer: peer, close: true); return }
                        }
                    } catch {
                        self.sendError(.init(code: "messageSize", message: "A message exceeded the local IPC size limit."), peer: peer, close: true); return
                    }
                }
                if complete || error != nil { self.disconnect(peer) }
                else { self.receive(peer) }
            }
        }
    }
    private func handle(_ request: StudioControlRequest, peer: Peer) {
        guard !peer.closing else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - peer.rateWindowStart >= 1 { peer.rateWindowStart = now; peer.requestsInWindow = 0 }
        peer.requestsInWindow += 1
        guard peer.requestsInWindow <= 60 else {
            sendError(.init(code: "rateLimit", message: "Local controllers may send at most 60 requests per second."), id: request.id, peer: peer, close: true); return
        }
        if peer.session.clientID == nil {
            if let error = peer.session.authorize(request, tokenForClient: pairingStore.token) { sendError(error, id: request.id, peer: peer, close: true); return }
            if let error = clientAuthorization(peer.session.clientID!, nil) { sendError(error, id: request.id, peer: peer, close: true); return }
            peer.handshakeTimeout?.cancel(); peer.handshakeTimeout = nil
            objectWillChange.send()
            send(.init(type: "authenticated", id: request.id, sessionID: peer.session.sessionID, snapshot: currentSnapshot()), peer: peer)
            return
        }
        if let error = peer.session.validate(request, clientStillPaired: { pairingStore.token(for: $0) != nil }) {
            sendError(error, id: request.id, peer: peer, close: error.code == "unauthorized" || error.code == "versionMismatch" || error.code == "sessionLimit"); return
        }
        if let error = clientAuthorization(peer.session.clientID!, request.type == .command ? request.commandID : nil) {
            sendError(error, id: request.id, peer: peer, close: error.code == "adapterDisabled"); return
        }
        switch request.type {
        case .authenticate: return
        case .ping: send(.init(type: "pong", id: request.id, sessionID: peer.session.sessionID), peer: peer)
        case .snapshot: send(.init(type: "snapshot", id: request.id, sessionID: peer.session.sessionID, snapshot: currentSnapshot()), peer: peer)
        case .subscribe:
            peer.subscribed = true
            send(.init(type: "snapshot", id: request.id, sessionID: peer.session.sessionID, snapshot: currentSnapshot()), peer: peer)
        case .capabilities:
            let all = capabilities(), cursor = request.cursor ?? 0
            guard cursor <= all.count else { sendError(.init(code: "invalidRequest", message: "Capability cursor is outside the catalog."), id: request.id, peer: peer); return }
            let end = min(all.count, cursor + 20)
            let page = all[cursor..<end].map { capability in
                guard let error = clientAuthorization(peer.session.clientID!, capability.id) else { return capability }
                var restricted = capability; restricted.available = false; restricted.unavailableReason = error.message
                return restricted
            }
            send(.init(type: "capabilities", id: request.id, sessionID: peer.session.sessionID,
                       commands: page, nextCursor: end < all.count ? end : nil, totalCommands: all.count), peer: peer)
        case .command:
            let commandID = request.commandID!
            let previousRun = currentRunID()
            let result = execute(commandID, request.value, request.delta, request.page, request.text)
            if result.succeeded, commandID.hasPrefix("macro."), commandID.hasSuffix(".run"), currentRunID() != previousRun { peer.ownedMacroRun = currentRunID() }
            send(.init(type: "result", id: request.id, sessionID: peer.session.sessionID, snapshot: currentSnapshot(), result: result), peer: peer)
        }
    }
    private func sendError(_ error: StudioControlProtocolError, id: UUID? = nil, peer: Peer, close: Bool = false) {
        send(.init(type: "error", id: id, sessionID: peer.session.sessionID, error: error), peer: peer, close: close)
    }
    private func send(_ response: StudioControlResponse, peer: Peer, close: Bool = false) {
        guard peers[peer.id] != nil, !peer.closing else { return }
        guard var data = try? JSONEncoder().encode(response), data.count <= StudioControlFrameBuffer.maximumFrameBytes,
              peer.pendingSends < 8 else { disconnect(peer); return }
        if close { peer.closing = true }
        data.append(10); peer.pendingSends += 1
        let peerID = peer.id
        peer.connection.send(content: data, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, let current = self.peers[peerID] else { return }
                current.pendingSends -= 1
                if close || error != nil { self.disconnect(current) }
            }
        })
    }
    private func currentSnapshot() -> StudioControlSnapshot {
        var state = snapshot()
        let commands = capabilities()
        if state != lastSnapshot || commands != lastCapabilities {
            lastSnapshot = state; lastCapabilities = commands; revision &+= 1
        }
        state.revision = revision
        return state
    }
    private func scheduleEvent() {
        guard listener != nil, eventTask == nil else { return }
        eventTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let self else { return }
            self.eventTask = nil
            let state = self.currentSnapshot()
            guard self.revision > self.lastBroadcastRevision else { return }
            self.lastBroadcastRevision = self.revision
            for peer in self.peers.values where peer.subscribed {
                self.send(.init(type: "event", sessionID: peer.session.sessionID, snapshot: state), peer: peer)
            }
        }
    }
    private func disconnect(_ peer: Peer) {
        guard peers.removeValue(forKey: peer.id) != nil else { return }
        peer.handshakeTimeout?.cancel(); peer.connection.cancel()
        if let run = peer.ownedMacroRun { cancelledRemoteRun(run) }
        connectedClients = peers.count
    }
    private static func streamLabel(_ state: StreamSessionState) -> String {
        switch state { case .idle: "idle"; case .connecting: "connecting"; case .live: "live"; case .reconnecting: "reconnecting"; case .stopping: "stopping"; case .failed: "failed" }
    }
    private static func recordingLabel(_ state: RecordingSessionState) -> String {
        switch state { case .idle: "idle"; case .preparing: "preparing"; case .recording: "recording"; case .paused: "paused"; case .stopping: "stopping"; case .failed: "failed" }
    }
}
