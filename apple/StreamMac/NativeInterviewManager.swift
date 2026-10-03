import Combine
import Foundation
import StreamCore

enum NativeInterviewCommand: Equatable, Sendable {
    case admit(UUID), backstage(UUID), onair(UUID), remove(UUID), restartMedia(UUID)
    case monitor(UUID, Bool), approveScreen(UUID, Bool)
    case lock(Bool), disconnect, rejoin, end

    var guestID: UUID? {
        switch self {
        case .admit(let id), .backstage(let id), .onair(let id), .remove(let id), .restartMedia(let id),
             .monitor(let id, _), .approveScreen(let id, _): return id
        default: return nil
        }
    }
    var displayName: String {
        switch self {
        case .admit: return "Admit Guest"
        case .backstage: return "Send Guest Backstage"
        case .onair: return "Allow Guest in Program"
        case .remove: return "Remove Guest"
        case .restartMedia: return "Reconnect Guest Media"
        case .monitor(_, let enabled): return enabled ? "Allow Guest in Monitor" : "Remove Guest from Monitor"
        case .approveScreen(_, let approved): return approved ? "Approve Guest Screen" : "Revoke Guest Screen"
        case .lock(let locked): return locked ? "Lock Guest Room" : "Unlock Guest Room"
        case .disconnect: return "Disconnect Guest Room"
        case .rejoin: return "Rejoin Guest Room"
        case .end: return "End Guest Room"
        }
    }
}

struct NativeInterviewLocalRoute: Equatable, Sendable {
    var slot: UUID
    var programAllowed = false
    var monitorAllowed = false
}
struct NativeInterviewControlState: Equatable, Sendable {
    var snapshot = NativeInterviewSnapshot()
    var routes: [UUID: NativeInterviewLocalRoute] = [:]
    var busy = false
    var failure: NativeInterviewError?
}

@MainActor struct NativeInterviewHostBinding {
    let factory: any NativeInterviewMediaHostFactory
    let shutdown: @MainActor () -> Void
}

/// Runtime-owned control and routing authority. A disappearing view owns no
/// session teardown; profile replacement, recovery and Quit retire this owner.
@MainActor final class NativeInterviewManager: ObservableObject {
    typealias CredentialProvider = @Sendable () async throws -> NativeInterviewSecret
    typealias ServiceFactory = @MainActor (NativeInterviewConfiguration, @escaping CredentialProvider) -> any NativeInterviewService
    typealias HostFactory = @MainActor (@escaping NativeInterviewReceiverFactory.SinkFactory) -> NativeInterviewHostBinding
    @Published private(set) var state = NativeInterviewControlState()
    private let controller: StreamController
    private let serviceFactory: ServiceFactory
    private let hostFactory: HostFactory
    private var session: NativeInterviewSession?
    private var binding: NativeInterviewHostBinding?
    private var configuration: NativeInterviewConfiguration?
    private var credentialSource: NativeInterviewCredentialSource?
    private var sharedInvite: NativeInterviewInvite?
    private var observation: AnyCancellable?
    private var reconciliation: Task<Void, Never>?, operation: Task<Void, Never>?
    private var reconciliationID: UUID?, operationID: UUID?
    private var epoch = UUID(), closed = false
    private var occupiedOperations: Set<UUID> = [], occupiedSinks: Set<UUID> = []
    private var registered: NativeInterviewPeerLease?
    private struct Intent {
        let context: NativeInterviewPeerLease
        var program = false, monitor = false
        var requiredMembershipRevision: UInt64 = 0
    }
    private var intent: Intent?

    init(controller: StreamController,
         serviceFactory: @escaping ServiceFactory = { configuration, credential in
             NativeInterviewServiceClient(configuration: configuration, credential: credential)
         }, hostFactory: @escaping HostFactory = { makeSink in
             let factory = NativeInterviewReceiverFactory(sinkFactory: makeSink)
             return .init(factory: factory, shutdown: { factory.retire() })
         }) {
        self.controller = controller; self.serviceFactory = serviceFactory; self.hostFactory = hostFactory
    }

    /// The view passes an explicit SecureField value, then clears its copy.
    /// There is no automatic credential reader or startup room creation.
    func create(configuration: NativeInterviewConfiguration, credential: NativeInterviewSecret) async throws {
        guard !closed, occupiedOperations.isEmpty,
              session == nil || [.failed, .ended, .expired, .closed].contains(state.snapshot.phase),
              state.snapshot.phase != .failed || session?.snapshot.room == nil else { throw NativeInterviewError.busy }
        let attempt = UUID(); occupiedOperations.insert(attempt); defer { occupiedOperations.remove(attempt); publishBusy() }
        retireSession(); let current = epoch
        self.configuration = configuration
        let source = NativeInterviewCredentialSource(credential); credentialSource = source
        let service = serviceFactory(configuration, { try source.current() })
        let hostBinding = hostFactory { [weak self] context in
            guard let self, !self.closed, self.epoch == current,
                  self.session?.currentPeerLease(for: context.receive.peerID) == context,
                  self.occupiedSinks.count < 2 else { throw NativeInterviewError.busy }
            let ticket = UUID(); self.occupiedSinks.insert(ticket)
            defer { self.occupiedSinks.remove(ticket) }
            self.registered = context; self.intent = .init(context: context)
            let name = self.session?.snapshot.members.first(where: { $0.id == context.receive.peerID })?.name ?? "Guest"
            guard let sink = await self.controller.makeGuestMediaSink(context.receive, name: name) else {
                self.clearRegistration(context); throw NativeInterviewError.changed
            }
            guard !self.closed, !Task.isCancelled, self.epoch == current,
                  self.session?.currentPeerLease(for: context.receive.peerID) == context,
                  self.registered == context else {
                sink.close(); self.clearRegistration(context); throw NativeInterviewError.changed
            }
            return sink
        }
        binding = hostBinding
        let next = NativeInterviewSession(service: service, factory: hostBinding.factory,
            nextGeneration: { [weak controller] in controller?.issueGuestReceiveGeneration() })
        session = next
        observation = next.$snapshot.sink { [weak self] _ in self?.scheduleReconciliation(epoch: current) }
        state = .init(busy: true)
        do {
            try await next.create(); try requireCurrent(current)
            sharedInvite = try next.guestInvite()
            try await next.connect(); try requireCurrent(current)
            reconcile(epoch: current)
        } catch {
            if epoch == current && !closed {
                if next.snapshot.room == nil {
                    let final = NativeInterviewControlState(snapshot: next.snapshot, failure: safe(error))
                    retireSession(); state = final
                } else { state.failure = safe(error); reconcile(epoch: current) }
            }
            throw safe(error)
        }
    }

    /// Explicit sharing only: no capability is published or returned by a
    /// dispatcher/IPC command. A revoked invite is replaced by a new request.
    func inviteForSharing() async throws -> URL {
        guard !closed, let session, let configuration, let room = session.snapshot.room,
              [.connected, .disconnected].contains(session.snapshot.phase), occupiedOperations.isEmpty else {
            throw NativeInterviewError.busy
        }
        let attempt = UUID(), current = epoch; occupiedOperations.insert(attempt); publishBusy()
        defer { occupiedOperations.remove(attempt); publishBusy() }
        let invite: NativeInterviewInvite
        if let sharedInvite { invite = sharedInvite }
        else { invite = try await session.createGuestInvite(); try requireCurrent(current); sharedInvite = invite }
        return try invite.guestURL(configuration: configuration, room: room)
    }

    func availabilityError(for command: NativeInterviewCommand) -> StudioCommandError? {
        guard !closed, let session else { return .unavailable("Create an interview room in Guests first.") }
        let snapshot = session.snapshot
        if let id = command.guestID, !snapshot.members.contains(where: { $0.id == id }) {
            return .invalidTarget("This guest is no longer in the current room.")
        }
        switch command {
        case .rejoin:
            return snapshot.phase == .disconnected && occupiedOperations.isEmpty && operation == nil
                ? nil : .unavailable("Rejoin is available after the room disconnects.")
        case .disconnect:
            return [.connected, .connecting].contains(snapshot.phase) ? nil : .unavailable("The room is disconnected.")
        case .end:
            return snapshot.phase == .connected ? nil : .unavailable("Rejoin the room before ending it.")
        case .admit(let id):
            guard snapshot.phase == .connected else { return .unavailable("Connect the room first.") }
            return snapshot.members.first(where: { $0.id == id })?.membership == .waiting
                ? nil : .unavailable("This guest has already been admitted.")
        case .remove, .lock:
            return snapshot.phase == .connected ? nil : .unavailable("Connect the room first.")
        case .restartMedia(let id):
            return snapshot.phase == .connected && session.currentPeerLease(for: id) != nil
                || snapshot.phase == .connected && snapshot.members.first(where: { $0.id == id })?.membership != .waiting
                ? nil : .unavailable("Admit the guest before reconnecting media.")
        case .backstage(let id):
            return snapshot.phase == .connected && snapshot.members.first(where: { $0.id == id })?.membership != .waiting
                ? nil : .unavailable("This guest has no admitted connection.")
        case .onair(let id), .monitor(let id, true), .approveScreen(let id, true):
            guard let context = session.readyPeerLease(for: id), context == registered else {
                return .unavailable("Wait for this guest's media connection to become ready.")
            }
            return nil
        case .monitor(let id, false), .approveScreen(let id, false):
            return registered?.receive.peerID == id ? nil : .unavailable("This guest has no local media connection.")
        }
    }

    @discardableResult func execute(_ command: NativeInterviewCommand) -> Bool {
        guard availabilityError(for: command) == nil, let session else { return false }
        let result: Bool
        switch command {
        case .admit(let id): result = session.admit(id)
        case .onair(let id):
            guard let context = session.readyPeerLease(for: id), context == registered,
                  let member = session.snapshot.members.first(where: { $0.id == id }), member.membershipRevision < UInt64.max else { return false }
            var wanted = intent?.context == context ? intent! : .init(context: context)
            // Repeating an already acknowledged local intent keeps its valid
            // receipt. A service that treats repeated stage as a no-op must not
            // revoke an otherwise unchanged live route. A new intent always
            // requires a new receipt, even when stale roster metadata is onair.
            let acknowledged = wanted.program && member.membership == .onair
                && member.membershipRevision >= wanted.requiredMembershipRevision
            wanted.program = true
            if !acknowledged { wanted.requiredMembershipRevision = member.membershipRevision + 1 }
            intent = wanted
            result = session.setMembership(.onair, guest: id)
            if !result { intent?.program = false }
        case .backstage(let id):
            revokeProgram(id); result = session.setMembership(.backstage, guest: id)
        case .monitor(let id, let enabled):
            guard registered?.receive.peerID == id else { return false }
            intent?.monitor = enabled; result = true
        case .approveScreen(let id, let approved):
            if !approved, let context = registered, context.receive.peerID == id {
                controller.setGuestScreenEnabled(false, lease: context.receive)
            }
            result = session.approveScreen(approved, guest: id)
        case .remove(let id):
            revokeAll(id); if sharedInvite?.id == id { sharedInvite = nil }; result = session.remove(id)
        case .restartMedia(let id):
            revokeAll(id); result = session.restartMedia(id)
        case .lock(let locked): result = session.setLocked(locked)
        case .disconnect:
            revokeAll(); session.disconnectForRejoin(); result = true
        case .rejoin:
            revokeAll(); let current = epoch, attempt = UUID(); occupiedOperations.insert(attempt); publishBusy()
            operationID = attempt
            operation = Task { [weak self] in
                guard let self else { return }
                defer {
                    self.occupiedOperations.remove(attempt)
                    if self.operationID == attempt { self.operation = nil; self.operationID = nil }
                    self.publishBusy()
                }
                do { try await session.connect(); try self.requireCurrent(current) }
                catch { if self.epoch == current && !self.closed { self.state.failure = self.safe(error) } }
                self.scheduleReconciliation(epoch: current)
            }
            result = true
        case .end:
            revokeAll(); credentialSource?.retire(); session.end(); result = true
        }
        reconcile(epoch: epoch)
        return result
    }

    /// Recovery cancels the current room without permanently retiring the
    /// runtime owner; a new room still uses the retained controller allocator.
    func endForRecovery() { retireSession(); state = .init() }
    func shutdown() {
        guard !closed else { return }
        closed = true; retireSession(); state = .init(snapshot: .init(phase: .closed))
    }
    var currentReadyLease: NativeInterviewPeerLease? {
        guard let registered else { return nil }
        return session?.readyPeerLease(for: registered.receive.peerID) == registered ? registered : nil
    }
    var occupiedSinkCount: Int { occupiedSinks.count }

    private func scheduleReconciliation(epoch current: UUID) {
        guard reconciliation == nil else { return }
        let ticket = UUID(); reconciliationID = ticket
        reconciliation = Task { [weak self] in
            guard let self, self.reconciliationID == ticket else { return }
            self.reconciliation = nil; self.reconciliationID = nil
            self.reconcile(epoch: current)
        }
    }
    private func reconcile(epoch current: UUID) {
        guard !closed, epoch == current, let session else { return }
        let snapshot = session.snapshot
        if let registered, session.currentPeerLease(for: registered.receive.peerID) != registered { clearRegistration(registered) }
        var routes: [UUID: NativeInterviewLocalRoute] = [:]
        if let context = registered, let intent, intent.context == context {
            let ready = session.readyPeerLease(for: context.receive.peerID) == context
            let member = snapshot.members.first { $0.id == context.receive.peerID }
            if member?.membership != .onair && (member?.membershipRevision ?? 0) >= intent.requiredMembershipRevision {
                self.intent?.program = false
            }
            let program = ready && intent.program && member?.membership == .onair
                && (member?.membershipRevision ?? 0) >= intent.requiredMembershipRevision
            let monitor = ready && intent.monitor
            if controller.setGuestMediaRouting(context.receive, programAllowed: program, monitorAllowed: monitor) {
                routes[context.receive.peerID] = .init(slot: context.receive.slot, programAllowed: program, monitorAllowed: monitor)
            }
        }
        state.snapshot = snapshot; state.routes = routes; state.busy = !occupiedOperations.isEmpty
        state.failure = snapshot.failure
        if [.ended, .expired, .closed].contains(snapshot.phase) {
            let final = state
            retireSession(); state = final; state.routes = [:]; state.busy = !occupiedOperations.isEmpty
        }
    }
    private func revokeProgram(_ id: UUID) {
        guard let context = registered, context.receive.peerID == id else { return }
        intent?.program = false
        _ = controller.setGuestMediaRouting(context.receive, programAllowed: false, monitorAllowed: intent?.monitor ?? false)
        state.routes[id]?.programAllowed = false
    }
    private func revokeAll(_ id: UUID? = nil) {
        guard let context = registered, id == nil || context.receive.peerID == id else { return }
        _ = controller.setGuestMediaRouting(context.receive, programAllowed: false, monitorAllowed: false)
        controller.setGuestScreenEnabled(false, lease: context.receive)
        clearRegistration(context)
    }
    private func clearRegistration(_ context: NativeInterviewPeerLease) {
        controller.removeGuestMedia(context.receive)
        if registered == context { registered = nil; intent = nil; state.routes[context.receive.peerID] = nil }
    }
    private func retireSession() {
        epoch = UUID(); observation = nil; reconciliation?.cancel(); reconciliation = nil; reconciliationID = nil
        operation?.cancel(); operation = nil; operationID = nil
        credentialSource?.retire(); credentialSource = nil
        revokeAll(); binding?.shutdown(); binding = nil; session?.shutdown(); session = nil
        configuration = nil; sharedInvite = nil
    }
    private func publishBusy() { state.busy = !occupiedOperations.isEmpty }
    private func requireCurrent(_ current: UUID) throws {
        guard !closed, epoch == current, !Task.isCancelled else { throw NativeInterviewError.changed }
    }
    private func safe(_ error: any Error) -> NativeInterviewError {
        (error as? NativeInterviewError) ?? (error is CancellationError ? .cancelled : .transport)
    }
}
