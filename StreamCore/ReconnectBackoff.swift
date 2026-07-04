import Foundation

/// The reconnect backoff ladder shared by both publishers. Jittered exponential
/// backoff, retained across short-lived successful connects and reset only on a
/// proven-stable connection or a fresh network route.
///
/// Extracted from `RTMPPublisher` (which previously inlined a bare
/// `nextRecoveryDelay: UInt64`) so the SRT/WHIP session publisher gains the same
/// jitter + reset semantics it lacked, and so the ladder is unit-tested on CI.
///
/// Semantics (identical to the RTMP original):
/// - starts at `base` (1s)
/// - `escalate()` doubles, capped at `cap` (30s) — call ONLY after a FAILED attempt
/// - `reset()` returns to `base` — call on success, on a 30s-stable connection, and
///   when a fresh route appears
/// - `jittered()` multiplies the current delay by a 0.8...1.2 random factor
public struct ReconnectBackoff: Sendable, Equatable {
    /// Initial delay: a reconnect that SUCCEEDS costs ~1s next time.
    public static let base: UInt64 = 1_000_000_000
    /// Ceiling: consecutive failures grow the delay only up to 30s.
    public static let cap: UInt64 = 30_000_000_000

    public private(set) var current: UInt64

    public init() { current = Self.base }

    /// Back to the 1s base. Used on a successful reconnect, after 30s of stable
    /// publishing, and when a fresh network route appears.
    public mutating func reset() { current = Self.base }

    /// Double the delay, capped at 30s. Call ONLY after a failed attempt — growing
    /// on success turned a burst of recoverable false recycles into long dead-air.
    public mutating func escalate() { current = min(current * 2, Self.cap) }

    /// The current delay with jitter applied. `rng` is injectable for tests; the
    /// production range is 0.8...1.2 to spread reconnect storms.
    public func jittered(_ rng: () -> Double = { .random(in: 0.8...1.2) }) -> UInt64 {
        UInt64(Double(current) * rng())
    }
}
