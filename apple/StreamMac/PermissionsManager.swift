import AppKit
import AVFoundation
import CoreGraphics
import ScreenCaptureKit

/// Central place for capture-permission state (W06, issue #69).
///
/// ONE object answers "can this source capture?" for the whole app — the
/// first-run onboarding flow, the just-in-time explainer sheets, and the
/// settings pane's Application section all read and request through it, so
/// the three can never disagree about what is granted or how to repair a
/// denial.
///
/// Statuses are read live from the OS (`AVCaptureDevice` authorization for
/// camera/mic, `CGPreflightScreenCaptureAccess` for screen recording) on
/// `refresh()` — call it when the window appears and when the app reactivates,
/// because the user can flip a permission in System Settings at any time.
///
/// Screen recording has no "not determined" probe: preflight only answers
/// granted/not-granted. To keep the UI honest about whether the OS prompt can
/// still be shown, the manager remembers (in `UserDefaults`) whether
/// `CGRequestScreenCaptureAccess` has ever been invoked; before that first
/// request a `.needsRequest` "Request…" action is offered, after it a denial
/// is treated as final and the repair path is System Settings.
@MainActor
final class PermissionsManager: ObservableObject {
    /// The OS permission a capture source depends on.
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case camera, microphone, screenCapture

        var id: String { rawValue }

        var title: String {
            switch self {
            case .camera: return "Camera"
            case .microphone: return "Microphone"
            case .screenCapture: return "Screen Capture"
            }
        }

        var symbolName: String {
            switch self {
            case .camera: return "video.fill"
            case .microphone: return "mic.fill"
            case .screenCapture: return "rectangle.dashed.badge.record"
            }
        }

        /// The just-in-time purpose copy shown BEFORE the OS prompt, so the
        /// system dialog never arrives unexplained (W06 acceptance).
        var purpose: String {
            switch self {
            case .camera:
                return "Stream uses your camera for camera scenes and the picture-in-picture facecam overlay. Video stays on this Mac until you go live."
            case .microphone:
                return "Stream captures your microphone so your voice is part of the preview, local recordings, and the broadcast mix."
            case .screenCapture:
                return "Stream captures only the display, window, or app you pick in the system content picker — nothing else is ever recorded or sent."
            }
        }

        /// Privacy pane anchor inside System Settings (used by every
        /// "Open System Settings" repair action).
        var systemSettingsPath: String {
            switch self {
            case .camera: return "Privacy_Camera"
            case .microphone: return "Privacy_Microphone"
            case .screenCapture: return "Privacy_ScreenCapture"
            }
        }
    }

    enum Status: Equatable, Sendable {
        /// The OS prompt has not been shown yet; `request(_:)` will show it.
        case needsRequest
        case granted
        /// Denied or revoked: the OS will NOT prompt again; repair means
        /// sending the user to System Settings.
        case denied
    }

    /// A source-specific repair state (W06 acceptance: a denial must surface
    /// an actionable fix, never a silent fallback).
    struct RepairAction: Equatable, Sendable {
        let kind: Kind
        /// e.g. "Camera access denied".
        let title: String
        /// What broke and what to do about it.
        let message: String
        /// True only while the OS prompt can still be shown (`.needsRequest`).
        let canReRequest: Bool
    }

    @Published private(set) var statuses: [Kind: Status] = [:]

    private static let screenRequestedKey = "permissions.screenCaptureRequested"

    init() {
        refresh()
    }

    func status(for kind: Kind) -> Status {
        statuses[kind] ?? .needsRequest
    }

    /// True when every capture permission is granted (all three sources usable).
    var allGranted: Bool {
        Kind.allCases.allSatisfy { status(for: $0) == .granted }
    }

    /// Re-reads every status from the OS. Call on window appearance and on
    /// `NSApplication.didBecomeActiveNotification` — the user may have flipped
    /// a switch in System Settings while we were backgrounded.
    func refresh() {
        var updated: [Kind: Status] = [:]
        updated[.camera] = Self.map(AVCaptureDevice.authorizationStatus(for: .video))
        updated[.microphone] = Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        updated[.screenCapture] = screenStatus()
        statuses = updated
    }

    /// Screen-recording revocation probe: preflight can lag a revocation, so
    /// this asks ScreenCaptureKit for the shareable content — exactly what a
    /// capture would see. If the probe throws (or preflight is false), the
    /// screen source must surface its repair state instead of capturing
    /// whatever display happens to be first (W06 acceptance: no silent
    /// fallback to another display).
    func probeScreenAccess() async {
        if CGPreflightScreenCaptureAccess() {
            do {
                _ = try await SCShareableContent.current
                statuses[.screenCapture] = .granted
                return
            } catch {
                // Fall through to the denial mapping below.
            }
        }
        statuses[.screenCapture] = screenStatus()
    }

    /// Requests the permission JUST IN TIME — call only at the moment the
    /// user reaches for the matching source, never as an upfront batch.
    /// Returns the resulting status.
    @discardableResult
    func request(_ kind: Kind) async -> Status {
        switch kind {
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .screenCapture:
            // From now on a "not granted" answer means denied, not undecided.
            UserDefaults.standard.set(true, forKey: Self.screenRequestedKey)
            _ = CGRequestScreenCaptureAccess()
        }
        refresh()
        return status(for: kind)
    }

    /// The repair state for one kind, or nil when it is granted (nothing to
    /// repair). Panels rendering a source call this to swap the source for an
    /// actionable denial state.
    func repairAction(for kind: Kind) -> RepairAction? {
        switch status(for: kind) {
        case .granted:
            return nil
        case .needsRequest:
            return RepairAction(
                kind: kind,
                title: "\(kind.title) access not set up",
                message: "\(kind.purpose)",
                canReRequest: true)
        case .denied:
            return RepairAction(
                kind: kind,
                title: "\(kind.title) access denied",
                message: "\(kind.title) permission is off for Stream. Enable it in System Settings > Privacy & Security, then return here — the app re-reads permissions when it becomes active.",
                canReRequest: false)
        }
    }

    /// The repair state for a layer/source payload, so a scene panel can map
    /// its sources straight to repair UI. Non-camera/screen payloads never
    /// need OS permission and return nil.
    func repairAction(forSource payload: LayerPayload) -> RepairAction? {
        switch payload {
        case .camera: return repairAction(for: .camera)
        case .screen: return repairAction(for: .screenCapture)
        default: return nil
        }
    }

    /// Opens the permission's pane in System Settings (the repair action for
    /// a `.denied` status, where the OS will never prompt again).
    func openSystemSettings(for kind: Kind) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.systemSettingsPath)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Status mapping

    private static func map(_ authorization: AVAuthorizationStatus) -> Status {
        switch authorization {
        case .authorized: return .granted
        case .notDetermined: return .needsRequest
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    private func screenStatus() -> Status {
        if CGPreflightScreenCaptureAccess() { return .granted }
        return UserDefaults.standard.bool(forKey: Self.screenRequestedKey)
            ? .denied
            : .needsRequest
    }
}
