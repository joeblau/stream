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
    private let queue: CMSimpleQueue
    private let format: VirtualCameraFormat
    private let cadence: FrameDeliveryCameraCadence
    private let stopStream: @Sendable () -> Void
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
    /// Resource admission and the broker's target-sized bank are prepared by
    /// the controller before this constructor can touch the CMIO device.
    init(format: VirtualCameraFormat, cadence: FrameDeliveryCameraCadence = FrameDeliveryCameraCadence()) throws {
        guard let target = Self.discover() else { throw Failure(message: "Activate Stream Studio Camera and refresh its device state first.") }
        let device = target.device, stream = target.sink
        self.format = format
        self.cadence = cadence
        stopStream = { CMIODeviceStopStream(device, stream) }
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
            width: Int32(format.width), height: Int32(format.height), extensions: nil, formatDescriptionOut: &description) == noErr,
              let description else { throw Failure(message: "The camera format could not be allocated.") }
        var property = Self.address(CMIOObjectPropertySelector(kCMIOStreamPropertyFormatDescription))
        var selected: CMFormatDescription = description
        guard CMIOObjectSetPropertyData(stream, &property, 0, nil, UInt32(MemoryLayout<CMFormatDescription>.size), &selected) == noErr else {
            throw Failure(message: "The camera rejected this input format. Stop and choose a supported format.")
        }
        var bufferQueue: Unmanaged<CMSimpleQueue>?
        guard CMIOStreamCopyBufferQueue(stream, nil, nil, &bufferQueue) == noErr, let bufferQueue else { throw Failure(message: "The camera input queue is unavailable.") }
        queue = bufferQueue.takeRetainedValue()
        guard CMSimpleQueueGetCapacity(queue) <= 2 else { throw Failure(message: "The camera input queue exceeds its supported capacity.") }
        guard CMIODeviceStartStream(device, stream) == noErr else { throw Failure(message: "The signed studio could not start the extension's input stream.") }
    }
    #if STREAM_NATIVE_VALIDATION
    /// Only the selected CMIO transport effects are inert. The production
    /// queue ownership, format checks, cadence, enqueue and stop drain execute.
    init(validationQueue: CMSimpleQueue, format: VirtualCameraFormat,
         cadence: FrameDeliveryCameraCadence = FrameDeliveryCameraCadence(), stopStream: @escaping @Sendable () -> Void = {}) throws {
        guard CMSimpleQueueGetCapacity(validationQueue) > 0, CMSimpleQueueGetCapacity(validationQueue) <= 2 else {
            throw Failure(message: "The camera input queue exceeds its supported capacity.")
        }
        queue = validationQueue; self.format = format; self.cadence = cadence; self.stopStream = stopStream
    }
    #endif
    var statistics: (sent: UInt64, dropped: UInt64) { lock.lock(); defer { lock.unlock() }; return (sent, dropped) }
    /// Accepts ONLY the broker's completed target-sized private sample. There
    /// is no compositor frame, CI image, conversion task or source borrow in
    /// scope when the opaque CMIO queue is called.
    func appendPrepared(_ sample: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        guard CMSampleBufferDataIsReady(sample), CMSampleBufferGetNumSamples(sample) == 1,
              let input = CMSampleBufferGetImageBuffer(sample),
              CVPixelBufferGetPixelFormatType(input) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(input) == format.width, CVPixelBufferGetHeight(input) == format.height,
              CMTimeCompare(CMSampleBufferGetDuration(sample), CMTime(value: 1, timescale: 30)) == 0 else { dropped += 1; return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isNumeric else { dropped += 1; return }
        if lastPTS.isValid, CMTimeCompare(CMTimeSubtract(pts, lastPTS), CMTime(value: 1, timescale: 30)) < 0 { return }
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { dropped += 1; return }
        let retained = Unmanaged.passRetained(sample)
        if CMSimpleQueueEnqueue(queue, element: retained.toOpaque()) == noErr {
            sent += 1; lastPTS = pts; cadence.didEnqueue(pts)
        }
        else { retained.release(); dropped += 1 }
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        accepting = false
        stopStream()
        // StopStream closes this producer's IPC stream before queued ownership
        // is reclaimed; other camera consumers continue with black frames.
        while let element = CMSimpleQueueDequeue(queue) { Unmanaged<CMSampleBuffer>.fromOpaque(element).release() }
    }
    deinit { stop() }
}
