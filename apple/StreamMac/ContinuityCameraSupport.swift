import AVFoundation
import CoreMedia
import SwiftUI

/// C05 (issue #105): Continuity Camera and wired iPhone/iPad camera support.
///
/// DISCOVERY. macOS surfaces iPhone/iPad video through three public device
/// shapes, all enumerated by `DeviceMonitor`:
/// - wireless Continuity Camera — `AVCaptureDevice.isContinuityCamera` (macOS
///   13+) is Apple's documented identity hook; these also carry the
///   `.continuityCamera` device type (macOS 14+);
/// - Desk View — the `.deskViewCamera` device type (macOS 13+), a companion
///   camera derived from a Continuity Camera's ultra-wide frame (pair it with
///   `companionDeskViewCamera` when several phones are present);
/// - wired iPhone/iPad — a plain `.external` device exposing the device
///   SCREEN as video muxed with device audio. No public API separates it from
///   a generic USB camera, so classification additionally matches the Apple
///   model identifier and the muxed format (documented heuristic — issue #105
///   forbids private APIs).
///
/// UNAVAILABLE USB MODES (public-API only, validated against the macOS 27
/// SDK): an iPhone/iPad over USB simply DOES NOT ENUMERATE until it is
/// unlocked and the computer is trusted — there is no public API to detect a
/// connected-but-untrusted device, so the UI states the requirement instead
/// of listing a phantom device. A locked/untrusted device also delivers no
/// audio. Screen capture follows the device's orientation; per-device
/// horizon-level rotation in `FacecamCapture` normalizes it so the program
/// canvas never rotates.
///
/// SUSPENSION. A Continuity Camera does NOT disconnect when the phone locks
/// or the user pauses it in Control Center — it stays connected and its
/// `isSuspended` (KVO-observable) becomes true. `DeviceMonitor` KVOs that
/// property and routes suspension through the C10 missing-source hooks, so
/// lock/unlock and undock all recover automatically with honest messaging.
///
/// EFFECTS. Center Stage is app-controllable in cooperative control mode
/// (`AVCaptureDevice.centerStageControlMode`); Portrait and Studio Light are
/// Control-Center-only (their class properties are readonly), so the UI shows
/// their live active state and points at Control Center rather than faking a
/// toggle. All effect UI is capability-gated to Continuity-family devices.

// MARK: - Device classification

/// The physical kind of a video capture device, for badges, icons, section
/// grouping, and capability gating.
enum CameraDeviceKind: String, Sendable {
    /// The Mac's built-in camera.
    case builtIn
    /// Wireless Continuity Camera (an iPhone/iPad rear camera over
    /// Continuity). Apple's `isContinuityCamera` hook is authoritative.
    case continuity
    /// A Desk View companion camera derived from a Continuity Camera.
    case deskView
    /// A USB-attached iPhone/iPad (device screen + mic, muxed). Heuristic —
    /// see the file header.
    case wirediOS
    /// Any other USB or virtual camera.
    case externalUSB

    /// True for iPhone/iPad-sourced devices — the "iPhone & iPad" grouping
    /// in the sources UI.
    var isAppleMobileDevice: Bool {
        switch self {
        case .continuity, .deskView, .wirediOS: return true
        case .builtIn, .externalUSB: return false
        }
    }

    /// Short badge shown next to the device name; nil = no badge.
    var badge: String? {
        switch self {
        case .continuity: return "Continuity"
        case .deskView: return "Desk View"
        case .wirediOS: return "USB"
        case .builtIn, .externalUSB: return nil
        }
    }

    /// SF Symbol for tiles and rows.
    var iconName: String {
        switch self {
        case .continuity, .deskView, .wirediOS: return "iphone"
        case .builtIn, .externalUSB: return "video.fill"
        }
    }
}

extension AVCaptureDevice {
    /// Classifies a video device using only public API (see the file header
    /// for the wired-iOS heuristic and its limits).
    var streamCameraKind: CameraDeviceKind {
        if deviceType == .deskViewCamera { return .deskView }
        // Apple's documented Continuity Camera identity hook (macOS 13+).
        if isContinuityCamera { return .continuity }
        guard deviceType == .external else { return .builtIn }
        // A wired iPhone/iPad exposes its screen muxed with device audio and
        // reports an Apple mobile model identifier. Generic USB cameras match
        // neither half, so both are required.
        let isAppleMobileModel = modelID.hasPrefix("iPhone")
            || modelID.hasPrefix("iPad")
            || modelID.hasPrefix("iPod")
        let hasMuxedFormats = formats.contains {
            CMFormatDescriptionGetMediaType($0.formatDescription) == kCMMediaType_Muxed
        }
        return isAppleMobileModel && hasMuxedFormats ? .wirediOS : .externalUSB
    }

    /// Display name with the connection badge, e.g. "Joe's iPhone ·
    /// Continuity" — the explicit identity issue #105 asks pickers to show.
    var streamSourceDisplayName: String {
        guard let badge = streamCameraKind.badge else { return localizedName }
        return "\(localizedName) · \(badge)"
    }

    /// True while the device is connected but delivering no frames: iPhone
    /// locked, camera paused in Control Center, or notebook lid closed.
    /// KVO-observable (`DeviceMonitor` observes it for the C10 missing path).
    var isFeedSuspended: Bool { isSuspended }
}

// MARK: - Continuity effects (capability-gated)

/// The system-wide Continuity video-effect state, bridged into SwiftUI.
///
/// Center Stage is the one effect an app may set: the default `.user` control
/// mode throws `NSInvalidArgumentException` on any programmatic set, so the
/// controller adopts `.cooperative` — the app and Control Center share
/// control and both toggles stay live. Portrait and Studio Light have
/// readonly class properties (Control Center owns them); the controller
/// exposes their state for honest display only.
@MainActor
final class ContinuityEffectsController: ObservableObject {
    @Published private(set) var isCenterStageEnabled = false
    @Published private(set) var isPortraitEffectEnabled = false
    @Published private(set) var isStudioLightEnabled = false

    init() {
        if AVCaptureDevice.centerStageControlMode == .user {
            AVCaptureDevice.centerStageControlMode = .cooperative
        }
        refresh()
    }

    /// Re-reads the system state. The class properties are KVO-observable but
    /// class-property KVO does not bridge to SwiftUI; the effects menu calls
    /// this on appear so a Control Center change made while the menu was
    /// closed shows correctly.
    func refresh() {
        isCenterStageEnabled = AVCaptureDevice.isCenterStageEnabled
        isPortraitEffectEnabled = AVCaptureDevice.isPortraitEffectEnabled
        isStudioLightEnabled = AVCaptureDevice.isStudioLightEnabled
    }

    func setCenterStage(_ enabled: Bool) {
        // Valid without a lock and without an active session in cooperative
        // mode; a device that can't apply Center Stage simply reports
        // `isCenterStageActive == false`.
        AVCaptureDevice.isCenterStageEnabled = enabled
        refresh()
    }
}

/// The effects section of a Continuity device's context menu. Rendered only
/// when `device.streamCameraKind` is `.continuity` or `.deskView` (the
/// capability gate): Center Stage as a real toggle, Portrait/Studio Light as
/// live state with their Control Center home, plus the per-device active
/// states so "enabled but not applying to this device" is never confused.
struct ContinuityEffectsMenuContent: View {
    let device: AVCaptureDevice

    @StateObject private var effects = ContinuityEffectsController()

    var body: some View {
        Toggle("Center Stage", isOn: Binding(
            get: { effects.isCenterStageEnabled },
            set: { effects.setCenterStage($0) }))
        if device.isCenterStageActive {
            Text("Center Stage is active on this camera")
        }
        Divider()
        Text(effectState(name: "Portrait",
                         enabled: effects.isPortraitEffectEnabled,
                         active: device.isPortraitEffectActive))
        Text(effectState(name: "Studio Light",
                         enabled: effects.isStudioLightEnabled,
                         active: device.isStudioLightActive))
        Text("Portrait and Studio Light are managed in Control Center › Video Effects")
        Text("Effects apply system-wide to \(device.localizedName)")
    }

    private func effectState(name: String, enabled: Bool, active: Bool) -> String {
        if active { return "\(name): Active" }
        return enabled ? "\(name): On (inactive in the current format)"
                       : "\(name): Off"
    }
}

// MARK: - Setup guidance

/// Honest unavailable-state copy (issue #105: show HOW to enable an iPhone
/// source instead of hiding the entry point when none is connected).
enum ContinuitySetupGuidance {
    /// Shown in pickers/menus when no iPhone or iPad is detected.
    static let noDeviceDetected =
        "No iPhone or iPad detected. Connect over USB and tap Trust on the unlocked device, "
        + "or use Continuity Camera: same Apple Account, Wi-Fi and Bluetooth on, and "
        + "iPhone Settings › General › AirPlay & Continuity › Continuity Camera enabled."

    /// Shown in the switcher's empty state.
    static let emptyStateHint =
        "Connect a camera — or use an iPhone over USB (unlock and tap Trust) "
        + "or Continuity Camera (same Apple Account, Wi-Fi & Bluetooth)."
}
