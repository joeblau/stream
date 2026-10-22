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
    enum StopResult: Equatable, Sendable {
        case confirmed, unconfirmed(OSStatus), inProgress
    }
    /// One native stream lifetime per process. A failed stop retains its exact
    /// transport core (queue, queued sample retains and admission completion).
    /// Keeping the core rather than a deinitializing producer avoids resurrection.
    private final class Registry: @unchecked Sendable {
        static let shared = Registry()
        private let lock = NSLock()
        private var reservation: UUID?
        private var pending: Transport?
        func reserve() throws -> UUID {
            lock.lock(); defer { lock.unlock() }
            guard reservation == nil else { throw Failure(message: "The previous camera transport still owns its stream. Stop it or retry its unconfirmed cleanup before starting another camera.") }
            let id = UUID(); reservation = id; return id
        }
        func release(_ id: UUID) {
            lock.lock(); defer { lock.unlock() }
            guard reservation == id else { return }
            reservation = nil; pending = nil
        }
        func quarantine(_ transport: Transport) {
            lock.lock(); defer { lock.unlock() }
            guard reservation == transport.id else { return }
            pending = transport
        }
        var occupied: Bool { lock.lock(); defer { lock.unlock() }; return reservation != nil }
        var quarantined: Transport? { lock.lock(); defer { lock.unlock() }; return pending }
    }
    private final class Transport: @unchecked Sendable {
        let id: UUID
        let queue: CMSimpleQueue
        let format: VirtualCameraFormat
        let cadence: FrameDeliveryCameraCadence
        let stopStream: @Sendable () -> OSStatus
        let lock = NSLock()
        var accepting = true
        var stopped = false
        var stopping = false
        var failedStatus: OSStatus?
        var revoke: (@Sendable () -> Void)?
        var completion: (@Sendable () -> Void)?
        var lastPTS = CMTime.invalid
        var sent: UInt64 = 0
        var dropped: UInt64 = 0
        init(id: UUID, queue: CMSimpleQueue, format: VirtualCameraFormat,
             cadence: FrameDeliveryCameraCadence, stopStream: @escaping @Sendable () -> OSStatus) {
            self.id = id; self.queue = queue; self.format = format; self.cadence = cadence; self.stopStream = stopStream
        }
        func bind(revoke: @escaping @Sendable () -> Void, completion: @escaping @Sendable () -> Void) {
            lock.lock()
            precondition(self.revoke == nil && self.completion == nil && !stopped && !stopping)
            self.revoke = revoke; self.completion = completion
            lock.unlock()
        }
        func stop(retry: Bool) -> StopResult {
            lock.lock()
            accepting = false
            if stopped { lock.unlock(); return .confirmed }
            if stopping { lock.unlock(); return .inProgress }
            if let failedStatus, !retry { lock.unlock(); return .unconfirmed(failedStatus) }
            stopping = true
            let revoke = self.revoke
            lock.unlock()
            revoke?()
            // CMIO may call back synchronously: never hold our ingress lock
            // across the native stop. No new enqueue can pass accepting=false.
            let status = stopStream()
            lock.lock()
            stopping = false
            guard status == noErr else {
                failedStatus = status
                lock.unlock()
                Registry.shared.quarantine(self)
                // CMSimpleQueue permits one dequeueing thread. A failed stop
                // does not authorize us to compete with its native consumer.
                return .unconfirmed(status)
            }
            stopped = true; failedStatus = nil
            while let element = CMSimpleQueueDequeue(queue) { Unmanaged<CMSampleBuffer>.fromOpaque(element).release() }
            let completion = self.completion
            self.revoke = nil; self.completion = nil
            lock.unlock()
            Registry.shared.release(id)
            completion?()
            return .confirmed
        }
    }
    private let transport: Transport
    static var hasOutstandingTransport: Bool { Registry.shared.occupied }
    static var hasUnconfirmedStop: Bool { Registry.shared.quarantined != nil }
    @discardableResult static func retryQuarantinedStop() -> StopResult {
        Registry.shared.quarantined?.stop(retry: true) ?? .confirmed
    }
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
        let reservation = try Registry.shared.reserve()
        var committed = false
        defer { if !committed { Registry.shared.release(reservation) } }
        guard let target = Self.discover() else { throw Failure(message: "Activate Stream Studio Camera and refresh its device state first.") }
        let device = target.device, stream = target.sink
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
        let queue = bufferQueue.takeRetainedValue()
        guard CMSimpleQueueGetCapacity(queue) > 0, CMSimpleQueueGetCapacity(queue) <= 2 else { throw Failure(message: "The camera input queue exceeds its supported capacity.") }
        guard CMIODeviceStartStream(device, stream) == noErr else { throw Failure(message: "The signed studio could not start the extension's input stream.") }
        transport = Transport(id: reservation, queue: queue, format: format, cadence: cadence,
                              stopStream: { CMIODeviceStopStream(device, stream) })
        committed = true
    }
    #if STREAM_NATIVE_VALIDATION
    /// Only the selected CMIO transport effects are inert. The production
    /// queue ownership, format checks, cadence, enqueue and stop drain execute.
    init(validationQueue: CMSimpleQueue, format: VirtualCameraFormat,
         cadence: FrameDeliveryCameraCadence = FrameDeliveryCameraCadence(), stopStream: @escaping @Sendable () -> OSStatus = { noErr }) throws {
        guard CMSimpleQueueGetCapacity(validationQueue) > 0, CMSimpleQueueGetCapacity(validationQueue) <= 2 else {
            throw Failure(message: "The camera input queue exceeds its supported capacity.")
        }
        transport = Transport(id: try Registry.shared.reserve(), queue: validationQueue, format: format, cadence: cadence, stopStream: stopStream)
    }
    #endif
    func bindRetirement(revoke: @escaping @Sendable () -> Void, completion: @escaping @Sendable () -> Void) {
        transport.bind(revoke: revoke, completion: completion)
    }
    var statistics: (sent: UInt64, dropped: UInt64) {
        transport.lock.lock(); defer { transport.lock.unlock() }; return (transport.sent, transport.dropped)
    }
    /// Accepts ONLY the broker's completed target-sized private sample. There
    /// is no compositor frame, CI image, conversion task or source borrow in
    /// scope when the opaque CMIO queue is called.
    func appendPrepared(_ sample: CMSampleBuffer) {
        let lock = transport.lock, queue = transport.queue, format = transport.format
        lock.lock(); defer { lock.unlock() }
        guard transport.accepting else { return }
        guard CMSampleBufferDataIsReady(sample), CMSampleBufferGetNumSamples(sample) == 1,
              let input = CMSampleBufferGetImageBuffer(sample),
              CVPixelBufferGetPixelFormatType(input) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(input) == format.width, CVPixelBufferGetHeight(input) == format.height,
              CMTimeCompare(CMSampleBufferGetDuration(sample), CMTime(value: 1, timescale: 30)) == 0 else { transport.dropped += 1; return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isNumeric else { transport.dropped += 1; return }
        if transport.lastPTS.isValid, CMTimeCompare(CMTimeSubtract(pts, transport.lastPTS), CMTime(value: 1, timescale: 30)) < 0 { return }
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { transport.dropped += 1; return }
        let retained = Unmanaged.passRetained(sample)
        if CMSimpleQueueEnqueue(queue, element: retained.toOpaque()) == noErr {
            transport.sent += 1; transport.lastPTS = pts; transport.cadence.didEnqueue(pts)
        }
        else { retained.release(); transport.dropped += 1 }
    }
    @discardableResult func stop(retry: Bool = false) -> StopResult {
        transport.stop(retry: retry)
    }
    deinit { stop() }
}
