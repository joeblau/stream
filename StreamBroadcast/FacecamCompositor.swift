import CoreImage
import CoreMedia
import CoreVideo
import Metal
import StreamCore

/// Composites the facecam `CVPixelBuffer` into a rounded corner box over the
/// screen `CVPixelBuffer`, using ONE reused Metal-backed `CIContext` and ONE
/// `CVPixelBufferPool` sized to the screen frame. Designed for minimal
/// per-frame allocations to respect the ~50MB extension budget.
final class FacecamCompositor {

    private let ciContext: CIContext
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private let workingColorSpace = CGColorSpaceCreateDeviceRGB()

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device,
                                  options: [.workingColorSpace: NSNull()])
        } else {
            // Simulator / no Metal device: fall back to a software context so
            // the type still functions (and compiles) everywhere.
            ciContext = CIContext(options: [.workingColorSpace: NSNull()])
        }
    }

    // MARK: - Public API

    /// Renders the (oriented) `screen` frame into a fixed `targetSize` canvas —
    /// aspect-fit over black, so portrait/landscape and any minor aspect mismatch
    /// are handled without distortion — then composites the optional `camera`
    /// facecam into the chosen corner. Output is a pooled buffer of exactly
    /// `targetSize`, matching the encoder so VideoToolbox does not re-scale.
    func composite(screen: CVPixelBuffer,
                   camera: CVPixelBuffer?,
                   targetSize: CGSize,
                   orientation: CGImagePropertyOrientation,
                   corner: PIPCorner,
                   scale: Double,
                   cameraPosition: CameraPosition) -> CVPixelBuffer? {

        let outWidth = Int(targetSize.width.rounded())
        let outHeight = Int(targetSize.height.rounded())
        guard outWidth > 1, outHeight > 1 else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: outWidth, height: outHeight)

        // Orient the screen upright, then aspect-FIT it (centered) into the canvas.
        let oriented = CIImage(cvPixelBuffer: screen).oriented(orientation)
        let src = oriented.extent
        guard src.width > 0, src.height > 0 else { return nil }
        let fit = min(canvas.width / src.width, canvas.height / src.height)
        let tx = (canvas.width - src.width * fit) / 2 - src.minX * fit
        let ty = (canvas.height - src.height * fit) / 2 - src.minY * fit
        var screenImage = oriented
            .transformed(by: CGAffineTransform(scaleX: fit, y: fit))
            .transformed(by: CGAffineTransform(translationX: tx, y: ty))

        // Composite over black so any letterbox/pillarbox margin is clean.
        screenImage = screenImage.composited(over: CIImage(color: .black).cropped(to: canvas))

        if let camera {
            // Mirror the front camera so the user sees a natural reflection.
            let camOrientation: CGImagePropertyOrientation =
                cameraPosition == .front ? .upMirrored : .up
            var cam = CIImage(cvPixelBuffer: camera).oriented(camOrientation)
            let camExtent = cam.extent

            if camExtent.width > 0, camExtent.height > 0 {
                let clampedScale = max(0.10, min(0.40, CGFloat(scale)))
                let boxW = canvas.width * clampedScale
                let boxH = boxW * (camExtent.height / camExtent.width)
                let inset: CGFloat = 24

                // Aspect-fill the camera into the box.
                let fillScale = max(boxW / camExtent.width, boxH / camExtent.height)
                cam = cam.transformed(by: CGAffineTransform(scaleX: fillScale,
                                                            y: fillScale))

                // Position the box by corner (relative to the canvas) with an inset.
                let originX: CGFloat
                let originY: CGFloat
                switch corner {
                case .topLeft:
                    originX = canvas.minX + inset
                    originY = canvas.maxY - boxH - inset
                case .topRight:
                    originX = canvas.maxX - boxW - inset
                    originY = canvas.maxY - boxH - inset
                case .bottomLeft:
                    originX = canvas.minX + inset
                    originY = canvas.minY + inset
                case .bottomRight:
                    originX = canvas.maxX - boxW - inset
                    originY = canvas.minY + inset
                }

                // Translate the (already scaled) camera so its lower-left aligns
                // with the box origin, then crop to the box rectangle.
                let placed = cam.transformed(by: CGAffineTransform(
                    translationX: originX - cam.extent.minX,
                    y: originY - cam.extent.minY))
                let boxRect = CGRect(x: originX, y: originY, width: boxW, height: boxH)
                let cropped = placed.cropped(to: boxRect)

                let rounded = applyRoundedCorners(cropped, radius: 16, rect: boxRect)
                screenImage = rounded.composited(over: screenImage)
            }
        }

        guard let pool = ensurePool(width: outWidth, height: outHeight) else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess,
              let outBuffer = out else { return nil }

        ciContext.render(screenImage,
                         to: outBuffer,
                         bounds: canvas,
                         colorSpace: workingColorSpace)
        return outBuffer
    }

    /// Wraps a composited `CVPixelBuffer` in a `CMSampleBuffer`, copying timing
    /// from the source screen sample buffer.
    func makeSampleBuffer(from pixelBuffer: CVPixelBuffer,
                          timingSource: CMSampleBuffer) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(timingSource, at: 0, timingInfoOut: &timing)

        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription) == noErr,
              let format = formatDescription else { return nil }

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer) == noErr else { return nil }

        return sampleBuffer
    }

    // MARK: - Private

    private func ensurePool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let pool, width == poolWidth, height == poolHeight {
            return pool
        }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        var newPool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                                      attrs as CFDictionary, &newPool) == kCVReturnSuccess else {
            return nil
        }
        pool = newPool
        poolWidth = width
        poolHeight = height
        return newPool
    }

    private func applyRoundedCorners(_ image: CIImage,
                                     radius: CGFloat,
                                     rect: CGRect) -> CIImage {
        guard let generator = CIFilter(name: "CIRoundedRectangleGenerator") else {
            return image
        }
        generator.setValue(CIVector(cgRect: rect), forKey: "inputExtent")
        generator.setValue(radius, forKey: "inputRadius")
        generator.setValue(CIColor.white, forKey: "inputColor")
        guard let mask = generator.outputImage else { return image }
        return image.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask
        ])
    }
}
