import Combine
import Foundation
import StreamCore

/// One ordered operation stream per immutable camera connection. Stop is a
/// transport-processing barrier, not a VISCA/device acknowledgment.
@MainActor final class PTZController: ObservableObject {
    @Published private(set) var connectionStates: [UUID: PTZConnectionState] = [:]
    let store: PTZPresetStore
    struct MotionLease: Equatable, Sendable {
        let targetID: UUID
        fileprivate let connection: UUID
        fileprivate let motion: UUID
    }
    private let transportFactory: (PTZTarget) -> any PTZTransport
    private let nudgeWait: @MainActor () async -> Void
    @MainActor private final class Runtime {
        let id = UUID()
        let target: PTZTarget
        let transport: any PTZTransport
        var tail: Task<Void, Never>?
        var motion: UUID?
        var nudge: Task<Void, Never>?
        var retired = false
        init(target: PTZTarget, transport: any PTZTransport) { self.target = target; self.transport = transport }
    }
    private var runtimes: [UUID: Runtime] = [:]
    private var retiring: [UUID: Task<Void, Never>] = [:]
    private var activeMotion: Set<UUID> = []
    private var cancellables: Set<AnyCancellable> = []

    init(store: PTZPresetStore,
         transportFactory: @escaping (PTZTarget) -> any PTZTransport = { NWPTZTransport(target: $0) },
         nudgeWait: @escaping @MainActor () async -> Void = { try? await Task.sleep(for: .milliseconds(250)) }) {
        self.store = store; self.transportFactory = transportFactory; self.nudgeWait = nudgeWait
        store.$targets.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                // Read current configuration, never a delayed old publisher snapshot.
                guard let self else { return }
                self.syncTransports(with: self.store.targets)
            }
        }.store(in: &cancellables)
    }

    func move(_ targetID: UUID, direction: PTZMoveDirection, panSpeed: Int, tiltSpeed: Int) {
        drive(targetID, nudge: false) { VISCAPacket.panTiltDrive(address: $0.cameraAddress,
            direction: direction, panSpeed: panSpeed, tiltSpeed: tiltSpeed) }
    }
    func zoom(_ targetID: UUID, direction: PTZZoomDirection, speed: Int) {
        drive(targetID, nudge: false) { VISCAPacket.zoom(address: $0.cameraAddress, direction: direction, speed: speed) }
    }
    func nudge(_ targetID: UUID, direction: PTZMoveDirection, panSpeed: Int, tiltSpeed: Int) {
        drive(targetID, nudge: true) { VISCAPacket.panTiltDrive(address: $0.cameraAddress,
            direction: direction, panSpeed: panSpeed, tiltSpeed: tiltSpeed) }
    }
    func nudgeZoom(_ targetID: UUID, direction: PTZZoomDirection, speed: Int) {
        drive(targetID, nudge: true) { VISCAPacket.zoom(address: $0.cameraAddress, direction: direction, speed: speed) }
    }
    private func drive(_ targetID: UUID, nudge: Bool, packet: (PTZTarget) -> Data) {
        guard let runtime = resolve(targetID) else { return }
        invalidateMotion(runtime)
        let lease = UUID(); runtime.motion = lease; activeMotion.insert(targetID)
        let bytes = packet(runtime.target)
        enqueue(runtime) {
            guard !runtime.retired, runtime.motion == lease else { return }
            await runtime.transport.send(bytes)
        }
        if nudge {
            let wait = nudgeWait
            runtime.nudge = Task { [weak self, weak runtime] in
                // The bounded intent starts now, not after a potentially slow send.
                await wait()
                guard !Task.isCancelled, let self, let runtime,
                      self.runtimes[targetID] === runtime, runtime.motion == lease else { return }
                self.stopRuntime(runtime)
            }
        }
    }
    private func invalidateMotion(_ runtime: Runtime) {
        runtime.nudge?.cancel(); runtime.nudge = nil; runtime.motion = nil
        activeMotion.remove(runtime.target.id)
    }
    private func enqueue(_ runtime: Runtime, _ operation: @escaping @MainActor () async -> Void) {
        let previous = runtime.tail
        runtime.tail = Task { await previous?.value; await operation() }
    }
    private func stopRuntime(_ runtime: Runtime) {
        invalidateMotion(runtime)
        enqueue(runtime) { await Self.sendStop(runtime) }
    }
    private static func sendStop(_ runtime: Runtime) async {
        await runtime.transport.send(VISCAPacket.panTiltStop(address: runtime.target.cameraAddress))
        await runtime.transport.send(VISCAPacket.zoomStop(address: runtime.target.cameraAddress))
    }
    func stop(_ targetID: UUID) {
        guard let runtime = runtimes[targetID] ?? resolve(targetID) else { return }
        stopRuntime(runtime)
    }
    func motionLease(for targetID: UUID) -> MotionLease? {
        guard let runtime = runtimes[targetID], let motion = runtime.motion else { return nil }
        return MotionLease(targetID: targetID, connection: runtime.id, motion: motion)
    }
    func stop(_ lease: MotionLease) {
        guard let runtime = runtimes[lease.targetID], runtime.id == lease.connection,
              runtime.motion == lease.motion else { return }
        stopRuntime(runtime)
    }
    /// Cleanup is independent of UI command availability: it only revokes
    /// motion this controller already owns, and never starts another drive.
    func endInteractiveControl() {
        for id in Array(activeMotion) { if let runtime = runtimes[id] { stopRuntime(runtime) } }
    }

    func storePreset(_ targetID: UUID, number: UInt8, name: String) {
        guard let runtime = resolve(targetID) else { return }
        store.storePreset(PTZPreset(number: number, name: name), forTargetID: targetID)
        enqueue(runtime) {
            guard !runtime.retired else { return }
            await runtime.transport.send(VISCAPacket.memorySet(address: runtime.target.cameraAddress, preset: number))
        }
    }
    func recallPreset(_ targetID: UUID, number: UInt8) {
        guard let runtime = resolve(targetID) else { return }
        // A recall supersedes manual motion and its timer. Stop both axes
        // before recall so the old zoom cannot continue alongside the preset.
        stopRuntime(runtime)
        enqueue(runtime) {
            guard !runtime.retired else { return }
            await runtime.transport.send(VISCAPacket.memoryRecall(address: runtime.target.cameraAddress, preset: number))
        }
    }
    func removePreset(_ targetID: UUID, number: UInt8) { store.removePreset(number: number, forTargetID: targetID) }
    func recallLinkedPresets(forSceneID sceneID: UUID) {
        for link in store.recallLinks(forSceneID: sceneID) where link.recallOnProgramEntry {
            guard store.preset(number: link.presetNumber, forTargetID: link.targetID) != nil else { continue }
            recallPreset(link.targetID, number: link.presetNumber)
        }
    }

    func disconnectTarget(_ targetID: UUID) {
        guard let runtime = runtimes.removeValue(forKey: targetID) else { return }
        invalidateMotion(runtime); runtime.retired = true
        runtime.transport.setStateHandler(nil)
        connectionStates.removeValue(forKey: targetID)
        let previous = runtime.tail
        let task = Task { [weak self] in
            await previous?.value
            // Uses the OLD address/transport even after its store entry changes.
            await Self.sendStop(runtime)
            await runtime.transport.disconnect()
            self?.retiring[runtime.id] = nil
        }
        runtime.tail = task; retiring[runtime.id] = task
    }
    /// Waits owned operations/retirement, useful to an orderly shutdown or an
    /// owned fixture. It cannot establish physical camera completion.
    func waitForPendingOperations() async {
        let owned = Array(runtimes.values), old = Array(retiring.values)
        for runtime in owned { await runtime.nudge?.value; await runtime.tail?.value }
        for task in old { await task.value }
    }
    private func resolve(_ targetID: UUID) -> Runtime? {
        guard let target = store.target(withID: targetID) else { return nil }
        if let current = runtimes[targetID] {
            if current.target == target { return current }
            disconnectTarget(targetID)
        }
        let transport = transportFactory(target), runtime = Runtime(target: target, transport: transport)
        runtimes[targetID] = runtime
        let generation = runtime.id
        transport.setStateHandler { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.runtimes[targetID]?.id == generation else { return }
                self.connectionStates[targetID] = state
            }
        }
        enqueue(runtime) { if !runtime.retired { await transport.connect() } }
        return runtime
    }
    private func syncTransports(with targets: [PTZTarget]) {
        let byID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
        for (id, runtime) in runtimes where byID[id] != runtime.target { disconnectTarget(id) }
    }
}
