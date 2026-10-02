import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import StreamCore
import VideoToolbox

/// A group belongs to one output controller/runtime. Its input is the immutable
/// taken canvas plus the studio's post-mix 48 kHz stereo Program bus. No source,
/// effect, timeline or adaptive state is inherited from an individual endpoint.
struct DestinationSharedEncoderKey: Hashable, Sendable {
    let canvas: OutputCanvas
    let width: Int, height: Int, fps: Int, sourceFPS: Int, videoBitrate: Int, audioBitrate: Int, keyframeSeconds: Int
    let audioPipeline = "program-postmix-48000-stereo"
    let latency = "realtime-h264-main-no-reordering"
    init?(destination: StreamDestination, settings: StreamSettings, sourceFrameRate: Int) {
        var effective = destination
        effective.followsProgramProfile = false; effective.outputProfile = settings.outputProfile
        effective.videoCodec = settings.effectiveVideoCodec; effective.videoBitrate = settings.videoBitrate
        effective.audioBitrate = settings.audioBitrate; effective.keyframeSeconds = settings.destinationKeyframeSeconds ?? 2
        guard (1...60).contains(sourceFrameRate), DestinationEncoderKey(destination: effective, program: settings.outputProfile)
            .supportsFixedH264AAC(on: destination.transport, sourceFrameRate: sourceFrameRate) else { return nil }
        canvas = destination.canvas ?? .program
        width = settings.outputProfile.canvasWidth; height = settings.outputProfile.canvasHeight
        fps = settings.outputProfile.frameRate; sourceFPS = sourceFrameRate; videoBitrate = settings.videoBitrate; audioBitrate = settings.audioBitrate
        keyframeSeconds = Int(settings.destinationKeyframeSeconds ?? 2)
    }
}

private final class SharedPCMInput: @unchecked Sendable {
    let pcm: AVAudioPCMBuffer
    private let lock = NSLock()
    private var supplied = false
    init(_ pcm: AVAudioPCMBuffer) { self.pcm = pcm }
    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock(); defer { lock.unlock() }
        if supplied { status.pointee = .noDataNow; return nil }
        supplied = true; status.pointee = .haveData; return pcm
    }
}

/// At most one pump block and two raw video / 64 audio buffers are retained.
/// VideoToolbox has at most four outstanding frames. Encoding happens once;
/// downstream readers receive the same immutable CMSampleBuffer/packet bytes.
final class DestinationSharedEncoder: @unchecked Sendable {
    let id: UUID
    let key: DestinationSharedEncoderKey
    private let queue = DispatchQueue(label: "com.joeblau.StreamMac.sharedEncoder")
    private let lock = NSLock()
    private var video: [CMSampleBuffer] = [], audio: [CMSampleBuffer] = []
    private var scheduled = false, accepting = true, keyframeRequested = true, failed = false, stopped = false
    private var sinks: [UUID: DestinationEncodedMailbox] = [:]
    private var videoSession: VTCompressionSession?
    private var pool: CVPixelBufferPool?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var converter: AVAudioConverter?
    private var audioFormat: AVAudioFormat?
    private var audioDescription: CMAudioFormatDescription?
    private var audioOrigin: CMTime = .invalid
    private var audioFrames: Int64 = 0
    private var audioInputFrames: Int64 = 0
    private var lastAudioInputEnd: CMTime = .invalid
    private var lastForcedPTS: CMTime = .invalid
    private var nextVideoPTS: CMTime = .invalid
    private var inFlight = 0
    private var encodedVideoCount = 0, encodedAudioCount = 0, rawVideoDrops = 0
    private let failure: @Sendable () -> Void
    init(key: DestinationSharedEncoderKey, id: UUID = UUID(), failure: @escaping @Sendable () -> Void) {
        self.key = key; self.id = id; self.failure = failure
    }
    func add(_ mailbox: DestinationEncodedMailbox, id: UUID) {
        lock.lock(); sinks[id] = mailbox; keyframeRequested = true; lock.unlock()
    }
    func remove(_ id: UUID) { lock.lock(); sinks[id] = nil; lock.unlock() }
    func requestKeyframe() { lock.lock(); keyframeRequested = true; lock.unlock() }
    func enqueueVideo(_ sample: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        guard let image = sample.imageBuffer, CVPixelBufferGetDataSize(image) <= 64 * 1024 * 1024 else {
            accepting = false; queue.async { [self] in fail() }; return
        }
        if video.count >= 2 { video.removeFirst(); rawVideoDrops += 1 }
        video.append(sample); scheduleLocked()
    }
    func enqueueAudio(_ sample: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        guard sample.numSamples <= 4096, sample.totalSampleSize <= 32_768, audio.count < 64 else { accepting = false; queue.async { [self] in fail() }; return }
        audio.append(sample); scheduleLocked()
    }
    private func scheduleLocked() {
        guard !scheduled else { return }; scheduled = true
        queue.async { [self] in pump() }
    }
    private func pump() {
        while true {
            lock.lock()
            let v = video.isEmpty ? nil : video.removeFirst(), a = audio.isEmpty ? nil : audio.removeFirst()
            let active = accepting
            if v == nil && a == nil || !active { scheduled = false; video.removeAll(); audio.removeAll(); lock.unlock(); return }
            lock.unlock()
            do {
                if let v { try encodeVideo(v) }
                if let a { try encodeAudio(a) }
            } catch { fail(); return }
        }
    }
    private func recipients() -> [DestinationEncodedMailbox] {
        lock.lock(); defer { lock.unlock() }; return Array(sinks.values)
    }
    private func fail() {
        lock.lock()
        guard !stopped, !failed else { lock.unlock(); return }
        failed = true; accepting = false; video.removeAll(); audio.removeAll(); lock.unlock()
        failure()
    }
    func statistics() async -> (video: Int, audio: Int, outstanding: Int, drops: Int) {
        await withCheckedContinuation { continuation in queue.async { [self] in
            lock.lock(); let drops = rawVideoDrops; lock.unlock()
            continuation.resume(returning: (encodedVideoCount, encodedAudioCount, inFlight, drops))
        } }
    }
    func stop(_ completion: @escaping @Sendable () -> Void = {}) {
        lock.lock(); accepting = false; stopped = true; video.removeAll(); audio.removeAll(); sinks.removeAll(); lock.unlock()
        queue.async { [self] in
            if let videoSession {
                VTCompressionSessionCompleteFrames(videoSession, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(videoSession)
            }
            videoSession = nil; converter = nil; pool = nil; audioFormat = nil; audioDescription = nil
            completion()
        }
    }
    private func makeVideoSession() throws {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(key.width), height: Int32(key.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let created else { throw CocoaError(.coderInvalidValue) }
        videoSession = created
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true, kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Main_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: key.videoBitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: key.fps,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: key.keyframeSeconds,
            kVTCompressionPropertyKey_MaxFrameDelayCount: 3
        ]
        guard VTSessionSetProperties(created, propertyDictionary: properties as CFDictionary) == noErr,
              VTCompressionSessionPrepareToEncodeFrames(created) == noErr else { throw CocoaError(.coderInvalidValue) }
        let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: key.width, kCVPixelBufferHeightKey: key.height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else { throw CocoaError(.coderInvalidValue) }
    }
    private func encodeVideo(_ sample: CMSampleBuffer) throws {
        let pts = sample.presentationTimeStamp
        guard pts.isNumeric, let input = sample.imageBuffer else { throw CocoaError(.coderInvalidValue) }
        if nextVideoPTS.isNumeric, (pts - nextVideoPTS).seconds < -0.0001 { return }
        guard inFlight < 4 else { lock.lock(); rawVideoDrops += 1; lock.unlock(); return }
        if videoSession == nil { try makeVideoSession() }
        guard let videoSession, let pool else { throw CocoaError(.coderInvalidValue) }
        var scaled: CVPixelBuffer?
        let allocation = [kCVPixelBufferPoolAllocationThresholdKey: 6] as CFDictionary
        if CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, allocation, &scaled) != kCVReturnSuccess { return }
        guard let scaled else { return }
        let source = CIImage(cvPixelBuffer: input)
        let factor = min(Double(key.width) / source.extent.width, Double(key.height) / source.extent.height)
        let image = source.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            .transformed(by: CGAffineTransform(translationX: (Double(key.width) - source.extent.width * factor) / 2,
                                             y: (Double(key.height) - source.extent.height * factor) / 2))
            .composited(over: CIImage(color: .black))
        context.render(image, to: scaled, bounds: CGRect(x: 0, y: 0, width: key.width, height: key.height), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        lock.lock()
        let force = keyframeRequested && (!lastForcedPTS.isNumeric || (pts - lastForcedPTS).seconds >= 0.25)
        if force { keyframeRequested = false; lastForcedPTS = pts }
        lock.unlock()
        inFlight += 1
        let interval = CMTime(value: 1, timescale: CMTimeScale(key.fps))
        if !nextVideoPTS.isNumeric || (pts - nextVideoPTS).seconds > 1 { nextVideoPTS = pts + interval }
        else {
            // Preserve phase for non-divisor rates (60 ->24 alternates source
            // steps) instead of resetting a full interval after every frame.
            repeat { nextVideoPTS = nextVideoPTS + interval } while (pts - nextVideoPTS).seconds >= -0.0001
        }
        let properties = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let result = VTCompressionSessionEncodeFrame(videoSession, imageBuffer: scaled, presentationTimeStamp: pts,
            duration: CMTime(value: 1, timescale: CMTimeScale(key.fps)), frameProperties: properties,
            infoFlagsOut: nil, outputHandler: { [self] status, _, sample in
                queue.async { [self] in
                    inFlight = max(0, inFlight - 1)
                    guard status == noErr, let sample else { fail(); return }
                    lock.lock(); let active = accepting; lock.unlock()
                    guard active else { return }
                    encodedVideoCount += 1
                    for sink in recipients() { sink.enqueueVideo(sample) }
                }
            })
        if result != noErr { inFlight -= 1; throw CocoaError(.coderInvalidValue) }
    }
    private func encodeAudio(_ sample: CMSampleBuffer) throws {
        guard let format = sample.formatDescription, CMFormatDescriptionGetMediaType(format) == kCMMediaType_Audio,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate == 48_000, asbd.mChannelsPerFrame == 2,
              let pcm = CanonicalAudioConverter.makePCMBuffer(from: sample), pcm.format.sampleRate == 48_000,
              pcm.format.channelCount == 2, pcm.frameLength <= 4096 else { throw CocoaError(.coderInvalidValue) }
        let sourcePTS = sample.presentationTimeStamp
        guard sourcePTS.isNumeric else { throw CocoaError(.coderInvalidValue) }
        if lastAudioInputEnd.isNumeric, abs((sourcePTS - lastAudioInputEnd).seconds) > 0.1 {
            // Do not silently turn an interrupted source clock into continuous
            // AAC timestamps. Restarting these outputs is an explicit repair.
            throw CocoaError(.coderInvalidValue)
        }
        if audioOrigin.isNumeric, abs((sourcePTS - (audioOrigin + CMTime(value: audioInputFrames, timescale: 48_000))).seconds) > 0.025 {
            throw CocoaError(.coderInvalidValue)
        }
        lastAudioInputEnd = sourcePTS + CMTime(value: Int64(pcm.frameLength), timescale: 48_000)
        if converter == nil {
            var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC,
                mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue), mBytesPerPacket: 0, mFramesPerPacket: 1024,
                mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
            guard let format = AVAudioFormat(streamDescription: &asbd), let created = AVAudioConverter(from: pcm.format, to: format) else { throw CocoaError(.coderInvalidValue) }
            created.bitRate = key.audioBitrate; created.primeMethod = .none
            converter = created; audioFormat = format; audioOrigin = sample.presentationTimeStamp
        }
        guard let converter, let audioFormat, converter.inputFormat == pcm.format else { throw CocoaError(.coderInvalidValue) }
        audioInputFrames += Int64(pcm.frameLength)
        let input = SharedPCMInput(pcm)
        for _ in 0..<16 {
            let output = AVAudioCompressedBuffer(format: audioFormat, packetCapacity: 1, maximumPacketSize: max(4096, converter.maximumOutputPacketSize))
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, status in input.next(status) }
            guard error == nil, status != .error else { throw CocoaError(.coderInvalidValue) }
            guard status == .haveData, output.packetCount > 0 else { return }
            guard output.packetCount == 1, output.byteLength > 0, output.byteLength <= 65_536 else { throw CocoaError(.coderInvalidValue) }
            if audioDescription == nil {
                var asbd = audioFormat.streamDescription.pointee
                let cookie = converter.magicCookie ?? Data()
                var description: CMAudioFormatDescription?
                let result = cookie.withUnsafeBytes { bytes in CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd,
                    layoutSize: 0, layout: nil, magicCookieSize: cookie.count, magicCookie: bytes.baseAddress,
                    extensions: nil, formatDescriptionOut: &description) }
                guard result == noErr else { throw CocoaError(.coderInvalidValue) }; audioDescription = description
            }
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: Int(output.byteLength),
                blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: Int(output.byteLength), flags: 0, blockBufferOut: &block) == noErr,
                let block, CMBlockBufferReplaceDataBytes(with: output.data, blockBuffer: block, offsetIntoDestination: 0, dataLength: Int(output.byteLength)) == noErr,
                let audioDescription else { throw CocoaError(.coderInvalidValue) }
            let pts = audioOrigin + CMTime(value: audioFrames, timescale: 48_000)
            var packet = output.packetDescriptions?.pointee ?? AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 1024, mDataByteSize: output.byteLength)
            var encoded: CMSampleBuffer?
            guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block,
                formatDescription: audioDescription, sampleCount: 1, presentationTimeStamp: pts,
                packetDescriptions: &packet, sampleBufferOut: &encoded) == noErr, let encoded else { throw CocoaError(.coderInvalidValue) }
            audioFrames += 1024; encodedAudioCount += 1
            let audio = SharedEncodedAudio(sample: encoded, buffer: output,
                when: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: pts.seconds)))
            for sink in recipients() { sink.enqueueAudio(audio) }
        }
        throw CocoaError(.coderInvalidValue)
    }
}
