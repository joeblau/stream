import Foundation
import CoreMedia
import StreamCore
import os.lock

/// Shared session transport, independent of staged scene edits and renderer
/// instances. Only explicit transport commands reset a running overlay.
final class DynamicOverlayStore: @unchecked Sendable {
    static let shared = DynamicOverlayStore()
    private var lock = os_unfair_lock_s()
    private var states: [UUID: TimerRuntimeState] = [:]

    static var hostSeconds: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    func state(for id: UUID, autoplay: Bool = false,
               at seconds: Double = DynamicOverlayStore.hostSeconds) -> TimerRuntimeState {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if let state = states[id] { return state }
        var state = TimerRuntimeState()
        if autoplay { state.start(at: seconds) }
        states[id] = state
        return state
    }

    func perform(_ action: OverlayTransportAction, id: UUID,
                 at seconds: Double = DynamicOverlayStore.hostSeconds) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        var state = states[id] ?? TimerRuntimeState()
        switch action {
        case .start: state.start(at: seconds)
        case .pause: state.pause(at: seconds)
        case .reset: state.reset()
        }
        states[id] = state
    }

    func timer(_ config: TimerOverlayConfiguration, at seconds: Double,
               epoch: Double = Date().timeIntervalSince1970) -> TimerOverlaySample {
        TimerOverlayResolver.sample(configuration: config, state: state(for: config.runtimeID),
                                    engineSeconds: seconds, wallClockEpoch: epoch)
    }
}
