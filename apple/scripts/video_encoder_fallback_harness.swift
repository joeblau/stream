import AVFoundation
import VideoToolbox

struct ProbeLogger {
  func info(_ items: Any...) {}
  func warn(_ items: Any...) { print(items) }
}
let logger = ProbeLogger()
final class Frames: @unchecked Sendable {
  let lock = NSLock()
  var values: [CMSampleBuffer] = []
  func add(_ value: CMSampleBuffer) {
    lock.lock()
    values.append(value)
    lock.unlock()
  }
}
final class Pixels: @unchecked Sendable {
  let lock = NSLock()
  var count = 0
  var red = 0
  func add(_ image: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(image, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    let bytes = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
    let offset = 90 * CVPixelBufferGetBytesPerRow(image) + 160 * 4
    lock.lock()
    count += 1
    if bytes[offset + 2] > 180 && bytes[offset] < 80 { red += 1 }
    lock.unlock()
  }
}
@main struct Probe {
  static func main() throws {
    for requested in [nil, false, true] as [Bool?] {
      for initial in [kVTParameterErr, kVTInvalidSessionErr] {
        var attempts = 0
        let spec: CFDictionary? = requested.map {
          [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: $0] as CFDictionary
        }
        do {
          _ = try VTCompressionSessionFactory.make(encoderSpecification: spec) { _, _ in
            attempts += 1
            return attempts == 1 ? initial : kVTVideoEncoderMalfunctionErr
          }
          preconditionFailure("Failed encoder was accepted")
        } catch VTSessionError.failedToCreate(let status) {
          let retries = requested == true && initial == kVTParameterErr
          precondition(attempts == (retries ? 2 : 1))
          precondition(status == (retries ? kVTVideoEncoderMalfunctionErr : initial))
        }
      }
    }
    print(
      "PASS: six refusal cases preserve other errors, absent/false requests, one-retry bound and failed fallback"
    )
    let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
    var attempts: [OSStatus] = []
    let specification =
      [
        kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: false,
        kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
      ] as CFDictionary
    let encoder = try VTCompressionSessionFactory.make(encoderSpecification: specification) {
      spec, session in
      let values = spec as? [String: Any]
      precondition(
        values?[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String]
          as? Bool == false)
      let lowLatency = values?[kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String]
      precondition(attempts.isEmpty ? lowLatency as? Bool == true : lowLatency == nil)
      precondition(values?.count == (attempts.isEmpty ? 2 : 1))
      let status = VTCompressionSessionCreate(
        allocator: nil, width: 320, height: 180, codecType: kCMVideoCodecType_H264,
        encoderSpecification: spec, imageBufferAttributes: attrs, compressedDataAllocator: nil,
        outputCallback: nil, refcon: nil, compressionSessionOut: &session)
      attempts.append(status)
      return status
    }
    defer { VTCompressionSessionInvalidate(encoder) }
    precondition(attempts == [kVTParameterErr, noErr])
    let settings = VideoCodecSettings(
      videoSize: .init(width: 320, height: 180), bitRate: 4_000_000,
      profileLevel: kVTProfileLevel_H264_Main_AutoLevel as String, scalingMode: .letterbox,
      allowFrameReordering: false, isLowLatencyRateControlEnabled: true,
      isHardwareAcceleratedEnabled: true, expectedFrameRate: 25)
    precondition(encoder.setOptions(settings.makeOptions()) == 0)
    precondition(encoder.prepareToEncodeFrames() == 0)
    precondition(encoder.setOption(.init(key: .expectedFrameRate, value: 25 as CFNumber)) == 0)
    let frames = Frames()
    for index in 0..<10 {
      var image: CVPixelBuffer?
      precondition(
        CVPixelBufferCreate(
          nil, 320, 180, kCVPixelFormatType_32BGRA,
          [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image) == 0)
      CVPixelBufferLockBaseAddress(image!, [])
      let bytes = CVPixelBufferGetBaseAddress(image!)!.assumingMemoryBound(to: UInt8.self)
      let row = CVPixelBufferGetBytesPerRow(image!)
      for y in 0..<180 {
        for x in 0..<320 {
          bytes[y * row + x * 4] = 0
          bytes[y * row + x * 4 + 1] = 0
          bytes[y * row + x * 4 + 2] = 255
          bytes[y * row + x * 4 + 3] = 255
        }
      }
      CVPixelBufferUnlockBaseAddress(image!, [])
      precondition(
        VTCompressionSessionEncodeFrame(
          encoder, imageBuffer: image!,
          presentationTimeStamp: CMTime(value: Int64(index), timescale: 25),
          duration: CMTime(value: 1, timescale: 25), frameProperties: nil, infoFlagsOut: nil,
          outputHandler: { status, _, sample in
            precondition(status == 0)
            if let sample { frames.add(sample) }
          }) == 0)
    }
    precondition(
      VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid) == 0)
    precondition(frames.values.count == 10)
    var decoder: VTDecompressionSession?
    precondition(
      VTDecompressionSessionCreate(
        allocator: nil, formatDescription: frames.values[0].formatDescription!,
        decoderSpecification: nil, imageBufferAttributes: attrs, outputCallback: nil,
        decompressionSessionOut: &decoder) == 0)
    let pixels = Pixels()
    defer { VTDecompressionSessionInvalidate(decoder!) }
    for frame in frames.values {
      precondition(
        VTDecompressionSessionDecodeFrame(
          decoder!, sampleBuffer: frame, flags: [], infoFlagsOut: nil,
          outputHandler: { status, _, image, _, _ in
            precondition(status == 0)
            if let image { pixels.add(image) }
          }) == 0)
    }
    precondition(VTDecompressionSessionWaitForAsynchronousFrames(decoder!) == 0)
    precondition(pixels.count == 10 && pixels.red == 10)
    // Exercise the actual codec's source-attribute derivation, independently of
    // the factory. Its received CMSampleBuffer describes BGRA, never 'vide'.
    var input: CVPixelBuffer?
    precondition(CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, nil, &input) == 0)
    CVPixelBufferLockBaseAddress(input!, [])
    memset(CVPixelBufferGetBaseAddress(input!)!, 0, CVPixelBufferGetDataSize(input!))
    CVPixelBufferUnlockBaseAddress(input!, [])
    var inputFormat: CMVideoFormatDescription?
    precondition(
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: nil, imageBuffer: input!, formatDescriptionOut: &inputFormat) == 0)
    var inputSample: CMSampleBuffer?
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 25),
      presentationTimeStamp: CMTime(value: 1, timescale: 25), decodeTimeStamp: .invalid)
    precondition(
      CMSampleBufferCreateForImageBuffer(
        allocator: nil, imageBuffer: input!, dataReady: true, makeDataReadyCallback: nil,
        refcon: nil, formatDescription: inputFormat!, sampleTiming: &timing,
        sampleBufferOut: &inputSample) == 0)
    let codec = VideoCodec()
    codec.settings = settings
    _ = codec.outputStream
    codec.startRunning()
    defer { codec.stopRunning() }
    codec.append(inputSample!)
    precondition(codec.session != nil)
    let supplied =
      codec.makeImageBufferAttributes(.compression)?[kCVPixelBufferPixelFormatTypeKey] as? NSNumber
    precondition(supplied?.uint32Value == kCVPixelFormatType_32BGRA)
    print("PASS: actual VideoCodec derives BGRA pixel subtype from received sample")
    print(
      "PASS: actual software low-latency create=\(attempts[0]), ordinary create=\(attempts[1]); exact shipping options/prepare;10 BGRA frames ->10 H264 frames ->10 decoded red frames"
    )
  }
}
