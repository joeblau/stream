import Foundation

/// E05 (issue #109): the persisted per-device hardware camera control
/// preferences (macOS studio), keyed in `StreamSettings.cameraControls` by
/// the capture device's stable `uniqueID` (the C10 identity rule: the same
/// physical camera restores its own settings across reconnects and
/// relaunches, and an unrelated device never inherits them).
///
/// The value type is deliberately platform-free (no AVFoundation): on macOS
/// the controllable hardware surface is the MODE of each control — manual
/// lens position, custom ISO/duration exposure, exposure bias, and manual
/// white-balance gains are `API_UNAVAILABLE(macos)` in the public SDK — so a
/// per-control automatic/locked pair is the whole honest model. Nil fields
/// mean "leave this control as the device has it", so a partial preference
/// never stomps a control the user hasn't touched.
public struct CameraDeviceControlSettings: Codable, Equatable, Sendable {
    /// Automatic (the device's continuous auto mode) vs locked at the
    /// current value. RawRepresentable for Codable stability.
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case automatic, locked

        public var displayName: String {
            switch self {
            case .automatic: return "Auto"
            case .locked: return "Locked"
            }
        }
    }

    public var focusMode: Mode?
    public var exposureMode: Mode?
    public var whiteBalanceMode: Mode?

    public init(focusMode: Mode? = nil,
                exposureMode: Mode? = nil,
                whiteBalanceMode: Mode? = nil) {
        self.focusMode = focusMode
        self.exposureMode = exposureMode
        self.whiteBalanceMode = whiteBalanceMode
    }

    /// True when no control carries a preference (the device runs its own
    /// defaults) — the UI's "reset" state.
    public var isEmpty: Bool {
        focusMode == nil && exposureMode == nil && whiteBalanceMode == nil
    }
}

/// E05 (issue #109): a macOS system reaction effect (hearts, confetti, …)
/// rendered by AVFoundation into the camera feed BEFORE frames reach Stream,
/// so it lands in preview and program together. The value type is
/// platform-free so commands and tests never touch AVFoundation; the macOS
/// layer maps it to `AVCaptureReactionType` and gates per-device support.
public enum CameraReaction: String, Codable, CaseIterable, Sendable {
    case hearts, thumbsUp, thumbsDown, balloons, rain, confetti, lasers, fireworks

    public var displayName: String {
        switch self {
        case .hearts: return "Hearts"
        case .thumbsUp: return "Thumbs Up"
        case .thumbsDown: return "Thumbs Down"
        case .balloons: return "Balloons"
        case .rain: return "Rain"
        case .confetti: return "Confetti"
        case .lasers: return "Lasers"
        case .fireworks: return "Fireworks"
        }
    }
}
