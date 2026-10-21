import CoreMediaIO
import Foundation

@main struct VirtualCameraHarness {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "VirtualCameraHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func pixels(width: Int = 1280, height: Int = 720, pts: UInt64, red: Bool = true) throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        try check(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixels) == kCVReturnSuccess, "Allocate pixels")
        let p = pixels!
        CVPixelBufferLockBaseAddress(p, []);
        let base = CVPixelBufferGetBaseAddress(p)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(p)
        for y in 0..<height { for x in 0..<width { let n = y * stride + x * 4; base[n] = 0; base[n+1] = 0; base[n+2] = red ? 255 : 0; base[n+3] = 255 } }
        CVPixelBufferUnlockBaseAddress(p, [])
        var format: CMVideoFormatDescription?; CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: p, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: Int64(pts), timescale: 1_000_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: p, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
        return sample!
    }
    static func middleRed(_ sample: CMSampleBuffer) -> UInt8 {
        let p = CMSampleBufferGetImageBuffer(sample)!
        CVPixelBufferLockBaseAddress(p, .readOnly); defer { CVPixelBufferUnlockBaseAddress(p, .readOnly) }
        return CVPixelBufferGetBaseAddress(p)!.assumingMemoryBound(to: UInt8.self)[CVPixelBufferGetHeight(p) / 2 * CVPixelBufferGetBytesPerRow(p) + CVPixelBufferGetWidth(p) / 2 * 4 + 2]
    }
    static func main() throws {
        let provider = try StreamCameraProvider()
        try check(provider.provider.devices.count == 1 && provider.camera.device.streams.count == 2, "Actual CMIO device source/sink")
        try check(provider.camera.device.deviceID == VirtualCameraContract.deviceID, "Stable camera identity")
        let source = provider.camera.video, sink = provider.camera.sink, mailbox = source.mailbox
        try check(source.formats.count == 2 && sink.formats.count == 2, "Negotiated formats")
        let queue = try sink.streamProperties(forProperties: sink.availableProperties)
        try check(queue.sinkBufferQueueSize == 2 && queue.sinkBuffersRequiredForStartup == 1, "Bounded actual sink properties")
        let now = VirtualCameraContract.hostNanoseconds
        let input = try pixels(pts: now)
        try check(mailbox.submit(input, sequence: 1, now: now), "Timestamped native frame")
        try check(!mailbox.submit(input, sequence: 2, now: now), "Reject duplicate PTS")
        guard let first = source.makeSample(now: now) else { throw NSError(domain: "Harness", code: 2) }
        try check(middleRed(first.buffer) > 240 && first.pts == now && first.discontinuity, "Graph PTS and actual pixels")
        let advanced = try pixels(pts: now + 8_000_000)
        try check(mailbox.submit(advanced, sequence: 2, now: now + 8_000_000), "Graph PTS retained at sink")
        let cadence = source.makeSample(now: now + 33_333_333)
        try check(cadence?.pts == now + 33_333_333, "Source retimes graph frame to camera delivery clock")
        let settings = CMIOExtensionStreamProperties(dictionary: [:]); settings.activeFormatIndex = 1
        try source.setStreamProperties(settings)
        guard let resized = source.makeSample(now: now + 33_333_333) else { throw NSError(domain: "Harness", code: 3) }
        try check(CVPixelBufferGetWidth(CMSampleBufferGetImageBuffer(resized.buffer)!) == 1920 && middleRed(resized.buffer) > 240 && resized.pts > first.pts, "1080 negotiated resize and monotonic repeat")
        // Pool threshold is enforced: holding consumer buffers drops this tick.
        var held: [StreamCameraSource.Sample] = [resized]
        for n in 2...3 { if let sample = source.makeSample(now: now + UInt64(n) * 33_333_333) { held.append(sample) } }
        try check(source.makeSample(now: now + 133_333_333) == nil, "Consumer exhaustion bounded to three buffers")
        held.removeAll()
        // New format allocates a separate bounded pool; release earlier refs.
        let back = CMIOExtensionStreamProperties(dictionary: [:]); back.activeFormatIndex = 0; try source.setStreamProperties(back)
        guard let stale = source.makeSample(now: now + 600_000_000) else { throw NSError(domain: "Harness", code: 4) }
        try check(middleRed(stale.buffer) == 0 && stale.discontinuity, "Stale producer gives black video")
        mailbox.clear()
        try check(mailbox.latest(now: now) == nil, "Producer disconnect clears immediately")
        let invalid = CMIOExtensionStreamProperties(dictionary: [:]); invalid.activeFormatIndex = 9
        do { try source.setStreamProperties(invalid); throw NSError(domain: "Harness", code: 5) }
        catch { try check(source.activeFormatIndex == 0, "Invalid format preserves negotiated state") }
        // A rejected compound negotiation must not silently change the sink
        // format, and a successful change must discard the old input image.
        let negotiationMailbox = VirtualCameraMailbox()
        let negotiationSink = StreamCameraSink(formats: source.formats, mailbox: negotiationMailbox)
        try check(negotiationMailbox.submit(input, sequence: 1, now: now), "Seed negotiated input")
        let compound = CMIOExtensionStreamProperties(dictionary: [:])
        compound.activeFormatIndex = 1; compound.frameDuration = CMTime(value: 1, timescale: 60)
        var rejected = false
        do { try negotiationSink.setStreamProperties(compound) } catch { rejected = true }
        let unchanged = try negotiationSink.streamProperties(forProperties: [.streamActiveFormatIndex])
        try check(rejected && unchanged.activeFormatIndex == 0 && negotiationMailbox.latest(now: now) != nil,
                  "Rejected compound sink negotiation preserves format and input")
        try negotiationSink.setStreamProperties(settings)
        try check(negotiationMailbox.latest(now: now) == nil, "Renegotiating the sink clears its previous-format frame")
        try check(!negotiationSink.receiveSample(advanced, sequence: 2, now: now + 8_000_000), "Late old-format completion cannot refill the sink")
        let negotiatedInput = try pixels(width: 1920, height: 1080, pts: now + 9_000_000)
        try check(negotiationSink.receiveSample(negotiatedInput, sequence: 3, now: now + 9_000_000), "Accept newly negotiated input")
        let unsupported = try pixels(width: 640, height: 480, pts: now + 10_000_000)
        try check(!negotiationMailbox.submit(unsupported, sequence: 4, now: now + 10_000_000), "Reject unadvertised input dimensions")
        try check(!StreamCameraSink.trustedProducer(pid: getpid(), team: "K78G42H4U2"), "Unsigned fixture cannot inject a signed production sink")
        let restart = try pixels(pts: now + 700_000_000)
        try check(mailbox.submit(restart, sequence: 1, now: now + 700_000_000), "Explicit new producer session")
        try source.stopStream() // Unbalanced stop cannot underflow client count.
        print("PASS: actual CMIO provider/device/source/sink, bounded queue and pool, graph timestamps/pixels, atomic 720p/1080p negotiation, rejected unadvertised/late old-format input, stale/disconnect black fallback, unsigned producer rejection; extension not installed")
    }
}
