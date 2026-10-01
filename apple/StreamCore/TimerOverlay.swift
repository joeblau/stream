import Foundation

// MARK: - G04 (issue #111): countdown, stopwatch, clock, and scheduled-start
// overlays — the pure value model, state machine, formatting, and timezone
// rules.
//
// The platform-independent half of the macOS timer-overlay work. A timer
// overlay is dynamic TEXT on a G02 `TextSourcePayload` (LayerGraph, StreamMac)
// — never a new layer kind: the payload carries a `TimerOverlayConfiguration`,
// and a per-tick provider (the `TitleTokenStore` pattern) resolves the string
// the renderer rasterizes, so box/style/timing semantics and the
// content-keyed raster cache come free from the G02 render path.
//
// CLOCK DOMAINS. Two clocks are in play, both injected so the whole surface
// is unit-testable:
// - ELAPSED timers (countdown, stopwatch) anchor to the COMMON MEDIA CLOCK —
//   the composition engines' presentation timestamps, which both engines
//   derive from the host clock (`CMClockGetTime(CMClockGetHostTimeClock())`),
//   so one anchor reads identically on preview and program. Command-time
//   mutations and render-time samples must agree on this domain; the
//   StreamMac `TimerOverlayStore` is the bridge.
// - WALL-CLOCK overlays (clock, scheduled start) sample epoch seconds and
//   apply the EXPLICIT timezone in the configuration — never the renderer's
//   ambient zone. An empty/unknown identifier falls back to the system zone
//   (the documented honest fallback).
//
// SHARING. Timer runtime state lives outside the scene document, keyed by
// durable playback ID in a lock-protected shared store (the `TitleTokenStore` /
// `ProgramAnnotationStore` pattern): preview and program sample the SAME
// state, transport commands are session state (never staged, never undoable
// — the A02 media-transport precedent), and `start` on a running timer is a
// no-op, so bringing a scene into preview can never reset a running program
// timer.

/// The kind of timer a text layer renders.
public enum TimerOverlayKind: String, Codable, CaseIterable, Sendable {
    /// Counts a configured duration down to zero; `zeroBehavior` rules the
    /// moment it reaches zero.
    case countdown
    /// Counts up from zero while running.
    case stopwatch
    /// The current wall-clock time in the configured timezone.
    case clock
    /// Counts down to a scheduled wall-clock time of day (explicit timezone;
    /// the next occurrence wins when today's has passed).
    case scheduledStart

    public var displayName: String {
        switch self {
        case .countdown: return "Countdown"
        case .stopwatch: return "Stopwatch"
        case .clock: return "Clock"
        case .scheduledStart: return "Scheduled Start"
        }
    }

    /// True for kinds driven by transport state (start/pause/reset);
    /// wall-clock kinds derive from the epoch and ignore the transport.
    public var usesTransport: Bool {
        switch self {
        case .countdown, .stopwatch: return true
        case .clock, .scheduledStart: return false
        }
    }
}

/// How the timer's value renders as text. The `clock*` cases are wall-clock
/// formats; the rest are elapsed/remaining formats. A mismatched pick (a
/// wall-clock format on an elapsed timer, or vice versa) falls back to the
/// kind's default — documented, deterministic.
public enum TimerDisplayFormat: String, Codable, CaseIterable, Sendable {
    /// `H:MM:SS` once hours exist, else `M:SS`.
    case hMMss
    /// Total minutes (can exceed 59) + seconds: `MM:SS`.
    case mmss
    /// Whole seconds only: `3909`.
    case seconds
    /// `M:SS.t` — tenths for sub-second-precision reads.
    case tenths
    /// `3:45 PM`.
    case clock12
    /// `15:45`.
    case clock24

    public var displayName: String {
        switch self {
        case .hMMss: return "H:MM:SS"
        case .mmss: return "MM:SS"
        case .seconds: return "Seconds"
        case .tenths: return "M:SS.t"
        case .clock12: return "12-Hour Clock"
        case .clock24: return "24-Hour Clock"
        }
    }

    public var isWallClockFormat: Bool {
        self == .clock12 || self == .clock24
    }
}

/// What a countdown or scheduled-start overlay shows once the remaining time
/// reaches zero.
public enum TimerZeroBehavior: String, Codable, CaseIterable, Sendable {
    /// Hold at the zero reading (`0:00`).
    case hold
    /// Paint nothing (the layer disappears until reset/restarted).
    case hide
    /// Show `zeroMessage` instead (an empty message paints nothing).
    case message
    /// Immediately start the next lap: a countdown re-anchors to its full
    /// duration; a scheduled start rolls to the following day's occurrence.
    case restart

    public var displayName: String {
        switch self {
        case .hold: return "Hold at Zero"
        case .hide: return "Hide"
        case .message: return "Show Message"
        case .restart: return "Restart"
        }
    }
}

/// G04 (issue #111): the CONFIGURATION half of a timer overlay — durable
/// scene content carried on the layer's `TextSourcePayload`, so it stages,
/// Takes, reverts, and undoes with the layer (the `setLayerText` precedent).
/// Runtime transport state is deliberately NOT here (see the file header).
public struct TimerOverlayConfiguration: Hashable, Codable, Sendable {
    /// Copies of a layer share transport until explicitly made independent.
    public var runtimeID: UUID = UUID()
    public var kind: TimerOverlayKind = .countdown
    /// The countdown's full duration in seconds, 1...86400.
    public var durationSeconds: Double = 300
    public var format: TimerDisplayFormat = .hMMss
    /// Zero-time rule for countdown/scheduled start.
    public var zeroBehavior: TimerZeroBehavior = .hold
    /// The string `zeroBehavior == .message` shows at zero.
    public var zeroMessage: String = "Time's up!"
    /// Scheduled-start target time of day, in `timeZoneIdentifier`.
    public var targetHour: Int = 9
    public var targetMinute: Int = 0
    /// IANA timezone identifier for clock/scheduled-start; empty = the
    /// system zone. Unknown identifiers fall back to the system zone at
    /// render time (the honest fallback — an exported project still renders).
    public var timeZoneIdentifier: String = ""

    public init(runtimeID: UUID = UUID(), kind: TimerOverlayKind = .countdown,
                durationSeconds: Double = 300,
                format: TimerDisplayFormat = .hMMss,
                zeroBehavior: TimerZeroBehavior = .hold,
                zeroMessage: String = "Time's up!",
                targetHour: Int = 9,
                targetMinute: Int = 0,
                timeZoneIdentifier: String = "") {
        self.runtimeID = runtimeID
        self.kind = kind
        self.durationSeconds = durationSeconds
        self.format = format
        self.zeroBehavior = zeroBehavior
        self.zeroMessage = zeroMessage
        self.targetHour = targetHour
        self.targetMinute = targetMinute
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    /// Decode every field with a default (the established additive-wire
    /// pattern), so documents written by any version keep loading.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runtimeID = try container.decodeIfPresent(UUID.self, forKey: .runtimeID) ?? UUID()
        kind = try container.decodeIfPresent(TimerOverlayKind.self, forKey: .kind) ?? .countdown
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 300
        format = try container.decodeIfPresent(TimerDisplayFormat.self, forKey: .format) ?? .hMMss
        zeroBehavior = try container.decodeIfPresent(TimerZeroBehavior.self, forKey: .zeroBehavior)
            ?? .hold
        zeroMessage = try container.decodeIfPresent(String.self, forKey: .zeroMessage) ?? "Time's up!"
        targetHour = try container.decodeIfPresent(Int.self, forKey: .targetHour) ?? 9
        targetMinute = try container.decodeIfPresent(Int.self, forKey: .targetMinute) ?? 0
        timeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
            ?? ""
    }

    /// The value with every field clamped to its documented range.
    public func clamped() -> TimerOverlayConfiguration {
        var copy = self
        copy.durationSeconds = durationSeconds.isFinite ? min(86_400, max(1, durationSeconds)) : 300
        copy.targetHour = min(23, max(0, targetHour))
        copy.targetMinute = min(59, max(0, targetMinute))
        if copy.zeroMessage.count > 200 {
            copy.zeroMessage = String(copy.zeroMessage.prefix(200))
        }
        return copy
    }

    /// The rejection reason for an out-of-range value, or nil (the
    /// `TextTitleStyle.validationError` precedent).
    public var validationError: String? {
        guard durationSeconds.isFinite else {
            return "The countdown duration must be a finite number."
        }
        guard (1...86_400).contains(durationSeconds) else {
            return "The countdown duration must be between 1 and 86400 seconds."
        }
        guard (0...23).contains(targetHour), (0...59).contains(targetMinute) else {
            return "The scheduled time must be a valid time of day."
        }
        guard zeroMessage.count <= 200 else {
            return "The zero-time message must be 200 characters or fewer."
        }
        return nil
    }
}

// MARK: - Transport state machine

/// G04 (issue #111): the RUNTIME half of an elapsed timer — pure value,
/// parametrized on `now` in the common media clock's domain (host-clock
/// seconds). Stored per playback ID in the StreamMac `TimerOverlayStore`, shared
/// by preview and program; wall-clock kinds never touch it.
///
/// The one rule that makes sharing safe: `start` on a RUNNING timer is a
/// no-op. Preview sampling never mutates, and re-selecting/re-staging a scene
/// never touches the store, so a running program timer is never unexpectedly
/// reset — only an explicit `reset` returns it to idle.
public struct TimerRuntimeState: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        /// Never started (or reset): countdown reads its full duration,
        /// stopwatch reads zero.
        case idle
        case running
        case paused
    }

    public private(set) var phase: Phase = .idle
    /// Elapsed seconds banked by completed run segments (pause banks the
    /// current segment; resume starts a fresh one).
    public private(set) var bankedSeconds: Double = 0
    /// The clock timestamp the current run segment anchored at.
    public private(set) var anchorSeconds: Double = 0

    public init() {}

    /// Starts from idle, resumes from paused, and is a deliberate no-op
    /// while running (a second start never resets a live timer).
    public mutating func start(at now: Double) {
        guard now.isFinite else { return }
        switch phase {
        case .running: break
        case .idle, .paused:
            anchorSeconds = now
            phase = .running
        }
    }

    /// Freezes the elapsed reading. No-op unless running.
    public mutating func pause(at now: Double) {
        guard phase == .running, now.isFinite else { return }
        bankedSeconds += max(0, now - anchorSeconds)
        phase = .paused
    }

    /// Returns to idle with a zeroed elapsed — the ONLY way a running timer
    /// re-anchors from zero.
    public mutating func reset() {
        phase = .idle
        bankedSeconds = 0
        anchorSeconds = 0
    }

    /// The elapsed seconds at `now`.
    public func elapsed(at now: Double) -> Double {
        switch phase {
        case .running: return bankedSeconds + (now.isFinite ? max(0, now - anchorSeconds) : 0)
        case .idle, .paused: return bankedSeconds
        }
    }
}

// MARK: - Formatting and timezone rules

/// G04 (issue #111): the pure formatting/timezone half — every function is
/// over explicit values (epoch seconds and identifiers in, strings out), so
/// the simulator tests pin the exact strings.
public enum TimerDisplay {
    /// The timezone an identifier names: empty or unknown resolves to the
    /// system zone (the documented honest fallback).
    public static func resolvedTimeZone(identifier: String) -> TimeZone {
        guard !identifier.isEmpty, let zone = TimeZone(identifier: identifier) else {
            return .current
        }
        return zone
    }

    /// The elapsed/remaining reading. `roundsUp` is the countdown convention
    /// (ceil, so `5:00` holds until the reading truly crosses below it);
    /// stopwatches pass false (floor). Negative input clamps to zero. A
    /// wall-clock format picked for an elapsed value falls back to `hMMss`.
    public static func elapsedString(seconds: Double,
                                     format: TimerDisplayFormat,
                                     roundsUp: Bool) -> String {
        // Keep conversion to Int safe even for malformed timestamps.
        let clamped = seconds.isFinite ? min(315_576_000, max(0, seconds)) : 0
        switch format {
        case .tenths:
            let ticks = Int((clamped * 10).rounded(roundsUp ? .up : .down))
            let whole = ticks / 10
            let fraction = ticks % 10
            return String(format: "%d:%02d.%d", whole / 60, whole % 60, fraction)
        case .seconds:
            let total = Int(roundsUp ? clamped.rounded(.up) : clamped.rounded(.down))
            return "\(total)"
        case .hMMss, .clock12, .clock24:
            let total = Int(roundsUp ? clamped.rounded(.up) : clamped.rounded(.down))
            if total >= 3600 {
                return String(format: "%d:%02d:%02d", total / 3600,
                              (total % 3600) / 60, total % 60)
            }
            return String(format: "%d:%02d", total / 60, total % 60)
        case .mmss:
            let total = Int(roundsUp ? clamped.rounded(.up) : clamped.rounded(.down))
            return String(format: "%d:%02d", total / 60, total % 60)
        }
    }

    /// The wall-clock reading for `epochSeconds` in the configured timezone.
    /// An elapsed format picked for a clock falls back to `clock24`.
    public static func wallClockString(epochSeconds: TimeInterval,
                                       format: TimerDisplayFormat,
                                       timeZoneIdentifier: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = resolvedTimeZone(identifier: timeZoneIdentifier)
        let components = calendar.dateComponents(
            [.hour, .minute], from: Date(timeIntervalSince1970: epochSeconds))
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        switch format {
        case .clock12:
            let isPM = hour >= 12
            let hour12 = hour % 12 == 0 ? 12 : hour % 12
            return String(format: "%d:%02d %@", hour12, minute, isPM ? "PM" : "AM")
        case .clock24, .hMMss, .mmss, .seconds, .tenths:
            return String(format: "%02d:%02d", hour, minute)
        }
    }

    /// The epoch seconds of `hour:minute` on the SAME calendar day as
    /// `nowEpoch` in the configured timezone.
    public static func scheduledEpoch(onDayOf nowEpoch: TimeInterval,
                                      hour: Int,
                                      minute: Int,
                                      timeZoneIdentifier: String) -> TimeInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = resolvedTimeZone(identifier: timeZoneIdentifier)
        let now = Date(timeIntervalSince1970: nowEpoch)
        let day = calendar.dateComponents([.year, .month, .day], from: now)
        var target = DateComponents()
        target.year = day.year
        target.month = day.month
        target.day = day.day
        target.hour = hour
        target.minute = minute
        return calendar.date(from: target)?.timeIntervalSince1970 ?? nowEpoch
    }

    /// The next occurrence of `hour:minute` in the configured timezone
    /// strictly after `nowEpoch` — today's when it hasn't passed, tomorrow's
    /// otherwise (calendar arithmetic, so DST transitions stay honest).
    public static func nextScheduledEpoch(after nowEpoch: TimeInterval,
                                          hour: Int,
                                          minute: Int,
                                          timeZoneIdentifier: String) -> TimeInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = resolvedTimeZone(identifier: timeZoneIdentifier)
        return calendar.nextDate(after: Date(timeIntervalSince1970: nowEpoch),
                                 matching: DateComponents(hour: hour, minute: minute, second: 0),
                                 matchingPolicy: .nextTime, repeatedTimePolicy: .first)?
            .timeIntervalSince1970 ?? nowEpoch + 86_400
    }
}

// MARK: - Sampling

/// G04 (issue #111): one resolved reading of a timer overlay. `text` is the
/// string the renderer rasterizes this tick (nil = paint nothing — the
/// `hide` zero behavior); `displaySeconds` backs the inspector's live
/// readout (remaining for countdown/scheduled, elapsed for stopwatch).
public struct TimerOverlaySample: Equatable, Sendable {
    public var text: String?
    public var phase: TimerRuntimeState.Phase
    public var isFinished: Bool
    public var displaySeconds: Double

    public init(text: String?, phase: TimerRuntimeState.Phase,
                isFinished: Bool, displaySeconds: Double) {
        self.text = text
        self.phase = phase
        self.isFinished = isFinished
        self.displaySeconds = displaySeconds
    }
}

/// G04 (issue #111): the pure resolver — configuration + runtime state +
/// both clocks in, sample out. The StreamMac `TimerOverlayStore` calls this
/// per tick per timer layer; it never mutates state, so any number of
/// engines can sample the same layer concurrently.
public enum TimerOverlayResolver {
    public static func sample(configuration configuration: TimerOverlayConfiguration,
                              state: TimerRuntimeState,
                              engineSeconds: Double,
                              wallClockEpoch: TimeInterval) -> TimerOverlaySample {
        let config = configuration.clamped()
        switch config.kind {
        case .stopwatch:
            let elapsed = state.elapsed(at: engineSeconds)
            return TimerOverlaySample(
                text: TimerDisplay.elapsedString(seconds: elapsed, format: config.format,
                                                 roundsUp: false),
                phase: state.phase, isFinished: false, displaySeconds: elapsed)

        case .countdown:
            let duration = config.durationSeconds
            let elapsed = state.elapsed(at: engineSeconds)
            var remaining = duration - elapsed
            // An idle countdown reads its full duration and is never finished.
            let finished = state.phase != .idle && remaining <= 0
            if finished {
                if case .restart = config.zeroBehavior {
                    // Wrap into the current lap: the remainder lands back at
                    // the full duration the moment a lap boundary is crossed.
                    let lap = elapsed.truncatingRemainder(dividingBy: duration)
                    remaining = lap == 0 ? duration : duration - lap
                } else {
                    return TimerOverlaySample(text: zeroText(for: config),
                                              phase: state.phase, isFinished: true,
                                              displaySeconds: 0)
                }
            }
            return TimerOverlaySample(
                text: TimerDisplay.elapsedString(seconds: remaining, format: config.format,
                                                 roundsUp: true),
                phase: state.phase, isFinished: false, displaySeconds: max(0, remaining))

        case .clock:
            return TimerOverlaySample(
                text: TimerDisplay.wallClockString(epochSeconds: wallClockEpoch,
                                                   format: config.format,
                                                   timeZoneIdentifier: config.timeZoneIdentifier),
                phase: state.phase, isFinished: false, displaySeconds: 0)

        case .scheduledStart:
            let today = TimerDisplay.scheduledEpoch(onDayOf: wallClockEpoch,
                                                    hour: config.targetHour,
                                                    minute: config.targetMinute,
                                                    timeZoneIdentifier: config.timeZoneIdentifier)
            var remaining = today - wallClockEpoch
            if remaining <= 0 {
                if case .restart = config.zeroBehavior {
                    remaining = TimerDisplay.nextScheduledEpoch(after: wallClockEpoch,
                                                                hour: config.targetHour,
                                                                minute: config.targetMinute,
                                                                timeZoneIdentifier: config.timeZoneIdentifier)
                        - wallClockEpoch
                } else {
                    return TimerOverlaySample(text: zeroText(for: config),
                                              phase: state.phase, isFinished: true,
                                              displaySeconds: 0)
                }
            }
            return TimerOverlaySample(
                text: TimerDisplay.elapsedString(seconds: remaining, format: config.format,
                                                 roundsUp: true),
                phase: state.phase, isFinished: false, displaySeconds: remaining)
        }
    }

    /// The zero-time reading for the non-restart behaviors: the formatted
    /// zero, nothing (`hide`), or the configured message (empty = nothing).
    private static func zeroText(for config: TimerOverlayConfiguration) -> String? {
        switch config.zeroBehavior {
        case .hold:
            return TimerDisplay.elapsedString(seconds: 0, format: config.format, roundsUp: true)
        case .hide:
            return nil
        case .message:
            return config.zeroMessage.isEmpty ? nil : config.zeroMessage
        case .restart:
            return nil // unreachable — restart never finishes
        }
    }
}
