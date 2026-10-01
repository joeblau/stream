import Foundation

/// A09 (issue #121): the user-selectable echo handling mode for mic capture.
///
/// **Platform reality (evaluated 2026-10, macOS 14+ SDK):** CoreAudio/AVAudioEngine
/// ships NO built-in AEC usable from Stream's capture architecture. The one true
/// Apple AEC — VoiceProcessingIO (`kAudioUnitSubType_VoiceProcessingIO`, surfaced
/// as `AVAudioInputNode.setVoiceProcessingEnabled(_:)`) — is iOS-focused, is
/// deprecated in the current SDKs, requires rebuilding capture AND playback
/// through a single VPIO audio unit (incompatible with Stream's AVCaptureSession
/// multi-mic + ScreenCaptureKit engine), forces a processed mono/narrow channel
/// layout, and fails silently on Spatial Audio Macs. It is therefore evaluated
/// and REJECTED (see `EchoHandlingEvaluation.paths`). A software
/// reference-subtraction AEC is likewise out of scope.
///
/// What macOS DOES offer is the OS microphone mode **Voice Isolation**
/// (`AVCaptureDevice.MicrophoneMode.voiceIsolation`, macOS 12+): system-level
/// voice DSP (noise/echo attenuation) applied to supported microphones. Mic
/// modes are USER-controlled per app (Control Center → Mic Mode) — the API is
/// read-only — so this mode means "Stream prefers Voice Isolation": Stream
/// reports whether it is actually active on the live mic and guides the user to
/// enable it, rather than pretending to apply DSP itself.
public enum EchoHandlingMode: String, Codable, CaseIterable, Sendable {
    /// No echo handling. Safe with speakers only if the mic can't hear them.
    case off
    /// Prefer the macOS Voice Isolation mic mode on capture devices (where the
    /// device/macOS build supports it). Stream surfaces the live state and the
    /// Control Center path; it never applies a second suppressor on top.
    case voiceIsolation

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .voiceIsolation: return "Voice Isolation (macOS)"
        }
    }

    /// Channel/stereo limitation shown BEFORE the mode is enabled (issue #121:
    /// "display channel/stereo limitations before enabling a mode").
    public var limitationNote: String {
        switch self {
        case .off:
            return "No echo suppression is applied. Use headphones, or keep speakers away from the mic and the monitor level low."
        case .voiceIsolation:
            return "Applied by macOS, not Stream, on supported microphones (most Apple silicon built-in mics and recent Continuity devices). It is designed for voice and can collapse multi-channel or music content into a processed mono-like signal — keep it Off for music/line inputs. Enable it in Control Center → Mic Mode while the mic is in use; Stream shows below whether it is active."
        }
    }
}

/// A09 (issue #121): the documented evaluation of every echo-cancellation path
/// the issue asks about ("evaluate public AVAudioEngine voice processing and
/// the guest transport AEC path and expose supported processing modes"). Each
/// entry records whether Stream can use the path and why — the auditable answer
/// to "why is there no software AEC toggle".
public struct EchoPathEvaluation: Equatable, Sendable {
    public enum Path: String, Sendable, CaseIterable {
        /// `AVCaptureDevice.MicrophoneMode.voiceIsolation` (macOS 12+).
        case osVoiceIsolation
        /// VoiceProcessingIO / `AVAudioInputNode.setVoiceProcessingEnabled`.
        case voiceProcessingIO
        /// AEC inside the guest/remote contribution transport (EP06 guests).
        case guestTransport
        /// Stream-written software reference-subtraction AEC.
        case softwareReference
    }

    public let path: Path
    /// True when the path can actually process Stream's audio today.
    public let isUsable: Bool
    public let summary: String
}

public enum EchoHandlingEvaluation {
    /// The full evaluation, in the order the issue lists the candidates.
    public static let paths: [EchoPathEvaluation] = [
        EchoPathEvaluation(
            path: .osVoiceIsolation,
            isUsable: true,
            summary: "macOS 12+ Voice Isolation mic mode. User-controlled (Control Center → Mic Mode); the API is read-only, so Stream prefers it, reports the live state, and guides the user. Not available on every input device."),
        EchoPathEvaluation(
            path: .voiceProcessingIO,
            isUsable: false,
            summary: "VoiceProcessingIO (AVAudioEngine voice processing) is the only Apple AEC, but it is deprecated in the current SDKs, requires capture AND playback through one VPIO unit (incompatible with Stream's AVCaptureSession multi-mic engine), forces a processed mono layout, and fails silently on Spatial Audio Macs. Not adopted; never stacked with Voice Isolation."),
        EchoPathEvaluation(
            path: .guestTransport,
            isUsable: false,
            summary: "Guest/remote contribution (EP06) has no landed transport with an AEC path yet. When guests land, their return audio already rides the aux mix-minus bus, so remote echo is prevented by routing rather than DSP."),
        EchoPathEvaluation(
            path: .softwareReference,
            isUsable: false,
            summary: "A hand-written reference-subtraction AEC (NLMS/adaptive filter against the monitor/program reference) is out of scope: adaptive AECs are convergence- and tuning-sensitive, and a mis-tuned one degrades every mic channel. Feedback is instead detected (HowlRiskDetector) and repaired by routing (FeedbackRouteAnalyzer)."),
    ]

    public static func evaluation(for path: EchoPathEvaluation.Path) -> EchoPathEvaluation? {
        paths.first { $0.path == path }
    }
}

/// A09: the feedback/echo state the UI surfaces, refreshed by the studio while
/// the pipeline runs. Value type so it can ride `StudioState`.
public struct FeedbackDiagnostics: Equatable, Sendable {
    /// Per-mic-channel howl risk (keyed by `AudioChannelID.label`), from the
    /// envelope/periodicity detector fed by the isolated mic taps.
    public var howlRiskByChannel: [String: HowlRisk] = [:]
    /// Deterministic duplicate capture/feedback routes (electrical paths),
    /// each with a concrete routing repair.
    public var routeIssues: [FeedbackRouteIssue] = []
    /// Whether the OS Voice Isolation mode is active on the live default mic.
    /// Nil = unknown (no mic running or the device doesn't report modes).
    public var voiceIsolationActive: Bool?

    public init() {}

    /// True when anything deserves a warning row in the UI.
    public var hasWarnings: Bool {
        !routeIssues.isEmpty || howlRiskByChannel.values.contains { $0.isWarning }
    }
}
