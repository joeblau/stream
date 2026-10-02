import CoreGraphics
import CoreImage
import Foundation
import StreamCore

/// One converter per bounded program subscription, called serially off-main.
final class ExternalProgramImageConverter: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false, .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    private let canvas: CGRect?
    init(profile: OutputProfile?) { canvas = profile.map { CGRect(origin: .zero, size: $0.canvasSize) } }
    func image(_ frame: CompositedFrame) -> CGImage? {
        guard let buffer = frame.pixelBuffer else { return nil }
        let raw = CIImage(cvPixelBuffer: buffer)
        guard let canvas else { return context.createCGImage(raw, from: raw.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) }
        let scale = min(canvas.width / raw.extent.width, canvas.height / raw.extent.height)
        let scaled = raw.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let centered = scaled.transformed(by: CGAffineTransform(translationX: (canvas.width - scaled.extent.width) / 2 - scaled.extent.minX,
                                                               y: (canvas.height - scaled.extent.height) / 2 - scaled.extent.minY))
        let background = CIImage(color: .black).cropped(to: canvas)
        return context.createCGImage(centered.composited(over: background), from: canvas, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
