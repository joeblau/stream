import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

enum ProgramRecordingFixtures {
    static func video(at seconds: Double, noisy: Bool = false, timestampBase: Double = 10_000, eventSeconds: Double = 0.5) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess, let pixel else { throw CocoaError(.fileReadUnknown) }
        CVPixelBufferLockBaseAddress(pixel, [])
        let bright: UInt8 = (eventSeconds..<(eventSeconds + 0.1)).contains(seconds) ? 255 : 0
        if noisy {
            let pointer = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
            var seed = UInt64(max(0, seconds) * 100_000) + 1
            for index in 0..<CVPixelBufferGetDataSize(pixel) {
                seed = seed &* 6364136223846793005 &+ 1
                pointer[index] = index % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: seed >> 32)
            }
        } else { memset(CVPixelBufferGetBaseAddress(pixel), Int32(bright), CVPixelBufferGetDataSize(pixel)) }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: CMTime(seconds: timestampBase + seconds, preferredTimescale: 48_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw CocoaError(.fileReadUnknown) }
        return sample
    }

    static func audio(at seconds: Double, timestampBase: Double = 10_000, constantTone: Bool = false, amplitude: Float = 0.8, eventSeconds: Double = 0.5) throws -> CMSampleBuffer {
        let floats: [Float] = (0..<960).map { index in
            let time = seconds + Double(index / 2) / 48_000
            return constantTone || (eventSeconds..<(eventSeconds + 0.1)).contains(time) ? Float(sin(time * 2 * .pi * 1000)) * amplitude : 0
        }
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: floats.count * 4,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: floats.count * 4,
            flags: 0, blockBufferOut: &block)
        let status = floats.withUnsafeBufferPointer { ptr in
            CMBlockBufferReplaceDataBytes(with: ptr.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: floats.count * 4)
        }
        precondition(status == noErr)
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!,
            formatDescription: format!, sampleCount: 480,
            presentationTimeStamp: CMTime(seconds: timestampBase + seconds, preferredTimescale: 48_000),
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard let sample else { throw CocoaError(.fileReadUnknown) }
        return sample
    }

    static func inspect(_ url: URL, expectedDuration: Double?, checkSync: Bool) async throws {
        let asset = AVURLAsset(url: url)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        precondition(videos.count == 1 && audios.count == 1, "Both program tracks must exist")
        let duration = try await asset.load(.duration).seconds
        if let expectedDuration { precondition(abs(duration - expectedDuration) < 0.08, "Unexpected duration \(duration)") }
        let videoRange = try await videos[0].load(.timeRange)
        let audioRange = try await audios[0].load(.timeRange)
        precondition(abs(videoRange.start.seconds - audioRange.start.seconds) < 0.04, "Track start mismatch")
        precondition(abs(videoRange.duration.seconds - audioRange.duration.seconds) < 0.08, "Track end mismatch")
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videos[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let audioOutput = AVAssetReaderTrackOutput(track: audios[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        reader.add(videoOutput); reader.add(audioOutput)
        precondition(reader.startReading())
        var flash: Double?; var tone: Double?; var frameCount = 0
        while let sample = videoOutput.copyNextSampleBuffer() {
            frameCount += 1
            if let image = CMSampleBufferGetImageBuffer(sample) {
                CVPixelBufferLockBaseAddress(image, .readOnly)
                let value = CVPixelBufferGetBaseAddress(image)!.load(as: UInt8.self)
                CVPixelBufferUnlockBaseAddress(image, .readOnly)
                if value > 150 && flash == nil { flash = sample.presentationTimeStamp.seconds }
            }
        }
        while let sample = audioOutput.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating: 0, count: length / 4)
            values.withUnsafeMutableBytes { ptr in _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: ptr.baseAddress!) }
            if tone == nil, let index = values.firstIndex(where: { abs($0) > 0.15 }) {
                tone = sample.presentationTimeStamp.seconds + Double(index / 2) / 48_000
            }
        }
        precondition(reader.status == .completed, reader.error?.localizedDescription ?? "Media decode failed")
        if checkSync {
            precondition(flash != nil && tone != nil, "Flash/tone must survive encoding")
            precondition(abs(flash! - tone!) < 0.06, "Decoded audio/video event drift \(flash! - tone!)")
        }
        print("Media: \(url.lastPathComponent), duration \(duration), frames \(frameCount), flash \(flash ?? -1), tone \(tone ?? -1)")
    }
}
