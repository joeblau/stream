import Foundation

/// The mic-stall failover predicate, shared by both publishers.
///
/// HaishinKit's multitrack mixer renders the audio mix only when the MAIN track
/// (mic, track 0) appends, so a silently dead mic route would mute app audio too.
/// When app audio (track 1) is still flowing but the mic has gone quiet, the
/// publisher promotes track 1 to the mix clock; the first mic buffer back flips it
/// home. This is the pure timing decision behind that failover.
///
/// Extracted from `RTMPPublisher.checkNetworkHealth` so the SRT/WHIP session
/// publisher gains the same failover, and so the thresholds are unit-tested.
public enum MicStallEvaluator {
    /// App audio counts as "still flowing" only if a buffer arrived within this window.
    public static let appFreshWindow: UInt64 = 2_000_000_000   // 2s
    /// The mic is considered stalled after this long with no buffer.
    public static let micStallThreshold: UInt64 = 4_000_000_000 // 4s

    /// Whether app audio should take over the mix clock. The caller pre-checks the
    /// preconditions (`includeAppAudio`, not already stalled, capture live) and owns
    /// the mixer re-apply; this is only the timing test. Uses wrapping subtraction to
    /// match the publisher's `uptimeNanoseconds` arithmetic.
    ///
    /// `startedAt` is when the broadcast went live. When the mic has NEVER produced a
    /// buffer (`lastMicAppendAt == 0`) its silence is measured from go-live, so a mic
    /// route that is dead from the start still promotes app audio — otherwise the main
    /// (mic) track never appends and HaishinKit renders the WHOLE mix silent, dropping
    /// the flowing app audio too.
    public static func shouldPromoteApp(now: UInt64,
                                        lastMicAppendAt: UInt64,
                                        lastAppAppendAt: UInt64,
                                        startedAt: UInt64) -> Bool {
        let micReference = lastMicAppendAt > 0 ? lastMicAppendAt : startedAt
        return now &- lastAppAppendAt < appFreshWindow && now &- micReference > micStallThreshold
    }
}
