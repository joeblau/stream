import Foundation

/// A single frame-boundary snapshot prevents project overlays, annotations or
/// an in-flight Take from escaping the explicitly held offline slate.
final class ProgramPrivacyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var scene: Scene?
    func setScene(_ scene: Scene?) { lock.lock(); self.scene = scene; lock.unlock() }
    func sceneSnapshot() -> Scene? { lock.lock(); defer { lock.unlock() }; return scene }
    func overlays() -> OverlayContext { sceneSnapshot() == nil ? ProjectOverlayStore.shared.snapshot() : .empty }
    func annotations() -> AnnotationRenderSnapshot { sceneSnapshot() == nil ? ProgramAnnotationStore.shared.snapshot() : .empty }
}
