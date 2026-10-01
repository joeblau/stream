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

    /// Lifecycle hooks the capture pool subscribes to. All fire on the main
    /// actor with the stable identity of the device that (dis)appeared.
    var onCameraConnected: ((String) -> Void)?
    var onCameraDisconnected: ((String) -> Void)?
    /// Fires only when the active display SET actually changed (a resolution
    /// change alone keeps every ID and stays silent).
    var onDisplaysChanged: ((Set<CGDirectDisplayID>) -> Void)?

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
        // `.external` covers USB cameras/mics AND Continuity Camera devices
        // on macOS — phones hot-plug constantly (C05), and these notifications
        // are what make the pool notice them.
        let video = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
        videoDevices = video
        connectedCameraIDs = Set(video.map(\.uniqueID))
        let audio = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
        connectedAudioDeviceIDs = Set(audio.map(\.uniqueID))
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
