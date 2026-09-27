import CoreImage
import CoreMedia
import CoreVideo
import Metal
import StreamCore

/// Composites the facecam `CVPixelBuffer` into a rounded corner box over the
/// screen `CVPixelBuffer`, using ONE reused Metal-backed `CIContext` and ONE
/// `CVPixelBufferPool` sized to the screen frame. Designed for minimal
/// per-frame allocations during simultaneous capture and encoding.
final class FacecamCompositor {

    private let ciContext: CIContext
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var outputFormatDescription: CMVideoFormatDescription?
    private let workingColorSpace = CGColorSpaceCreateDeviceRGB()
    /// Reused corner-rounding mask generator. `CIFilter(name:)` is a registry
    /// lookup plus an NSObject allocation; at 60 fps for the life of a broadcast
    /// that is pure churn, and the filter is stateless between frames.
    private let roundedRectangleGenerator = CIFilter(name: "CIRoundedRectangleGenerator")
    /// The last mask produced by `roundedRectangleGenerator`, keyed by the geometry
    /// that produced it. The facecam box only moves when the user drags it to
    /// another corner or resizes it, so the mask is otherwise identical every frame.
    private var cachedMask: CIImage?
    private var cachedMaskRect: CGRect = .null
    private var cachedMaskRadius: CGFloat = -1

    init() {
        // `.cacheIntermediates: false` matters more here than in a one-shot render:
        // this context renders continuously for the length of a broadcast, and the
        // intermediate cache is memory that never pays off across frames.
        let options: [CIContextOption: Any] = [
            .workingColorSpace: NSNull(),
            .cacheIntermediates: false
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device, options: options)
        } else {
            // Simulator / no Metal device: fall back to a software context so
            // the type still functions (and compiles) everywhere.
            ciContext = CIContext(options: options)
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

        // Composite over black so any letterbox/pillarbox margin is clean. The
        // canvas is derived from this same screen's aspect ratio, so in the normal
        // case the fitted image covers it exactly and the blend is a full-frame pass
        // over pixels that are all about to be overwritten — skip it then.
        if !screenImage.extent.contains(canvas) {
            screenImage = screenImage.composited(over: CIImage(color: .black).cropped(to: canvas))
        }

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
        // Never let a slow encoder turn the pool into an unbounded collection of
        // BGRA surfaces — but the steady state genuinely needs four: one being
        // rendered here, one inside the mixer's single input buffer, one pinned by
        // the publisher's frame-repeat `lastVideoBuffer`, and one of slack. A
        // threshold of two put the pipeline permanently one buffer short, so any
        // encoder hiccup failed the allocation and shed the frame
        // (`telemetry.recordDrop(.compositor)`) even on a healthy uplink.
        let allocationLimit = [
            kCVPixelBufferPoolAllocationThresholdKey as String: 4
        ] as CFDictionary
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pool,
            allocationLimit,
            &out
        ) == kCVReturnSuccess,
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

        let format: CMVideoFormatDescription
        if let outputFormatDescription {
            format = outputFormatDescription
        } else {
            var created: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &created) == noErr,
                  let created else { return nil }
            outputFormatDescription = created
            format = created
        }

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
        outputFormatDescription = nil
        return newPool
    }

    private func applyRoundedCorners(_ image: CIImage,
                                     radius: CGFloat,
                                     rect: CGRect) -> CIImage {
        guard let mask = roundedCornerMask(radius: radius, rect: rect) else { return image }
        return image.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask
        ])
    }

    /// The facecam box's rounded-corner mask. Its geometry only changes when the
    /// user moves or resizes the overlay, so the generated mask is reused across
    /// every frame in between.
    private func roundedCornerMask(radius: CGFloat, rect: CGRect) -> CIImage? {
        if let cachedMask, cachedMaskRect == rect, cachedMaskRadius == radius {
            return cachedMask
        }
        guard let generator = roundedRectangleGenerator else { return nil }
        generator.setValue(CIVector(cgRect: rect), forKey: "inputExtent")
        generator.setValue(radius, forKey: "inputRadius")
        generator.setValue(CIColor.white, forKey: "inputColor")
        guard let mask = generator.outputImage else { return nil }
        cachedMask = mask
        cachedMaskRect = rect
        cachedMaskRadius = radius
        return mask
    }
}
