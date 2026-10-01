import AVFoundation
import Combine
import StreamCore

/// E05 (issue #109): hardware camera controls and macOS reaction effects.
///
/// DISCOVERY. Every control a device offers is discovered per device from
/// `AVCaptureDevice`'s capability probes (`isFocusModeSupported(_:)` etc.) —
/// never assumed from the device kind — so the UI shows exactly the controls
/// the connected hardware honors and every unavailable state is explicit
/// (`CameraControlCapabilities.reactionUnavailableReason`, empty mode lists).
///
/// THE macOS CONTROL SURFACE. Manual lens position, custom ISO/duration
/// exposure, exposure bias, and manual white-balance gains are
/// `API_UNAVAILABLE(macos)` in the public SDK (validated against the macOS
/// 27 SDK), so the honest hardware surface on macOS is each control's MODE
/// (continuous-auto vs locked-at-current) plus points of interest. Controls
/// are applied with the lock-and-set pattern (`lockForConfiguration`, set
/// only probed-supported values, `unlockForConfiguration`), so no requested
/// change can throw.
///
/// PREVIEW AND PROGRAM. The capture pool runs ONE capture per camera source
/// and both composition engines read its frames, so a hardware change (a
/// focus lock, a reaction) is inherently a preview AND program change — the
/// UI states this rather than pretending the control is preview-local.
///
/// REACTIONS (macOS 14+, the deployment target — the gate is per-device, not
/// per-OS). A device can perform reactions only when the user enabled them
/// for the app in Control Center (`AVCaptureDevice.reactionEffectsEnabled`,
/// read-only) AND its active format supports them; `canPerformReactionEffects`
/// is the single probe that folds both. `availableReactionTypes` lists the
/// reactions the device can render right now — triggers outside it throw, so
/// commands validate against it. Triggered reactions render into the feed
/// before frames reach Stream, which is why they hit preview and program
/// together.

// MARK: - Capability discovery

/// The adjustable hardware controls + reaction support of one connected
/// camera, discovered fresh from the device (capabilities change with the
/// active format — a probe result is a point-in-time truth, re-read on every
/// snapshot rebuild).
struct CameraControlCapabilities: Equatable, Sendable {
    /// The focus modes the device honors (subset of automatic/locked).
    var focusModes: [CameraDeviceControlSettings.Mode] = []
    var exposureModes: [CameraDeviceControlSettings.Mode] = []
    var whiteBalanceModes: [CameraDeviceControlSettings.Mode] = []
    /// Reactions can be performed on this device right now.
    var reactionsAvailable = false
    /// The reactions `performEffect(for:)` accepts right now.
    var supportedReactions: [CameraReaction] = []
    /// WHY reactions are unavailable (nil when they are) — the explicit
    /// unavailable state the issue requires instead of an inert button.
    var reactionUnavailableReason: String?

    /// Any adjustable control at all (drives the "no adjustable controls"
    /// explicit state for devices that offer nothing).
    var hasAdjustableControls: Bool {
        !focusModes.isEmpty || !exposureModes.isEmpty || !whiteBalanceModes.isEmpty
    }
}

extension AVCaptureDevice {
    /// The discovered control surface of this device (see the file header).
    var cameraControlCapabilities: CameraControlCapabilities {
        var capabilities = CameraControlCapabilities()
        // Automatic exists when either auto flavor is honored; continuous is
        // preferred at apply time when both are.
        if isFocusModeSupported(.continuousAutoFocus) || isFocusModeSupported(.autoFocus) {
            capabilities.focusModes.append(.automatic)
        }
        if isFocusModeSupported(.locked) {
            capabilities.focusModes.append(.locked)
        }
        if isExposureModeSupported(.continuousAutoExposure) || isExposureModeSupported(.autoExpose) {
            capabilities.exposureModes.append(.automatic)
        }
        if isExposureModeSupported(.locked) {
            capabilities.exposureModes.append(.locked)
        }
        if isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            capabilities.whiteBalanceModes.append(.automatic)
        }
        if isWhiteBalanceModeSupported(.locked) {
            capabilities.whiteBalanceModes.append(.locked)
        }
        capabilities.reactionsAvailable = canPerformReactionEffects
        capabilities.supportedReactions = CameraReaction.allCases.filter {
            availableReactionTypes.contains($0.avCaptureReactionType)
        }
        if !capabilities.reactionsAvailable {
            capabilities.reactionUnavailableReason = AVCaptureDevice.reactionEffectsEnabled
                ? "This camera (or its current format) doesn't support reactions."
                : "Reactions are turned off for Stream. Enable them in Control Center › Video Effects › Reactions while the camera is capturing."
        }
        return capabilities
    }
}

extension CameraReaction {
    /// The AVFoundation reaction type this value maps to (macOS 14+).
    var avCaptureReactionType: AVCaptureReactionType {
        switch self {
        case .hearts: return .heart
        case .thumbsUp: return .thumbsUp
        case .thumbsDown: return .thumbsDown
        case .balloons: return .balloons
        case .rain: return .rain
        case .confetti: return .confetti
        case .lasers: return .lasers
        case .fireworks: return .fireworks
        }
    }

    /// Apple's recommended iconography for the reaction.
    var systemImageName: String {
        avCaptureReactionType.systemImageName
    }

    init?(avCaptureReactionType: AVCaptureReactionType) {
        switch avCaptureReactionType {
        case .heart: self = .hearts
        case .thumbsUp: self = .thumbsUp
        case .thumbsDown: self = .thumbsDown
        case .balloons: self = .balloons
        case .rain: self = .rain
        case .confetti: self = .confetti
        case .lasers: self = .lasers
        case .fireworks: self = .fireworks
        default: return nil
        }
    }
}

// MARK: - Applying preferences

/// The lock-and-set applier for persisted preferences. Shared by the capture
/// pool (re-apply on every camera start — hardware modes don't survive
/// capture restarts) and the command path (live in-place changes).
enum CameraControlApplier {
    /// Applies each non-nil preference whose target mode the device PROBED as
    /// supported; unsupported requests are skipped, never thrown. Returns a
    /// user-facing failure message when the device rejected everything (or
    /// couldn't be configured); nil on success.
    @discardableResult
    static func apply(_ settings: CameraDeviceControlSettings,
                      to device: AVCaptureDevice) -> String? {
        guard !settings.isEmpty else { return nil }
        guard (try? device.lockForConfiguration()) != nil else {
            return "The camera's controls are busy — try again."
        }
        defer { device.unlockForConfiguration() }
        if let mode = settings.focusMode, let target = focusTarget(mode, device) {
            device.focusMode = target
        }
        if let mode = settings.exposureMode, let target = exposureTarget(mode, device) {
            device.exposureMode = target
        }
        if let mode = settings.whiteBalanceMode, let target = whiteBalanceTarget(mode, device) {
            device.whiteBalanceMode = target
        }
        return nil
    }

    /// The concrete mode a preference resolves to on THIS device (continuous
    /// auto preferred over single-shot auto; nil when unsupported — callers
    /// must skip rather than set).
    private static func focusTarget(_ mode: CameraDeviceControlSettings.Mode,
                                    _ device: AVCaptureDevice) -> AVCaptureDevice.FocusMode? {
        switch mode {
        case .automatic:
            if device.isFocusModeSupported(.continuousAutoFocus) { return .continuousAutoFocus }
            return device.isFocusModeSupported(.autoFocus) ? .autoFocus : nil
        case .locked:
            return device.isFocusModeSupported(.locked) ? .locked : nil
        }
    }

    private static func exposureTarget(_ mode: CameraDeviceControlSettings.Mode,
                                       _ device: AVCaptureDevice) -> AVCaptureDevice.ExposureMode? {
        switch mode {
        case .automatic:
            if device.isExposureModeSupported(.continuousAutoExposure) { return .continuousAutoExposure }
            return device.isExposureModeSupported(.autoExpose) ? .autoExpose : nil
        case .locked:
            return device.isExposureModeSupported(.locked) ? .locked : nil
        }
    }

    private static func whiteBalanceTarget(_ mode: CameraDeviceControlSettings.Mode,
                                           _ device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceMode? {
        switch mode {
        case .automatic:
            return device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance)
                ? .continuousAutoWhiteBalance : nil
        case .locked:
            return device.isWhiteBalanceModeSupported(.locked) ? .locked : nil
        }
    }
}

// MARK: - Live state surface

/// One connected camera's control snapshot: discovered capabilities, live
/// mode/adjusting state, reactions in progress, the persisted preference, and
/// whether a demanded capture is using the device right now. Pure values —
/// the SwiftUI surface and (later) automation observe this, never the device.
struct CameraDeviceSnapshot: Equatable, Sendable, Identifiable {
    var id: String { uniqueID }
    let uniqueID: String
    let displayName: String
    let kind: CameraDeviceKind
    /// True while a demanded capture is actually using this device.
    let isCapturing: Bool
    let capabilities: CameraControlCapabilities
    let focusMode: CameraDeviceControlSettings.Mode?
    let exposureMode: CameraDeviceControlSettings.Mode?
    let whiteBalanceMode: CameraDeviceControlSettings.Mode?
    let isAdjustingFocus: Bool
    let isAdjustingExposure: Bool
    let isAdjustingWhiteBalance: Bool
    let reactionsInProgress: [CameraReaction]
    /// The persisted preference for this device (`StreamSettings.cameraControls`).
    let persisted: CameraDeviceControlSettings
}

/// The per-device control center (E05, issue #109): rebuilds a snapshot per
/// connected camera when the device set, capture demand, or persisted
/// preferences change, and owns the live control/reaction operations the
/// dispatcher's commands ride. Owned by the dispatcher (the `transitions`
/// precedent) so UI, and later automation/hardware controllers, share one
/// instance.
///
/// Device properties are read on the main actor only (the snapshot rebuild
/// and the section view's refresh timer both run there); `AVCaptureDevice`
/// objects never cross into the published state.
@MainActor
final class CameraControlCenter: ObservableObject {
    @Published private(set) var devices: [CameraDeviceSnapshot] = []

    private let deviceMonitor: DeviceMonitor
    private let pool: CaptureSourcePool
    private let session: SettingsSession
    private var cancellables: Set<AnyCancellable> = []

    init(deviceMonitor: DeviceMonitor, pool: CaptureSourcePool, session: SettingsSession) {
        self.deviceMonitor = deviceMonitor
        self.pool = pool
        self.session = session
        // `objectWillChange` fires in willSet — the Task hop lands post-set,
        // so the rebuild reads current values (the dispatcher's own pattern).
        Publishers.Merge3(
            deviceMonitor.$videoDevices.map { _ in () },
            pool.$activeSources.map { _ in () },
            session.objectWillChange.map { _ in () })
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.rebuild()
                }
            }
            .store(in: &cancellables)
        rebuild()
    }

    /// Rebuilds every snapshot. Cheap (a handful of property reads per
    /// camera); also the section view's live-refresh entry point while its
    /// controls are on screen, so "Adjusting…" states and Control-Center-side
    /// changes show without an app restart.
    func rebuild() {
        let next = deviceMonitor.videoDevices.map { snapshot(for: $0) }
        if next != devices { devices = next }
    }

    /// Applies a whole per-device preference to the connected hardware,
    /// capability-gated by the applier; the caller (dispatcher) has already
    /// persisted it. Returns a failure message for the rejection surface, or
    /// nil on success.
    @discardableResult
    func apply(_ settings: CameraDeviceControlSettings, toDeviceUID uid: String) -> String? {
        guard let device = device(for: uid) else {
            return "That camera is not connected."
        }
        let failure = CameraControlApplier.apply(settings, to: device)
        rebuild()
        return failure
    }

    /// Triggers a macOS reaction on the device (renders into the camera feed
    /// itself, so preview and program both show it). Validated by the
    /// dispatcher against `cameraControlCapabilities` first; a race (format
    /// change mid-flight) degrades to an honest failure message, never a
    /// throw.
    @discardableResult
    func performReaction(_ reaction: CameraReaction, onDeviceUID uid: String) -> String? {
        guard let device = device(for: uid) else {
            return "That camera is not connected."
        }
        guard device.canPerformReactionEffects else {
            return device.cameraControlCapabilities.reactionUnavailableReason
                ?? "Reactions aren't available on this camera right now."
        }
        let type = reaction.avCaptureReactionType
        guard device.availableReactionTypes.contains(type) else {
            return "\(reaction.displayName) isn't available on this camera right now."
        }
        device.performEffect(for: type)
        rebuild()
        return nil
    }

    private func device(for uid: String) -> AVCaptureDevice? {
        deviceMonitor.videoDevices.first(where: { $0.uniqueID == uid })
            ?? AVCaptureDevice(uniqueID: uid)
    }

    private func snapshot(for device: AVCaptureDevice) -> CameraDeviceSnapshot {
        CameraDeviceSnapshot(
            uniqueID: device.uniqueID,
            displayName: device.streamSourceDisplayName,
            kind: device.streamCameraKind,
            isCapturing: pool.isCameraDeviceInUse(device.uniqueID),
            capabilities: device.cameraControlCapabilities,
            focusMode: Self.mode(device.focusMode),
            exposureMode: Self.mode(device.exposureMode),
            whiteBalanceMode: Self.mode(device.whiteBalanceMode),
            isAdjustingFocus: device.isAdjustingFocus,
            isAdjustingExposure: device.isAdjustingExposure,
            isAdjustingWhiteBalance: device.isAdjustingWhiteBalance,
            reactionsInProgress: device.reactionEffectsInProgress.compactMap {
                CameraReaction(avCaptureReactionType: $0.reactionType)
            },
            persisted: session.activeSettings.cameraControls[device.uniqueID]
                ?? CameraDeviceControlSettings())
    }

    private static func mode(_ focusMode: AVCaptureDevice.FocusMode) -> CameraDeviceControlSettings.Mode? {
        switch focusMode {
        case .locked: return .locked
        case .autoFocus, .continuousAutoFocus: return .automatic
        @unknown default: return nil
        }
    }

    private static func mode(_ exposureMode: AVCaptureDevice.ExposureMode) -> CameraDeviceControlSettings.Mode? {
        switch exposureMode {
        case .locked, .custom: return .locked
        case .autoExpose, .continuousAutoExposure: return .automatic
        @unknown default: return nil
        }
    }

    private static func mode(_ whiteBalanceMode: AVCaptureDevice.WhiteBalanceMode) -> CameraDeviceControlSettings.Mode? {
        switch whiteBalanceMode {
        case .locked: return .locked
        case .autoWhiteBalance, .continuousAutoWhiteBalance: return .automatic
        @unknown default: return nil
        }
    }
}
