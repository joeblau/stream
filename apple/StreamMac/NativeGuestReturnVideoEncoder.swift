import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import StreamCore
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
enum NativeGuestReturnVideoError: Error { case accessUnitTooLarge, privateCapacityOccupied }
struct NativeGuestReturnH264Frame: Sendable {
    let data: Data
    /// Exact RTP packets plus the SDK's per-AU compound sender report.
    let sendBytes: UInt32
    let rtp: UInt32, ntp: UInt64
}

/// One serial capacity-one Program consumer owns this encoder. Every submitted
/// frame is completed before accepting another; source PTS is never restamped.
/// A measured profile sets an upper bound; source frames are never upscaled or duplicated.
final class NativeGuestReturnVideoEncoder {
    private var session: VTCompressionSession?
    private(set) var profile: NativeGuestReturnVideoProfile = .low
    func setProfile(_ value: NativeGuestReturnVideoProfile) {
        guard profile != value else { return }
        // Same owner/reservation spans invalidation and the next allocation.
        invalidate(resetCadence: false); profile = value
    }
    private var width = 0, height = 0
    private var nextPTS = CMTime.invalid
    private var forceKeyframe = true
    private(set) var privateCapacityDrops = 0
    private let resourceWorkspace = UUID()
    private var ownedResources: (token: UUID, width: Int, height: Int,
                                 resources: GuestReturnVideoResources, receipt: RawVideoResourceReceipt)?
    #if STREAM_GUEST_VALIDATION
    var validationBeforeCompletion: (@Sendable () -> Void)?
    private(set) var validationSessionActive = false
    var validationDimensions: (Int, Int) { (width, height) }
    #endif
    private let context = CIContext(options: [.cacheIntermediates: false])
    func requestKeyframe() { forceKeyframe = true }
    func close() {
        invalidate(resetCadence: true)
        if let ownedResources { RawVideoResourceCoordinator.shared.rollback(ownedResources.receipt) }
        ownedResources = nil
    }
    private func invalidate(resetCadence: Bool) {
        if let session { VTCompressionSessionInvalidate(session) }
        #if STREAM_GUEST_VALIDATION
        validationSessionActive = false
        #endif
        session = nil; if resetCadence { nextPTS = .invalid }; forceKeyframe = true
    }
    deinit { close() }
    private func prepare(width: Int, height: Int) throws {
        invalidate(resetCadence: false); self.width = width; self.height = height; forceKeyframe = true
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
            kVTCompressionPropertyKey_AverageBitRate: profile.maximumBitrate,
            kVTCompressionPropertyKey_DataRateLimits: [profile.maximumBitrate / 8, 1],
            kVTCompressionPropertyKey_ExpectedFrameRate: profile.framesPerSecond,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 1,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: profile.framesPerSecond
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
        let raster = try GuestReturnVideoResources.raster(sourceWidth: iw, sourceHeight: ih, profile: profile)
        let w = raster.width, h = raster.height
        // Shipping frames carry the conversion banks admitted by their source
        // installation. Direct owned callers use the same admission contract
        // before creating VT, rather than an unbounded CVPixelBufferCreate.
        let resources = try frame.resources ?? prepareOwnedResources(token: frame.token, width: iw, height: ih)
        let pixels: CVPixelBuffer
        do { pixels = try resources.allocate(raster) }
        catch RawVideoResourceFailure.capacityOccupied {
            privateCapacityDrops = min(privateCapacityDrops, Int.max - 1) + 1
            // The sender's existing failure path retires this output. Returning
            // nil here would report a stalled bank as ordinary cadence shedding.
            throw NativeGuestReturnVideoError.privateCapacityOccupied
        }
        autoreleasepool {
            let image = CIImage(cvPixelBuffer: input).transformed(by: .init(scaleX: Double(w) / Double(iw), y: Double(h) / Double(ih)))
            context.render(image, to: pixels, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        if session == nil || width != w || height != h { try prepare(width: w, height: h) }
        guard let session else { throw NativeGuestReturnAudioError.unavailable }
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
        let step = CMTime(value: 1, timescale: CMTimeScale(profile.framesPerSecond))
        if !nextPTS.isNumeric || (pts - nextPTS).seconds > 1 { nextPTS = pts + step }
        else { repeat { nextPTS = nextPTS + step } while CMTimeCompare(nextPTS, pts) <= 0 }
        let data = try Self.annexB(encoded)
        let seconds = pts.seconds + NativeGuestReturnClock.ntpHostOffset
        guard seconds > 0, seconds < Double(UInt32.max) else { throw NativeGuestReturnAudioError.malformed }
        let whole = UInt64(seconds.rounded(.down)), fraction = UInt64((seconds - Double(whole)) * 4_294_967_296)
        let projected = data.withUnsafeBytes { SGReturnH264SendBytes($0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        guard projected > 0 else { throw NativeGuestReturnAudioError.malformed }
        return .init(data: data, sendBytes: projected,
            rtp: UInt32(truncatingIfNeeded: CMTimeConvertScale(pts, timescale: 90_000, method: .roundHalfAwayFromZero).value),
            ntp: whole << 32 | fraction)
    }
    private func prepareOwnedResources(token: UUID, width: Int, height: Int) throws -> GuestReturnVideoResources {
        if let ownedResources, ownedResources.token == token,
           ownedResources.width == width, ownedResources.height == height { return ownedResources.resources }
        let plan = try GuestReturnVideoResources.plan(workspace: resourceWorkspace, outputID: "direct-return",
            generation: UUID(), sourceSize: CGSize(width: width, height: height), maximumProfile: .high)
        let receipt = try RawVideoResourceCoordinator.shared.reserveBatch(plan.requests)
        let resources: GuestReturnVideoResources
        do { resources = try .init(plan: plan, receipt: receipt) }
        catch { RawVideoResourceCoordinator.shared.rollback(receipt); throw error }
        let previous = ownedResources
        ownedResources = (token, width, height, resources, receipt)
        if let previous { RawVideoResourceCoordinator.shared.rollback(previous.receipt) }
        return resources
    }
    private static func containsIDR(_ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset + 4 < bytes.count {
            let length = bytes[offset..<offset + 4].reduce(0) { $0 * 256 + Int($1) }; offset += 4
            guard length > 0, length <= bytes.count - offset else { return false }
            if bytes[offset] & 31 == 5 { return true }; offset += length
        }
        return false
    }
    private static func annexB(_ sample: CMSampleBuffer) throws -> Data {
        guard let block = sample.dataBuffer, let format = sample.formatDescription,
              CMBlockBufferGetDataLength(block) > 0 else {
            throw NativeGuestReturnAudioError.malformed
        }
        guard CMBlockBufferGetDataLength(block) <= 65_536 else { throw NativeGuestReturnVideoError.accessUnitTooLarge }
        var data = Data(), nalLength: Int32 = 0
        var pointer: UnsafePointer<UInt8>?, size = 0, count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
            parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &nalLength) == noErr, nalLength == 4, count == 2 else {
            throw NativeGuestReturnAudioError.malformed
        }
        var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
        let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        guard status == noErr else { throw NativeGuestReturnAudioError.malformed }
        let idr = containsIDR(bytes)
        if idr {
            // Every lease, profile change and failed AU requests a fresh IDR.
            // Tiny inter frames do not repeat unnecessary parameter sets.
            for index in 0..<2 {
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil) == noErr, let pointer, size > 0, size <= 4096 else { throw NativeGuestReturnAudioError.malformed }
                data.append(contentsOf: [0, 0, 0, 1]); data.append(pointer, count: size)
            }
        }
        var offset = 0, nals = 0
        while offset < bytes.count {
            guard offset + 4 <= bytes.count, nals < 62 else { throw NativeGuestReturnAudioError.malformed }
            let length = bytes[offset..<offset + 4].reduce(0) { $0 * 256 + Int($1) }; offset += 4
            guard length > 0, length <= bytes.count - offset else { throw NativeGuestReturnAudioError.malformed }
            guard data.count + 4 + length <= 65_536 else { throw NativeGuestReturnVideoError.accessUnitTooLarge }
            data.append(contentsOf: [0, 0, 0, 1]); data.append(contentsOf: bytes[offset..<offset + length]); offset += length; nals += 1
        }
        return data
    }
}
