import CoreGraphics
import CoreImage
import Foundation
import StreamCore

/// One converter per bounded program subscription, called serially off-main.
final class ExternalProgramImageConverter: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false, .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    func image(_ frame: CompositedFrame) -> CGImage? {
        guard let buffer = frame.pixelBuffer else { return nil }
        // The broker completed any selected-canvas aspect-fit/letterbox into
        // this admitted private bank before invoking the subscription callback.
        let image = CIImage(cvPixelBuffer: buffer)
        return context.createCGImage(image, from: image.extent, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB), deferred: true)
    }
}
