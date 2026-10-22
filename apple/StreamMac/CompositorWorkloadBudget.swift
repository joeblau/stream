import Foundation
import StreamCore

/// Shared Program/Clean/Secondary compositor ceiling. Multiple subscribers to
/// the same clean renderer count once; presentation and encoding are separate.
enum CompositorWorkloadBudget {
    static let maximumPixelsPerSecond = Double(3840 * 2160 * 30)
    static func pixels(_ profile: OutputProfile) -> Double {
        Double(profile.canvasWidth) * Double(profile.canvasHeight) * Double(profile.frameRate)
    }
    static func cleanStartError(program: OutputProfile, secondary: OutputProfile?, qualified: Bool) -> String? {
        guard qualified else { return "Additional composition is not qualified on this Mac class." }
        guard pixels(program) * 2 + (secondary.map(pixels) ?? 0) <= maximumPixelsPerSecond else {
            return "Clean return exceeds the compositor budget (4K30 total pixels per second)."
        }
        return nil
    }
    static func secondaryStartError(program: OutputProfile, secondary: OutputProfile, cleanDemanded: Bool) -> String? {
        guard pixels(program) * (cleanDemanded ? 2 : 1) + pixels(secondary) <= maximumPixelsPerSecond else {
            return "Both canvases exceed the compositor budget (4K30 total pixels per second). Reduce their size or frame rate before starting outputs."
        }
        return nil
    }
}

/// Revocation closes extra rendering synchronously, before actor teardown can
/// drain. Its budget reservation is released only after removal is acknowledged.
final class ExternalCleanRenderPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var accepting = true
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return accepting }
    func finish() { lock.lock(); accepting = false; lock.unlock() }
}
