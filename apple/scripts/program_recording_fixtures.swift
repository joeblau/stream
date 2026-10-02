import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

enum ProgramRecordingFixtures {
    static func video(at seconds: Double, noisy: Bool = false) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess, let pixel else { throw CocoaError(.fileReadUnknown) }
        CVPixelBufferLockBaseAddress(pixel, [])
        let bright: UInt8 = (0.5..<0.6).contains(seconds) ? 255 : 0
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
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: CMTime(seconds: 10_000 + seconds, preferredTimescale: 48_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw CocoaError(.fileReadUnknown) }
        return sample
    }

    static func audio(at seconds: Double) throws -> CMSampleBuffer {
        let floats: [Float] = (0..<960).map { index in
            let time = seconds + Double(index / 2) / 48_000
            return (0.5..<0.6).contains(time) ? Float(sin(time * 2 * .pi * 1000)) * 0.8 : 0
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
            presentationTimeStamp: CMTime(seconds: 10_000 + seconds, preferredTimescale: 48_000),
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard let sample else { throw CocoaError(.fileReadUnknown) }
        return sample
    }

}
