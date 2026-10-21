import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

private final class ReturnVideoResult: @unchecked Sendable {
    private let lock = NSLock()
    private var sample: CMSampleBuffer?, status: OSStatus = noErr
    func receive(_ status: OSStatus, _ sample: CMSampleBuffer?) {
        lock.lock(); self.status = status; self.sample = sample; lock.unlock()
    }
    func take() throws -> CMSampleBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard status == noErr else { throw NativeGuestReturnAudioError.codec }
        return sample
    }
}
struct NativeGuestReturnH264Frame: Sendable {
    let data: Data
    let rtp: UInt32, ntp: UInt64
}

/// One serial capacity-one Program consumer owns this encoder. Every submitted
/// frame is completed before accepting another; source PTS is never restamped.
/// The fixed low ceiling is 320x180, 15fps and 250kbps, with no upscaling.
final class NativeGuestReturnVideoEncoder {
    private var session: VTCompressionSession?
    private var width = 0, height = 0
    private var nextPTS = CMTime.invalid
    private var forceKeyframe = true
    #if STREAM_GUEST_VALIDATION
    var validationBeforeCompletion: (@Sendable () -> Void)?
    private(set) var validationSessionActive = false
    #endif
    private let context = CIContext(options: [.cacheIntermediates: false])
    func requestKeyframe() { forceKeyframe = true }
    func close() {
        if let session { VTCompressionSessionInvalidate(session) }
        #if STREAM_GUEST_VALIDATION
        validationSessionActive = false
        #endif
        session = nil; nextPTS = .invalid; forceKeyframe = true
    }
    deinit { close() }
    private func prepare(width: Int, height: Int) throws {
        close(); self.width = width; self.height = height; forceKeyframe = true
        var created: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &created) == noErr, let created else { throw NativeGuestReturnAudioError.unavailable }
        session = created
        #if STREAM_GUEST_VALIDATION
        validationSessionActive = true
        #endif
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Baseline_3_1,
            kVTCompressionPropertyKey_AverageBitRate: 250_000,
            kVTCompressionPropertyKey_DataRateLimits: [31_250, 1],
            kVTCompressionPropertyKey_ExpectedFrameRate: 15,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 1,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 15
        ]
        guard VTSessionSetProperties(created, propertyDictionary: properties as CFDictionary) == noErr,
              VTCompressionSessionPrepareToEncodeFrames(created) == noErr else { throw NativeGuestReturnAudioError.unavailable }
    }
    func encode(_ frame: GuestReturnVideoFrame) throws -> NativeGuestReturnH264Frame? {
        let pts = frame.pts
        guard pts.isNumeric, let input = frame.sample.imageBuffer else { throw NativeGuestReturnAudioError.malformed }
        if nextPTS.isNumeric, CMTimeCompare(pts, nextPTS) < 0 { return nil }
        let iw = CVPixelBufferGetWidth(input), ih = CVPixelBufferGetHeight(input)
        guard iw >= 2, ih >= 2, iw <= 8192, ih <= 8192 else { throw NativeGuestReturnAudioError.malformed }
        let scale = min(1, min(320 / Double(iw), 180 / Double(ih)))
        let w = max(2, Int(Double(iw) * scale) / 2 * 2), h = max(2, Int(Double(ih) * scale) / 2 * 2)
        if session == nil || width != w || height != h { try prepare(width: w, height: h) }
        guard let session else { throw NativeGuestReturnAudioError.unavailable }
        var pixels: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels) == kCVReturnSuccess,
            let pixels else { throw NativeGuestReturnAudioError.codec }
        let image = CIImage(cvPixelBuffer: input).transformed(by: .init(scaleX: Double(w) / Double(iw), y: Double(h) / Double(ih)))
        context.render(image, to: pixels, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let result = ReturnVideoResult()
        let properties = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        guard VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: pts,
            duration: frame.sample.duration, frameProperties: properties, infoFlagsOut: nil,
            outputHandler: { status, _, sample in result.receive(status, sample) }) == noErr else {
            throw NativeGuestReturnAudioError.codec
        }
        #if STREAM_GUEST_VALIDATION
        validationBeforeCompletion?()
        #endif
        guard VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: pts) == noErr else {
            throw NativeGuestReturnAudioError.codec
        }
        guard let encoded = try result.take() else { return nil }
        forceKeyframe = false
        let step = CMTime(value: 1, timescale: 15)
        if !nextPTS.isNumeric || (pts - nextPTS).seconds > 1 { nextPTS = pts + step }
        else { repeat { nextPTS = nextPTS + step } while CMTimeCompare(nextPTS, pts) <= 0 }
        let data = try Self.annexB(encoded)
        let seconds = pts.seconds + NativeGuestReturnClock.ntpHostOffset
        guard seconds > 0, seconds < Double(UInt32.max) else { throw NativeGuestReturnAudioError.malformed }
        let whole = UInt64(seconds.rounded(.down)), fraction = UInt64((seconds - Double(whole)) * 4_294_967_296)
        return .init(data: data,
            rtp: UInt32(truncatingIfNeeded: CMTimeConvertScale(pts, timescale: 90_000, method: .roundHalfAwayFromZero).value),
            ntp: whole << 32 | fraction)
    }
    private static func annexB(_ sample: CMSampleBuffer) throws -> Data {
        guard let block = sample.dataBuffer, let format = sample.formatDescription,
              CMBlockBufferGetDataLength(block) > 0, CMBlockBufferGetDataLength(block) <= 65_536 else {
            throw NativeGuestReturnAudioError.malformed
        }
        var data = Data(), nalLength: Int32 = 0
        var pointer: UnsafePointer<UInt8>?, size = 0, count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
            parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &nalLength) == noErr, nalLength == 4, count == 2 else {
            throw NativeGuestReturnAudioError.malformed
        }
        // Parameter sets on every access unit make recovery independent of
        // retained frames from a previous lease or an expired decoder buffer.
        for index in 0..<2 {
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil) == noErr, let pointer, size > 0, size <= 4096 else { throw NativeGuestReturnAudioError.malformed }
            data.append(contentsOf: [0, 0, 0, 1]); data.append(pointer, count: size)
        }
        var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
        let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        guard status == noErr else { throw NativeGuestReturnAudioError.malformed }
        var offset = 0, nals = 0
        while offset < bytes.count {
            guard offset + 4 <= bytes.count, nals < 62 else { throw NativeGuestReturnAudioError.malformed }
            let length = bytes[offset..<offset + 4].reduce(0) { $0 * 256 + Int($1) }; offset += 4
            guard length > 0, length <= bytes.count - offset, data.count + 4 + length <= 65_536 else { throw NativeGuestReturnAudioError.malformed }
            data.append(contentsOf: [0, 0, 0, 1]); data.append(contentsOf: bytes[offset..<offset + length]); offset += length; nals += 1
        }
        return data
    }
}
