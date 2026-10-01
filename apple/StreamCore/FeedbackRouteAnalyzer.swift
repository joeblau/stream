import Foundation

/// A09 (issue #121): one identified duplicate capture/feedback route, with the
/// concrete routing repair the UI offers as a one-click action.
public struct FeedbackRouteIssue: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        /// The monitor OUTPUT device is also the preferred (default) mic
        /// input — the monitor signal is re-captured electrically.
        case monitorIsPreferredInput
        /// The monitor OUTPUT device is also an enabled ADDITIONAL input
        /// (A05) — same electrical loop through a second channel.
        case monitorIsAdditionalInput
        /// The monitor OUTPUT device is the SYSTEM DEFAULT input, which the
        /// default mic channel captures when no preferred input is chosen.
        case monitorIsDefaultInput
        /// No electrical route was identified, but the howl detector sees an
        /// acoustic loop (speakers heard by the mic).
        case acousticHowl
    }

    /// The concrete repair the UI offers. Every case maps to an existing
    /// studio command, so the fix is one dispatch, never a manual hunt.
    public enum Repair: Equatable, Sendable {
        /// Disable the additional input with this device UID
        /// (`.setAudioInputEnabled(uid, false)`).
        case disableInput(deviceUID: String)
        /// Mute the default mic channel (`.setChannelMuted(.microphone(nil), true)`).
        case muteDefaultMic
        /// Turn monitoring off (`.setMonitoringEnabled(false)`).
        case disableMonitoring
        /// Halve the monitor bus gain (`.setBusGain(.monitor, …)`), keeping
        /// monitoring audible while breaking the loop's gain.
        case lowerMonitor
    }

    public var kind: Kind
    /// The device at fault, when the route is electrical.
    public var deviceUID: String?
    /// The mic channel a howl was detected on, when the route is acoustic.
    public var affectedChannel: String?
    /// Short label for the diagnostics strip.
    public var title: String
    /// The exact fix, spelled out (issue #121: "surface actionable warnings
    /// with the exact fix").
    public var fix: String
    public var repair: Repair

    public var id: String { kind.rawValue + (deviceUID ?? "") + (affectedChannel ?? "") }

    public init(kind: Kind, deviceUID: String? = nil, affectedChannel: String? = nil,
                title: String, fix: String, repair: Repair) {
        self.kind = kind
        self.deviceUID = deviceUID
        self.affectedChannel = affectedChannel
        self.title = title
        self.fix = fix
        self.repair = repair
    }
}

/// A09: the routing facts the analyzer reasons over. Collected on the main
/// actor from settings + the monitor output + the howl detectors, so the
/// analysis itself stays a pure, testable function.
public struct FeedbackRouteInput: Equatable, Sendable {
    /// Monitoring is playing the monitor bus out loud right now.
    public var monitoringEnabled = false
    /// The CoreAudio UID of the device the monitor is ACTUALLY playing through
    /// (the effective output after fallback), nil when monitoring is off.
    public var monitorOutputUID: String?
    /// The system-default INPUT device UID (what the default mic channel
    /// captures when no preferred input is configured).
    public var defaultInputUID: String?
    /// The configured preferred input (the default mic channel's pinned
    /// device), if any.
    public var preferredInputUID: String?
    /// Device UIDs of ENABLED additional inputs (A05).
    public var additionalEnabledInputUIDs: [String] = []
    /// Labels of mic channels currently at howl risk (from `HowlRiskDetector`).
    public var howlingChannelLabels: [String] = []

    public init() {}
}

/// A09 (issue #121): identifies likely duplicate capture/feedback routes and
/// pairs each with a concrete routing repair ("identify likely duplicate
/// capture/feedback routes and offer a concrete routing repair in the mixer").
/// Extends A07's single monitor==input flag: the default-input route (no
/// explicit preferred input) and per-additional-input routes are diagnosed
/// too, and acoustic howls with no electrical route still get a guided repair.
public enum FeedbackRouteAnalyzer {
    public static func issues(for input: FeedbackRouteInput) -> [FeedbackRouteIssue] {
        var issues: [FeedbackRouteIssue] = []

        if input.monitoringEnabled, let output = input.monitorOutputUID {
            if let preferred = input.preferredInputUID, preferred == output {
                issues.append(FeedbackRouteIssue(
                    kind: .monitorIsPreferredInput,
                    deviceUID: output,
                    title: "Monitor output is the microphone",
                    fix: "The monitor plays through the same device the mic captures — the monitor signal loops straight back into the program mix. Disable monitoring, or choose a different monitor output.",
                    repair: .disableMonitoring))
            } else if input.preferredInputUID == nil,
                      let defaultInput = input.defaultInputUID, defaultInput == output {
                issues.append(FeedbackRouteIssue(
                    kind: .monitorIsDefaultInput,
                    deviceUID: output,
                    title: "Monitor output is the default input",
                    fix: "The default mic channel captures the system default input, which is the device monitoring plays through — the monitor signal loops into the program mix. Disable monitoring, or choose a different monitor output.",
                    repair: .disableMonitoring))
            }
            if input.additionalEnabledInputUIDs.contains(output) {
                issues.append(FeedbackRouteIssue(
                    kind: .monitorIsAdditionalInput,
                    deviceUID: output,
                    title: "Monitor output is an enabled input",
                    fix: "An additional input captures the device monitoring plays through — its channel carries the monitor signal back into the mix. Disable that input, or choose a different monitor output.",
                    repair: .disableInput(deviceUID: output)))
            }
        }

        // Acoustic loops: the detectors flagged a howl — the mic is hearing
        // the speakers (or an un-diagnosed loopback path).
        for label in input.howlingChannelLabels {
            issues.append(FeedbackRouteIssue(
                kind: .acousticHowl,
                affectedChannel: label,
                title: "Possible feedback howl on \(label)",
                fix: "The mic hears a loud, sustained tone while the monitor is live — a speaker→mic loop is forming. Lower the Monitor fader or mute the channel, and move the mic away from the speakers.",
                repair: .lowerMonitor))
        }

        return issues
    }
}
