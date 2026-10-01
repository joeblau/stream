import Combine
import Foundation
import StreamCore

/// E06 (issue #165): the PTZ runtime. Owns one `PTZTransport` per configured
/// target and turns dispatcher commands into VISCA frames; the store stays
/// the source of truth for configuration (targets, presets, recall links).
///
/// **Stop discipline** (the issue's safety requirement): every movement or
/// zoom marks the target ACTIVE; `endInteractiveControl()` — called when the
/// control view disappears/loses focus — and `disconnectTarget(_:)` send a
/// VISCA stop to every active target first, so a camera never keeps driving
/// after its controls go away or its transport tears down. Movement commands
/// are fire-and-forget (VISCA over IP is best-effort; see the pinned
/// assumptions in StreamCore/PTZ.swift), so failures surface as connection
/// state, never as thrown errors.
///
/// **Testability**: the transport factory is injectable, so tests (or a
/// future on-hardware harness) can substitute a fake transport and assert on
/// the exact frames emitted without any network.
@MainActor
final class PTZController: ObservableObject {
    /// Live connection state per target, for the UI's status line.
    @Published private(set) var connectionStates: [UUID: PTZConnectionState] = [:]

    let store: PTZPresetStore

    private let transportFactory: (PTZTarget) -> any PTZTransport
    private var transports: [UUID: any PTZTransport] = [:]
    /// Targets with an outstanding move/zoom — the stop-on-focus-loss set.
    private var activeMotion: Set<UUID> = []
    private var cancellables: Set<AnyCancellable> = []

    init(store: PTZPresetStore,
         transportFactory: @escaping (PTZTarget) -> any PTZTransport = { NWPTZTransport(target: $0) }) {
        self.store = store
        self.transportFactory = transportFactory
        syncTransports(with: store.targets)
        // Configuration edits re-key transports: a target whose host/port/
        // kind changed gets a fresh connection; a removed target is stopped
        // and torn down.
        store.$targets
            .sink { [weak self] targets in
                Task { @MainActor [weak self] in
                    self?.syncTransports(with: targets)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Movement and zoom

    func move(_ targetID: UUID, direction: PTZMoveDirection, panSpeed: Int, tiltSpeed: Int) {
        guard let (target, transport) = resolve(targetID) else { return }
        activeMotion.insert(targetID)
        let packet = VISCAPacket.panTiltDrive(address: target.cameraAddress,
                                              direction: direction,
                                              panSpeed: panSpeed,
                                              tiltSpeed: tiltSpeed)
        Task { await transport.send(packet) }
    }

    func zoom(_ targetID: UUID, direction: PTZZoomDirection, speed: Int) {
        guard let (target, transport) = resolve(targetID) else { return }
        activeMotion.insert(targetID)
        let packet = VISCAPacket.zoom(address: target.cameraAddress,
                                      direction: direction,
                                      speed: speed)
        Task { await transport.send(packet) }
    }

    /// Stops pan/tilt AND zoom on one target (both axes can be driving).
    func stop(_ targetID: UUID) {
        guard let (target, transport) = resolve(targetID) else { return }
        activeMotion.remove(targetID)
        let panTilt = VISCAPacket.panTiltStop(address: target.cameraAddress)
        let zoom = VISCAPacket.zoomStop(address: target.cameraAddress)
        Task {
            await transport.send(panTilt)
            await transport.send(zoom)
        }
    }

    /// The panic/focus-loss path: stop every target with outstanding motion.
    /// Called when the control surface disappears or the window loses key
    /// status — a camera must never drive unattended.
    func endInteractiveControl() {
        for targetID in activeMotion {
            stop(targetID)
        }
    }

    // MARK: - Presets

    /// Stores the camera's CURRENT position into a VISCA slot (sends
    /// CAM_Memory set) and records the slot's name in the document.
    func storePreset(_ targetID: UUID, number: UInt8, name: String) {
        guard let (target, transport) = resolve(targetID) else { return }
        store.storePreset(PTZPreset(number: number, name: name), forTargetID: targetID)
        let packet = VISCAPacket.memorySet(address: target.cameraAddress, preset: number)
        Task { await transport.send(packet) }
    }

    /// Recalls a stored slot (CAM_Memory recall). Only slots the document
    /// knows about are recallable through the command interface — recalling
    /// an unstored slot is rejected upstream by the dispatcher.
    func recallPreset(_ targetID: UUID, number: UInt8) {
        guard let (target, transport) = resolve(targetID) else { return }
        activeMotion.remove(targetID)  // a recall supersedes manual driving
        let packet = VISCAPacket.memoryRecall(address: target.cameraAddress, preset: number)
        Task { await transport.send(packet) }
    }

    /// Removes the app-side record of a slot. The camera's own memory is
    /// deliberately left intact — the app never erases on-camera state the
    /// operator may reach from the camera's own remote.
    func removePreset(_ targetID: UUID, number: UInt8) {
        store.removePreset(number: number, forTargetID: targetID)
    }

    // MARK: - Scene-linked recall (the Take seam)

    /// Fires the EXPLICIT, opted-in recall links for a scene that just
    /// became program. Called only from the dispatcher's Take paths —
    /// previewing a scene never reaches here, and links with
    /// `recallOnProgramEntry == false` are inert by design.
    func recallLinkedPresets(forSceneID sceneID: UUID) {
        for link in store.recallLinks(forSceneID: sceneID) where link.recallOnProgramEntry {
            guard store.preset(number: link.presetNumber, forTargetID: link.targetID) != nil
            else { continue }
            recallPreset(link.targetID, number: link.presetNumber)
        }
    }

    // MARK: - Target lifecycle

    /// Stops motion, then tears the transport down (removal and
    /// reconfiguration). Stop always precedes disconnect.
    func disconnectTarget(_ targetID: UUID) {
        stop(targetID)
        if let transport = transports.removeValue(forKey: targetID) {
            Task { await transport.disconnect() }
        }
        connectionStates.removeValue(forKey: targetID)
    }

    // MARK: - Internals

    private func resolve(_ targetID: UUID) -> (PTZTarget, any PTZTransport)? {
        guard let target = store.target(withID: targetID) else { return nil }
        if let transport = transports[targetID] { return (target, transport) }
        let transport = transportFactory(target)
        transports[targetID] = transport
        transport.setStateHandler { [weak self] state in
            Task { @MainActor [weak self] in
                self?.connectionStates[targetID] = state
            }
        }
        Task { await transport.connect() }
        return (target, transport)
    }

    /// Re-keys transports against the configured targets: stops+removes
    /// transports for deleted targets and for targets whose connection
    /// parameters changed (host/port/kind/address); leaves healthy ones.
    private func syncTransports(with targets: [PTZTarget]) {
        let byID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
        for (id, _) in transports {
            guard let target = byID[id] else {
                disconnectTarget(id)
                continue
            }
            // A reconfigured connection can't migrate in place — rebuild it.
            // (Transport equality is by the parameters it was built with.)
            if let existing = transports[id] as? NWPTZTransport,
               !existing.matches(target) {
                disconnectTarget(id)
            }
        }
    }
}

private extension NWPTZTransport {
    /// True when the transport was built with the same connection
    /// parameters the target now carries (compared against the stored
    /// target snapshot captured at build time).
    func matches(_ target: PTZTarget) -> Bool {
        self.target == target
    }
}
