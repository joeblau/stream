import CoreImage
import CoreMediaIO
import Foundation
import IOKit.audio
import Security

/// Independent CMIO source. No microphone is published by this extension.
/// Formats are negotiated by camera clients; the transport stays bounded to
/// 1080p and the renderer fits incoming program frames into the chosen format.
final class StreamCameraSource: NSObject, CMIOExtensionStreamSource, @unchecked Sendable {
    private(set) var stream: CMIOExtensionStream!
    private let lock = NSRecursiveLock()
    private var selectedIndex = 0
    private var clients = 0
    private var timer: DispatchSourceTimer?
    let mailbox: VirtualCameraMailbox
    private var lastPTS: UInt64 = 0
    private var lastSequence: UInt64?
    private var wasFresh = false
    private var pools: [Int: CVPixelBufferPool] = [:]
    private let context = CIContext(options: [.cacheIntermediates: false])
    let formats: [CMIOExtensionStreamFormat]
    static let sizes = [(1280, 720), (1920, 1080)]

    init(mailbox: VirtualCameraMailbox = VirtualCameraMailbox()) throws {
        self.mailbox = mailbox
        formats = try Self.sizes.map { width, height in
            var description: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                width: Int32(width), height: Int32(height), extensions: nil, formatDescriptionOut: &description) == noErr,
                  let description else { throw NSError(domain: "StreamCamera", code: 3) }
            let duration = CMTime(value: 1, timescale: 30)
            return CMIOExtensionStreamFormat(formatDescription: description, maxFrameDuration: duration, minFrameDuration: duration, validFrameDurations: nil)
        }
        super.init()
        stream = CMIOExtensionStream(localizedName: "Stream Studio Video", streamID: VirtualCameraContract.streamID,
            direction: .source, clockType: .hostTime, source: self)
    }
    var activeFormatIndex: Int { lock.lock(); defer { lock.unlock() }; return selectedIndex }
    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }
    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = activeFormatIndex }
        if properties.contains(.streamFrameDuration) { result.frameDuration = CMTime(value: 1, timescale: 30) }
        return result
    }
    func setStreamProperties(_ properties: CMIOExtensionStreamProperties) throws {
        lock.lock(); defer { lock.unlock() }
        if let index = properties.activeFormatIndex, !formats.indices.contains(index) { throw NSError(domain: "StreamCamera", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported camera format."]) }
        if let duration = properties.frameDuration, CMTimeCompare(duration, CMTime(value: 1, timescale: 30)) != 0 {
            throw NSError(domain: "StreamCamera", code: 2, userInfo: [NSLocalizedDescriptionKey: "This camera supports 30 fps."])
        }
        if let index = properties.activeFormatIndex { selectedIndex = index }
    }
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true } // OS mediates camera-client access.
    func startStream() throws {
        lock.lock(); defer { lock.unlock() }
        clients += 1
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.joeblau.Stream.camera", qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .nanoseconds(33_333_333), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, let frame = self.makeSample() else { return }
            self.stream.send(frame.buffer, discontinuity: frame.discontinuity ? [.time] : [], hostTimeInNanoseconds: frame.pts)
        }
        self.timer = timer; timer.resume()
    }
    func stopStream() throws {
        lock.lock(); defer { lock.unlock() }
        clients = max(0, clients - 1)
        if clients == 0 { timer?.cancel(); timer = nil; pools.removeAll(); lastSequence = nil; wasFresh = false }
    }
    deinit { timer?.cancel() }
    struct Sample { var buffer: CMSampleBuffer; var pts: UInt64; var discontinuity: Bool }
    /// The same path used by the live timer, callable without activating or
    /// installing a system extension for native format/lifecycle validation.
    func makeSample(now: UInt64 = VirtualCameraContract.hostNanoseconds) -> Sample? {
        lock.lock(); defer { lock.unlock() }
        let frame = mailbox.latest(now: now)
        let index = selectedIndex, (width, height) = Self.sizes[index]
        if pools[index] == nil {
            var allocated: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                [kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height, kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                 kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &allocated) == kCVReturnSuccess else { return nil }
            pools[index] = allocated
        }
        guard let pool = pools[index] else { return nil }
        var pixels: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
            [kCVPixelBufferPoolAllocationThresholdKey: 3] as CFDictionary, &pixels) == kCVReturnSuccess, let pixels else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let black = CIImage(color: .black).cropped(to: rect)
        if let frame {
            let raw = CIImage(cvPixelBuffer: frame.pixelBuffer)
            let scale = min(rect.width / raw.extent.width, rect.height / raw.extent.height)
            let scaled = raw.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let centered = scaled.transformed(by: CGAffineTransform(translationX: (rect.width - scaled.extent.width) / 2, y: (rect.height - scaled.extent.height) / 2))
            context.render(centered.composited(over: black), to: pixels, bounds: rect, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        } else { context.render(black, to: pixels) }
        // The sink retains graph PTS for freshness validation. Retiming onto
        // the same host clock at delivery also gives a 24/60-fps graph a valid
        // 30-fps camera cadence, instead of mixing old source PTS with repeats.
        let pts = max(lastPTS + 1, now)
        let discontinuity = (frame != nil) != wasFresh || (frame != nil && lastSequence != nil && frame!.sequence < lastSequence!)
        lastPTS = pts; lastSequence = frame?.sequence; wasFresh = frame != nil
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: Int64(pts), timescale: 1_000_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: formats[index].formatDescription, sampleTiming: &timing,
            sampleBufferOut: &sample) == noErr, let sample else { return nil }
        return Sample(buffer: sample, pts: pts, discontinuity: discontinuity)
    }
}

final class StreamCameraDevice: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    let video: StreamCameraSource
    let sink: StreamCameraSink
    init(localizedName: String = "Stream Studio Camera") throws {
        let mailbox = VirtualCameraMailbox()
        video = try StreamCameraSource(mailbox: mailbox)
        sink = StreamCameraSink(formats: video.formats, mailbox: mailbox)
        super.init()
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: VirtualCameraContract.deviceID, legacyDeviceID: nil, source: self)
        try device.addStream(video.stream)
        try device.addStream(sink.stream)
    }
    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }
    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { result.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { result.model = "Stream Studio Camera 1" }
        return result
    }
    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}
}

final class StreamCameraProvider: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    let camera: StreamCameraDevice
    init(cameraName: String = "Stream Studio Camera") throws {
        camera = try StreamCameraDevice(localizedName: cameraName)
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: nil)
        try provider.addDevice(camera.device)
    }
    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) { camera.sink.disconnect(clientID: client.clientID) }
    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }
    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { result.manufacturer = "Stream Studio" }
        return result
    }
    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
