import CoreImage
import CoreMediaIO
import Foundation
import StreamCore

enum VirtualCameraFormat: String, CaseIterable, Sendable {
    case hd720, hd1080
    var width: Int { self == .hd720 ? 1280 : 1920 }
    var height: Int { self == .hd720 ? 720 : 1080 }
    var label: String { "\(width) × \(height), 30 fps" }
}

/// Core Media I/O's public output queue transports samples into the camera's
/// sink stream. The framework performs IPC to the sandboxed role-user daemon.
final class VirtualCameraProducer: @unchecked Sendable {
    struct Failure: Error { var message: String }
    private let lock = NSLock()
    private let device: CMIODeviceID
    private let stream: CMIOStreamID
    private let queue: CMSimpleQueue
    private let pool: CVPixelBufferPool
    private let description: CMVideoFormatDescription
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let outputRect: CGRect
    private let canvas: CGSize?
    private var accepting = true
    private var lastPTS = CMTime.invalid
    private var sent: UInt64 = 0
    private var dropped: UInt64 = 0
    static func address(_ selector: CMIOObjectPropertySelector, scope: CMIOObjectPropertyScope = CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal)) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }
    private static func objects(_ object: CMIOObjectID, selector: CMIOObjectPropertySelector, scope: CMIOObjectPropertyScope = CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal)) -> [CMIOObjectID] {
        var property = address(selector, scope: scope), bytes: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &property, 0, nil, &bytes) == noErr, bytes > 0, bytes <= 4096, bytes % 4 == 0 else { return [] }
        var values = [CMIOObjectID](repeating: 0, count: Int(bytes) / 4), used = bytes
        let status = values.withUnsafeMutableBytes { CMIOObjectGetPropertyData(object, &property, 0, nil, bytes, &used, $0.baseAddress!) }
        return status == noErr && used == bytes ? values : []
    }
    static func discover() -> (device: CMIODeviceID, sink: CMIOStreamID)? {
        for device in objects(CMIOObjectID(kCMIOObjectSystemObject), selector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices)) {
            var property = address(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID))
            var uid: CFString?, used: UInt32 = 0
            let bytes = UInt32(MemoryLayout<CFString?>.size)
            guard CMIOObjectGetPropertyData(device, &property, 0, nil, bytes, &used, &uid) == noErr,
                  let uid, (uid as String).caseInsensitiveCompare(VirtualCameraContract.deviceID.uuidString) == .orderedSame else { continue }
            let sinks = objects(device, selector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams), scope: CMIOObjectPropertyScope(kCMIODevicePropertyScopeOutput))
            if sinks.count == 1 { return (device, sinks[0]) }
        }
        return nil
    }
    init(format: VirtualCameraFormat, canvas: CGSize?) throws {
        guard let target = Self.discover() else { throw Failure(message: "Activate Stream Studio Camera and refresh its device state first.") }
        device = target.device; stream = target.sink; self.canvas = canvas
        outputRect = CGRect(x: 0, y: 0, width: format.width, height: format.height)
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
            width: Int32(format.width), height: Int32(format.height), extensions: nil, formatDescriptionOut: &description) == noErr,
              let description else { throw Failure(message: "The camera format could not be allocated.") }
        self.description = description
        var property = Self.address(CMIOObjectPropertySelector(kCMIOStreamPropertyFormatDescription))
        var selected: CMFormatDescription = description
        guard CMIOObjectSetPropertyData(stream, &property, 0, nil, UInt32(MemoryLayout<CMFormatDescription>.size), &selected) == noErr else {
            throw Failure(message: "The camera rejected this input format. Stop and choose a supported format.")
        }
        var bufferQueue: Unmanaged<CMSimpleQueue>?
        guard CMIOStreamCopyBufferQueue(stream, nil, nil, &bufferQueue) == noErr, let bufferQueue else { throw Failure(message: "The camera input queue is unavailable.") }
        queue = bufferQueue.takeRetainedValue()
        guard CMSimpleQueueGetCapacity(queue) <= 2 else { throw Failure(message: "The camera input queue exceeds its supported capacity.") }
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
            [kCVPixelBufferWidthKey: format.width, kCVPixelBufferHeightKey: format.height, kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
             kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pool) == kCVReturnSuccess, let pool else { throw Failure(message: "The camera buffer pool is unavailable.") }
        self.pool = pool
        guard CMIODeviceStartStream(device, stream) == noErr else { throw Failure(message: "The signed studio could not start the extension's input stream.") }
    }
    var statistics: (sent: UInt64, dropped: UInt64) { lock.lock(); defer { lock.unlock() }; return (sent, dropped) }
    func append(_ frame: CompositedFrame) {
        lock.lock(); defer { lock.unlock() }
        guard accepting, let input = frame.pixelBuffer else { return }
        let pts = frame.presentationTime
        guard pts.isValid, !pts.isIndefinite, pts.seconds.isFinite else { dropped += 1; return }
        if lastPTS.isValid, CMTimeCompare(CMTimeSubtract(pts, lastPTS), CMTime(value: 1, timescale: 30)) < 0 { return }
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { dropped += 1; return }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
            [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary, &output) == kCVReturnSuccess, let output else { dropped += 1; return }
        let raw = CIImage(cvPixelBuffer: input)
        let reference = canvas.map { CGRect(origin: .zero, size: $0) } ?? raw.extent
        let scale = min(reference.width / raw.extent.width, reference.height / raw.extent.height)
        let placed = raw.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).transformed(by: CGAffineTransform(
            translationX: (reference.width - raw.extent.width * scale) / 2, y: (reference.height - raw.extent.height * scale) / 2))
        let canvasImage = placed.composited(over: CIImage(color: .black).cropped(to: reference))
        let fit = min(outputRect.width / reference.width, outputRect.height / reference.height)
        let fitted = canvasImage.transformed(by: CGAffineTransform(scaleX: fit, y: fit)).transformed(by: CGAffineTransform(
            translationX: (outputRect.width - reference.width * fit) / 2, y: (outputRect.height - reference.height * fit) / 2))
        context.render(fitted.composited(over: CIImage(color: .black).cropped(to: outputRect)), to: output, bounds: outputRect, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: output, dataReady: true, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { dropped += 1; return }
        let retained = Unmanaged.passRetained(sample)
        if CMSimpleQueueEnqueue(queue, element: retained.toOpaque()) == noErr { sent += 1; lastPTS = pts }
        else { retained.release(); dropped += 1 }
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        accepting = false
        CMIODeviceStopStream(device, stream)
        // StopStream closes this producer's IPC stream before queued ownership
        // is reclaimed; other camera consumers continue with black frames.
        while let element = CMSimpleQueueDequeue(queue) { Unmanaged<CMSampleBuffer>.fromOpaque(element).release() }
    }
    deinit { stop() }
}
