import CoreGraphics
import CoreImage
import Foundation

/// Eligibility runs before the broker borrows/copies a renderer frame. Conversion
/// runs serially on this recipient's private-frame queue, with no second throttle.
final class PreviewImageConverter: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var lastUpdateAt: UInt64 = 0

    func admitsFrame(throttleNanoseconds: UInt64) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock(); defer { lock.unlock() }
        guard now &- lastUpdateAt >= throttleNanoseconds else { return false }
        lastUpdateAt = now
        return true
    }
    func makeImage(_ frame: CompositedFrame) -> CGImage? {
        guard let buffer = frame.pixelBuffer else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        // Keep the provider tied to this admitted private CV backing. Do not
        // eagerly produce separately allocated, uncharged image snapshots.
        return context.createCGImage(image, from: image.extent, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB), deferred: true)
    }
}
