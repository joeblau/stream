import Foundation
import Observation
import StreamCore

/// Observable bridge to the broadcast extension's liveness, for the app's
/// "End Stream" control. The picker (`RPSystemBroadcastPickerView`) gives the app
/// no start/stop callback, so live state is learned two ways: the extension posts
/// `stateSignal` on start/finish, and — because a jetsam-killed extension can't
/// post anything — a light poll re-reads the heartbeat while the app is foreground.
@MainActor
@Observable
final class BroadcastMonitor {
    /// True while a broadcast is running (heartbeat fresh). Drives the End button.
    private(set) var isLive = false

    @ObservationIgnored private var observer: DarwinSignalObserver?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// Begin observing. Call from `.onAppear`.
    func start() {
        refresh()
        observer = DarwinSignalObserver(name: BroadcastControl.stateSignal) { [weak self] in
            // Delivered on the main queue already; hop onto the MainActor context.
            Task { @MainActor in self?.refresh() }
        }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.refresh()
            }
        }
    }

    /// Stop observing. Call from `.onDisappear`.
    func stop() {
        observer = nil
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() {
        isLive = BroadcastStateStore.isLive()
    }

    /// Ask the extension to end the broadcast. It tears down the RTMP/mixer
    /// pipeline with the manual-stop flag set, so it cannot auto-reconnect, then
    /// finishes itself. The extension confirms the new state via `stateSignal`.
    func endBroadcast() {
        BroadcastControl.post(BroadcastControl.stopSignal)
    }
}
