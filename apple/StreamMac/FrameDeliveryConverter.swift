import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import IOSurface

enum FrameDeliveryTransferError: Error {
    case invalidFrame, unsupportedFormat, invalidGeometry, aliasedStorage
    case copyFailed, renderFailed, sampleFailed, cadenceSkipped
}

/// Only successful camera enqueues advance this clock, matching the original
/// producer's pre-conversion 30 fps check. This short lock is never held across
/// CI, CMIO, a consumer callback or any asynchronous operation.
final class FrameDeliveryCameraCadence: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPTS = CMTime.invalid
    func permits(_ pts: CMTime) -> Bool {
        guard pts.isNumeric else { return false }
        lock.lock(); defer { lock.unlock() }
        return !lastPTS.isNumeric || CMTimeCompare(pts - lastPTS, CMTime(value: 1, timescale: 30)) >= 0
    }
    func didEnqueue(_ pts: CMTime) {
        lock.lock(); defer { lock.unlock() }
        if !lastPTS.isNumeric || CMTimeCompare(pts, lastPTS) > 0 { lastPTS = pts }
    }
}

/// The broker is the only caller that may hand this helper a compositor borrow.
/// It owns no pool and invokes no consumer, codec or CMIO operation. Allocation
/// belongs to the admitted bank; a successful return contains only that bank's
/// completed private pixels and bounded value metadata.
final class FrameDeliveryConverter: @unchecked Sendable {
    private let context: CIContext?

    init() { context = CIContext(options: [.cacheIntermediates: false]) }
    private init(copyOnly: Void) { context = nil }

    static func copy(source: CMSampleBuffer, into bank: RawVideoResourceBank) throws -> CMSampleBuffer {
        let output = try bank.allocatePixelBuffer()
        return try FrameDeliveryConverter(copyOnly: ()).prepare(source, into: output, transfer: .copyBGRA)
    }

    func prepare(_ source: CMSampleBuffer, into output: CVPixelBuffer,
                 transfer: FrameDeliveryTransfer) throws -> CMSampleBuffer {
        guard CMSampleBufferDataIsReady(source), CMSampleBufferGetNumSamples(source) == 1,
              CMSampleBufferGetPresentationTimeStamp(source).isNumeric,
              let input = CMSampleBufferGetImageBuffer(source) else { throw FrameDeliveryTransferError.invalidFrame }
        try Self.validate(input)
        try Self.validate(output)
        guard input !== output else { throw FrameDeliveryTransferError.aliasedStorage }
        if let from = CVPixelBufferGetIOSurface(input)?.takeUnretainedValue(),
           let to = CVPixelBufferGetIOSurface(output)?.takeUnretainedValue(),
           IOSurfaceGetID(from) == IOSurfaceGetID(to) { throw FrameDeliveryTransferError.aliasedStorage }

        let duration: CMTime, decodeTime: CMTime
        switch transfer {
        case .copyBGRA:
            try Self.copyPixels(input, into: output)
            try Self.copyColorMetadata(input, into: output)
            duration = CMSampleBufferGetDuration(source)
            decodeTime = CMSampleBufferGetDecodeTimeStamp(source)
        case .aspectFitBGRA:
            try render(input, into: output, referenceCanvas: nil)
            duration = CMSampleBufferGetDuration(source)
            decodeTime = CMSampleBufferGetDecodeTimeStamp(source)
        case .virtualCameraBGRA(let referenceCanvas, let cadence):
            guard cadence?.permits(CMSampleBufferGetPresentationTimeStamp(source)) != false else {
                throw FrameDeliveryTransferError.cadenceSkipped
            }
            if let referenceCanvas {
                guard referenceCanvas.width.isFinite, referenceCanvas.height.isFinite,
                      referenceCanvas.width > 0, referenceCanvas.height > 0,
                      referenceCanvas.width <= 4096, referenceCanvas.height <= 4096 else {
                    throw FrameDeliveryTransferError.invalidGeometry
                }
            }
            try render(input, into: output, referenceCanvas: referenceCanvas)
            duration = CMTime(value: 1, timescale: 30)
            decodeTime = .invalid
        }
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: output,
            formatDescriptionOut: &description) == noErr, let description else { throw FrameDeliveryTransferError.sampleFailed }
        var timing = CMSampleTimingInfo(duration: duration,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(source),
            decodeTimeStamp: decodeTime)
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: output,
            formatDescription: description, sampleTiming: &timing, sampleBufferOut: &result) == noErr,
              let result else { throw FrameDeliveryTransferError.sampleFailed }
        if case .copyBGRA = transfer {
            // This metadata deliberately does not propagate through Core Media.
            // Decode/validate/re-encode its bounded values instead of retaining
            // an arbitrary source attachment graph or losing recorder evidence.
            RecordingChatPaint.attach(RecordingChatPaint.read(source), to: result)
        }
        return result
    }

    private static func validate(_ image: CVPixelBuffer) throws {
        guard CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA,
              !CVPixelBufferIsPlanar(image) else { throw FrameDeliveryTransferError.unsupportedFormat }
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
        guard (1...4096).contains(width), (1...4096).contains(height) else { throw FrameDeliveryTransferError.invalidGeometry }
        let (rowBytes, overflow) = width.multipliedReportingOverflow(by: 4)
        let stride = CVPixelBufferGetBytesPerRow(image)
        let (storage, storageOverflow) = stride.multipliedReportingOverflow(by: height)
        guard !overflow, !storageOverflow, stride >= rowBytes,
              storage > 0, storage <= 64 * 1024 * 1024,
              CVPixelBufferGetDataSize(image) >= storage else { throw FrameDeliveryTransferError.invalidGeometry }
    }

    private static func copyPixels(_ input: CVPixelBuffer, into output: CVPixelBuffer) throws {
        let width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input)
        guard width == CVPixelBufferGetWidth(output), height == CVPixelBufferGetHeight(output) else {
            throw FrameDeliveryTransferError.invalidGeometry
        }
        guard CVPixelBufferLockBaseAddress(input, .readOnly) == kCVReturnSuccess else { throw FrameDeliveryTransferError.copyFailed }
        defer { CVPixelBufferUnlockBaseAddress(input, .readOnly) }
        guard CVPixelBufferLockBaseAddress(output, []) == kCVReturnSuccess else { throw FrameDeliveryTransferError.copyFailed }
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        guard let from = CVPixelBufferGetBaseAddress(input), let to = CVPixelBufferGetBaseAddress(output), from != to else {
            throw FrameDeliveryTransferError.aliasedStorage
        }
        let sourceStride = CVPixelBufferGetBytesPerRow(input), targetStride = CVPixelBufferGetBytesPerRow(output)
        let activeRowBytes = width * 4
        if sourceStride == activeRowBytes, targetStride == activeRowBytes {
            memcpy(to, from, activeRowBytes * height)
        } else {
            // Every active byte is overwritten by the copy. Only destination
            // padding needs clearing; never copy a source's padding bytes.
            let padding = targetStride - activeRowBytes
            for row in 0..<height {
                let destination = to.advanced(by: row * targetStride)
                memcpy(destination, from.advanced(by: row * sourceStride), activeRowBytes)
                if padding > 0 { memset(destination.advanced(by: activeRowBytes), 0, padding) }
            }
        }
    }

    private func render(_ input: CVPixelBuffer, into output: CVPixelBuffer, referenceCanvas: CGSize?) throws {
        guard let context else { throw FrameDeliveryTransferError.renderFailed }
        let raw = CIImage(cvPixelBuffer: input)
        let target = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(output), height: CVPixelBufferGetHeight(output))
        let image: CIImage
        if let referenceCanvas {
            // Preserve the camera's existing two-stage fit: first into the
            // selected canvas, then fit that canvas into the negotiated format.
            let reference = CGRect(origin: .zero, size: referenceCanvas)
            let placed = Self.fit(raw, into: reference).composited(over: CIImage(color: .black).cropped(to: reference))
            image = Self.fit(placed, into: target)
        } else {
            image = Self.fit(raw, into: target)
        }
        let finished = image.composited(over: CIImage(color: .black).cropped(to: target))
        let destination = CIRenderDestination(pixelBuffer: output)
        destination.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        do {
            // Submission alone does not end the source borrow. Wait for actual
            // Core Image completion before returning to the opaque consumer.
            let task = try context.startTask(toRender: finished, from: target, to: destination, at: .zero)
            _ = try task.waitUntilCompleted()
        } catch { throw FrameDeliveryTransferError.renderFailed }
    }

    private static func fit(_ image: CIImage, into target: CGRect) -> CIImage {
        let scale = min(target.width / image.extent.width, target.height / image.extent.height)
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: target.midX - image.extent.midX * scale,
                                             y: target.midY - image.extent.midY * scale))
    }

    private static func copyColorMetadata(_ input: CVPixelBuffer, into output: CVPixelBuffer) throws {
        // Property-list round-tripping makes these bounded values independent.
        // In particular, no CMSampleBuffer/CVPixelBuffer attachment can escape.
        let keys: [CFString] = [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey,
            kCVImageBufferYCbCrMatrixKey, kCVImageBufferGammaLevelKey, kCVImageBufferICCProfileKey,
            kCVImageBufferPixelAspectRatioKey, kCVImageBufferCleanApertureKey]
        var remaining = 65_536
        for key in keys {
            CVBufferRemoveAttachment(output, key)
            guard let raw = CVBufferCopyAttachment(input, key, nil) else { continue }
            guard boundedPropertyList(raw, depth: 0, remaining: &remaining),
                  PropertyListSerialization.propertyList(raw, isValidFor: .binary),
                  let encoded = try? PropertyListSerialization.data(fromPropertyList: raw, format: .binary, options: 0),
                  encoded.count <= 16_384,
                  let value = try? PropertyListSerialization.propertyList(from: encoded, options: [], format: nil) else {
                throw FrameDeliveryTransferError.unsupportedFormat
            }
            CVBufferSetAttachment(output, key, value as CFTypeRef, .shouldPropagate)
        }
        CVBufferRemoveAttachment(output, kCVImageBufferCGColorSpaceKey)
        if let raw = CVBufferCopyAttachment(input, kCVImageBufferCGColorSpaceKey, nil) {
            guard CFGetTypeID(raw) == CGColorSpace.typeID else { throw FrameDeliveryTransferError.unsupportedFormat }
            let color = unsafeDowncast(raw, to: CGColorSpace.self)
            guard color.model == .rgb else { throw FrameDeliveryTransferError.unsupportedFormat }
            if let name = color.name, CFStringGetLength(name) <= 128, let owned = CGColorSpace(name: name) {
                CVBufferSetAttachment(output, kCVImageBufferCGColorSpaceKey, owned, .shouldPropagate)
            } else if CFEqual(color, CGColorSpaceCreateDeviceRGB()) {
                // The compositor's existing working space is DeviceRGB.
                // Recreate that fixed space instead of flattening to sRGB or
                // retaining an unbounded arbitrary ICC profile from input.
                CVBufferSetAttachment(output, kCVImageBufferCGColorSpaceKey, CGColorSpaceCreateDeviceRGB(), .shouldPropagate)
            } else { throw FrameDeliveryTransferError.unsupportedFormat }
        }
    }

    private static func boundedPropertyList(_ value: CFTypeRef, depth: Int, remaining: inout Int) -> Bool {
        guard depth <= 4, remaining > 0 else { return false }
        switch CFGetTypeID(value) {
        case CFDataGetTypeID():
            let size = CFDataGetLength(unsafeDowncast(value, to: CFData.self))
            guard size <= 16_384, size <= remaining else { return false }
            remaining -= size; return true
        case CFStringGetTypeID():
            // Bound the native object BEFORE any Swift Data/String bridge or
            // property-list serialization could allocate a large temporary.
            let length = CFStringGetLength(unsafeDowncast(value, to: CFString.self))
            guard length <= 128, length * 4 <= remaining else { return false }
            remaining -= length * 4; return true
        case CFNumberGetTypeID():
            var number = 0.0
            guard CFNumberGetValue(unsafeDowncast(value, to: CFNumber.self), .doubleType, &number),
                  number.isFinite, remaining >= 16 else { return false }
            remaining -= 16; return true
        case CFBooleanGetTypeID():
            guard remaining >= 16 else { return false }
            remaining -= 16; return true
        case CFDictionaryGetTypeID():
            let dictionary = unsafeDowncast(value, to: CFDictionary.self)
            let count = CFDictionaryGetCount(dictionary)
            guard count <= 16 else { return false }
            var keys = [UnsafeRawPointer?](repeating: nil, count: count)
            var values = [UnsafeRawPointer?](repeating: nil, count: count)
            keys.withUnsafeMutableBufferPointer { keyBuffer in
                values.withUnsafeMutableBufferPointer { valueBuffer in
                    CFDictionaryGetKeysAndValues(dictionary, keyBuffer.baseAddress, valueBuffer.baseAddress)
                }
            }
            for index in 0..<count {
                guard let key = keys[index], let child = values[index],
                      boundedPropertyList(Unmanaged<AnyObject>.fromOpaque(key).takeUnretainedValue(), depth: depth + 1, remaining: &remaining),
                      boundedPropertyList(Unmanaged<AnyObject>.fromOpaque(child).takeUnretainedValue(), depth: depth + 1, remaining: &remaining) else { return false }
            }
            return true
        default: return false
        }
    }
}
