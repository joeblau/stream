import AppKit
import Combine
import Foundation
import StreamCore

/// Native lifecycle observation with injectable events/actions for deterministic
/// tests. No event has permission to create a publishing or recording session.
@MainActor
final class DesktopResilienceCoordinator: ObservableObject {
    enum Event: Sendable { case sleep, wake, locked, unlocked }
    @Published var policy = DesktopResiliencePolicy()
    @Published private(set) var notice: String?
    @Published private(set) var requiresManualRestart = false
    @Published private(set) var isLocked = false
    var stopOutputs: (() -> Void)?
    var showOfflineSlate: (() -> Void)?
    var startPreview: (() -> Void)?
    var refreshSources: (() -> Void)?
    private let url: URL?
    private let workspaceCenter: NotificationCenter
    private var isSleeping = false
    private var previewOnUnlock = false
    private nonisolated(unsafe) var workspaceObservers: [NSObjectProtocol] = []
    private nonisolated(unsafe) var distributedObservers: [NSObjectProtocol] = []

    init(url: URL? = nil, observeSystem: Bool = true) {
        self.url = url
        self.workspaceCenter = NSWorkspace.shared.notificationCenter
        if let url, FileManager.default.fileExists(atPath: url.path) {
            do { policy = try JSONDecoder().decode(DesktopResiliencePolicy.self, from: Data(contentsOf: url)) }
            catch { notice = "The project resilience policy could not be read. Safe defaults are active; the original document is preserved." }
        }
        if observeSystem { observeLifecycle() }
    }
    deinit {
        for observer in workspaceObservers { workspaceCenter.removeObserver(observer) }
        for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) }
    }
    func save() {
        guard let url else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try JSONDecoder().decode(DesktopResiliencePolicy.self, from: Data(contentsOf: url))
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(policy).write(to: url, options: .atomic)
        } catch { notice = "The resilience policy could not be saved. Repair the project document before replacing it." }
    }
    func handle(_ event: Event) {
        switch event {
        case .sleep:
            guard !isSleeping else { return }; isSleeping = true
            previewOnUnlock = false
            requiresManualRestart = true
            notice = "Sleep requested: publishing and recording are stopping. Wake never restarts outputs automatically."
            stopOutputs?()
        case .wake:
            guard isSleeping else { return }
            isSleeping = false
            guard !isLocked else {
                previewOnUnlock = policy.previewAfterWake
                notice = "Mac woke while locked: source refresh and optional preview wait for unlock. Outputs require a manual restart."
                return
            }
            refreshSources?()
            if policy.previewAfterWake { startPreview?() }
            notice = "Mac woke: inspect sources and resume outputs manually. Interrupted recordings may require recovery."
        case .locked:
            guard !isLocked else { return }; isLocked = true
            // Sleep already retired every output and capture. A delayed lock
            // notification must not rebuild a slate or repeat that teardown.
            guard !isSleeping else { return }
            if policy.lockAction == .stopOutputs {
                requiresManualRestart = true
                stopOutputs?()
                notice = "Screen locked: outputs stopped; unlock does not restart public publishing."
            } else {
                showOfflineSlate?()
                notice = "Screen locked: existing outputs continue on a silent offline slate. Restore program manually after unlock."
            }
        case .unlocked:
            guard isLocked else { return }
            isLocked = false
            // The session-active and distributed unlock notifications can
            // arrive before didWake. Capture stays retired until wake.
            guard !isSleeping else { return }
            refreshSources?()
            if previewOnUnlock && policy.previewAfterWake { startPreview?() }
            previewOnUnlock = false
            notice = "Screen unlocked: inspect source availability and restore program or start outputs manually."
        }
    }
    func noteSourceFallback(_ message: String?) { notice = message }
    func acknowledgeManualRestart() { requiresManualRestart = false }
    private func observeLifecycle() {
        let center = workspaceCenter
        let events: [(Notification.Name, Event)] = [(NSWorkspace.willSleepNotification, .sleep), (NSWorkspace.didWakeNotification, .wake),
            (NSWorkspace.sessionDidResignActiveNotification, .locked), (NSWorkspace.sessionDidBecomeActiveNotification, .unlocked)]
        for (name, event) in events {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handle(event) }
            })
        }
        // Screen lock has no public NSWorkspace lock notification. These macOS
        // distributed notifications complement the public user-session events;
        // the same conservative policy applies to either signal.
        let distributed = DistributedNotificationCenter.default()
        for (name, event) in [("com.apple.screenIsLocked", Event.locked), ("com.apple.screenIsUnlocked", .unlocked)] {
            distributedObservers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handle(event) }
            })
        }
    }
}
