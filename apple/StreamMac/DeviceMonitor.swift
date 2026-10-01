import AppKit
import AVFoundation
import CoreGraphics

/// Central device-availability watcher (C10, issue #79).
///
/// ONE object answers "is this physical device/display still there?" for the
/// capture layer: camera connect/disconnect (`AVCaptureDevice` notifications,
/// which cover USB, Continuity Camera, and virtual cameras), audio input
/// connect/disconnect (same notifications, audio media type), and display
/// reconfiguration (`NSApplication.didChangeScreenParametersNotification`
/// re-probed through CoreGraphics' active display list — no Screen Recording
/// permission needed for the ID list).
///
/// The `CaptureSourcePool` subscribes through the `on*` hooks to move sources
/// in and out of their missing state; SwiftUI reads the published snapshots
/// for source-specific health and relink pickers. Stable identity is the
/// capture device's `uniqueID` / the `CGDirectDisplayID`: those are what the
/// S05 source registry pins, so a reconnected device matches its source
/// exactly and an unrelated device never substitutes for it.
@MainActor
final class DeviceMonitor: ObservableObject {
    /// `uniqueID`s of the currently connected video capture devices.
    @Published private(set) var connectedCameraIDs: Set<String> = []
    /// `uniqueID`s of the currently connected audio input devices.
    @Published private(set) var connectedAudioDeviceIDs: Set<String> = []
    /// Active displays from the most recent CoreGraphics re-probe.
    @Published private(set) var connectedDisplayIDs: Set<CGDirectDisplayID> = []
    /// The connected video devices themselves, for relink pickers.
    @Published private(set) var videoDevices: [AVCaptureDevice] = []
    /// C05 (issue #105): `uniqueID`s of connected cameras whose feed is
    /// SUSPENDED — iPhone locked, camera paused in Control Center, notebook
    /// lid closed. A suspended Continuity Camera stays connected (no
    /// disconnect notification fires), so suspension is tracked separately
    /// via KVO on `AVCaptureDevice.isSuspended` and routed through the same
    /// connect/disconnect hooks below: the pool's C10 missing state and
    /// auto-recovery then cover lock/unlock exactly like unplug/replug.
    @Published private(set) var suspendedCameraIDs: Set<String> = []

    /// Lifecycle hooks the capture pool subscribes to. All fire on the main
    /// actor with the stable identity of the device that (dis)appeared.
    var onCameraConnected: ((String) -> Void)?
    var onCameraDisconnected: ((String) -> Void)?
    /// Fires only when the active display SET actually changed (a resolution
    /// change alone keeps every ID and stays silent).
    var onDisplaysChanged: ((Set<CGDirectDisplayID>) -> Void)?

    /// Per-device `isSuspended` KVO tokens, keyed by `uniqueID` (C05). Tokens
    /// invalidate on dealloc; the dictionary is rebuilt by `refreshDevices`.
    private var suspensionObservers: [String: NSKeyValueObservation] = [:]

    /// Notification tokens. `nonisolated(unsafe)` so `deinit` (nonisolated on
    /// a @MainActor type) can remove them; tokens are safe to touch there.
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    init() {
        refreshDevices()
        refreshDisplays()
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            // `Notification`/`AVCaptureDevice` aren't Sendable: read the
            // stable identity here (main queue) and hop only the String.
            let uniqueID = (note.object as? AVCaptureDevice)?.uniqueID
            let isVideo = (note.object as? AVCaptureDevice)?.hasMediaType(.video) ?? false
            Task { @MainActor in
                self?.handleDeviceChange(uniqueID: uniqueID, isVideo: isVideo, connected: true)
            }
        })
        observers.append(center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let uniqueID = (note.object as? AVCaptureDevice)?.uniqueID
            let isVideo = (note.object as? AVCaptureDevice)?.hasMediaType(.video) ?? false
            Task { @MainActor in
                self?.handleDeviceChange(uniqueID: uniqueID, isVideo: isVideo, connected: false)
            }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshDisplays(notify: true) }
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Re-probes

    private func handleDeviceChange(uniqueID: String?, isVideo: Bool, connected: Bool) {
        refreshDevices()
        guard isVideo, let uniqueID else { return }
        if connected {
            onCameraConnected?(uniqueID)
        } else {
            onCameraDisconnected?(uniqueID)
        }
    }

    private func refreshDevices() {
        // `.external` covers USB cameras/mics AND wired iPhone/iPad screen
        // devices; `.continuityCamera` (macOS 14+) and `.deskViewCamera`
        // (macOS 13+) name the wireless Continuity devices explicitly (C05).
        // A device matching several requested types appears once. Phones
        // hot-plug constantly, and these notifications are what make the
        // pool notice them.
        let video = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .deskViewCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
        videoDevices = video
        connectedCameraIDs = Set(video.map(\.uniqueID))
        observeSuspension(for: video)
        let audio = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
        connectedAudioDeviceIDs = Set(audio.map(\.uniqueID))
    }

    // MARK: - Feed suspension (C05, issue #105)

    /// Keeps one `isSuspended` observer per connected camera and re-syncs the
    /// suspended set. A suspended device (locked iPhone, camera paused in
    /// Control Center) stays connected but delivers no frames — the pool
    /// needs the same missing/recovery treatment as an unplug, so suspension
    /// fires the C10 hooks: suspended → `onCameraDisconnected`, back →
    /// `onCameraConnected`. The pool reads `isSuspended` itself to phrase the
    /// missing message honestly.
    private func observeSuspension(for devices: [AVCaptureDevice]) {
        let live = Set(devices.map(\.uniqueID))
        suspensionObservers = suspensionObservers.filter { live.contains($0.key) }
        for device in devices where suspensionObservers[device.uniqueID] == nil {
            let uniqueID = device.uniqueID
            suspensionObservers[uniqueID] = device.observe(\.isSuspended, options: [.new]) { [weak self] _, change in
                // Only the Bool crosses the isolation boundary (same pattern
                // as the notification observers above).
                let suspended = change.newValue ?? false
                Task { @MainActor in
                    self?.handleSuspension(uniqueID: uniqueID, suspended: suspended)
                }
            }
        }
        suspendedCameraIDs = Set(devices.filter(\.isSuspended).map(\.uniqueID))
    }

    private func handleSuspension(uniqueID: String, suspended: Bool) {
        // A device that also disconnected is owned by the disconnect path.
        guard connectedCameraIDs.contains(uniqueID) else { return }
        if suspended {
            guard !suspendedCameraIDs.contains(uniqueID) else { return }
            suspendedCameraIDs.insert(uniqueID)
            onCameraDisconnected?(uniqueID)
        } else {
            guard suspendedCameraIDs.contains(uniqueID) else { return }
            suspendedCameraIDs.remove(uniqueID)
            onCameraConnected?(uniqueID)
        }
    }

    /// Re-reads the active display list. With `notify`, fires
    /// `onDisplaysChanged` only on a real membership change.
    private func refreshDisplays(notify: Bool = false) {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return }
        let current = Set(ids.prefix(Int(count)))
        guard current != connectedDisplayIDs else { return }
        connectedDisplayIDs = current
        if notify { onDisplaysChanged?(current) }
    }
}
