import Foundation

/// Spoken gain values must also tolerate older or externally edited documents.
/// This describes the stored value without changing or clamping playback gain.
enum StudioGainAccessibility {
    static func value(_ gain: Double) -> String {
        guard gain.isFinite else { return "Volume unavailable" }
        let percent = gain * 100
        guard percent.isFinite else {
            // Scaling a finite Double may overflow. Keep the original finite
            // value and name its unit rather than displaying infinity or a cap.
            return String(format: "%.6g times unity gain", gain)
        }
        if abs(percent) >= 1_000_000_000 {
            return String(format: "%.6g percent", percent)
        }
        return String(format: "%.0f percent", percent == 0 ? 0 : percent)
    }
}
