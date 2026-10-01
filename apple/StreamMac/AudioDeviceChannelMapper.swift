import CoreMedia
import StreamCore
import os.lock

/// A05 (issue #84): applies one audio interface's `AudioInputMapping` to its
/// capture buffers on the capture queue — BEFORE the mix engine's insert and
/// format normalization — so the device's `.microphone(deviceUID:)` channel
/// carries exactly the hardware inputs the user picked.
///
/// `.all` (and anything unresolvable) passes the buffer through untouched:
/// built-in/USB mics keep their native mono/stereo layout and the canonical
/// converter normalizes them as before. `.mono` duplicates one hardware
/// channel to L/R; `.stereo` maps a hardware channel pair to L/R — the
/// output is always interleaved stereo Float32 at the device's NATIVE sample
/// rate (resampling stays the engine converter's job), stamped with the
/// original PTS/duration so the host-clock positioning (drift correction) is
/// unaffected.
///
/// The mapping can change LIVE (a settings edit mid-capture): the current
/// value is read under a lock per buffer, so a remap takes effect on the
/// next callback with no capture restart and no click beyond the layout
/// change itself.
final class AudioDeviceChannelMapper: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var mapping: AudioInputMapping
    /// Stereo Float32 format descriptions, cached per source sample rate.
    private var formatDescriptions: [Double: CMAudioFormatDescription] = [:]

    init(mapping: AudioInputMapping) {
        self.mapping = mapping
    }

    func setMapping(_ mapping: AudioInputMapping) {
        os_unfair_lock_lock(&lock)
        self.mapping = mapping
        os_unfair_lock_unlock(&lock)
    }

    /// Returns the mapped buffer, or `sampleBuffer` itself when the mapping
    /// is passthrough or the buffer's layout can't be remapped (the engine's
    /// converter keeps its existing normalize-or-drop policy for those).
    func process(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        os_unfair_lock_lock(&lock)
        let mapping = self.mapping
        os_unfair_lock_unlock(&lock)

        guard let asbd = CMSampleBufferGetFormatDescription(sampleBuffer)
                .flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }),
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mSampleRate > 0 else { return sampleBuffer }
        let channelCount = Int(asbd.mChannelsPerFrame)
        guard let pair = mapping.stereoPair(channelCount: channelCount) else {
            return sampleBuffer
        }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return sampleBuffer }

        var listSize = 0
        var blockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &listSize,
            bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        ) == noErr, listSize > 0 else { return sampleBuffer }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: list, bufferListSize: listSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        ) == noErr else { return sampleBuffer }

        var stereo = [Float](repeating: 0, count: frameCount * 2)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0

        // Channel-at-frame reader for both layouts: interleaved packs all
        // channels in buffer 0; non-interleaved carries one channel per
        // buffer. Unsupported sample widths bail to passthrough below.
        func sample(channel: Int, frame: Int) -> Float? {
            if isFloat, asbd.mBitsPerChannel == 32 {
                if isNonInterleaved {
                    guard channel < buffers.count, let data = buffers[channel].mData,
                          frame < Int(buffers[channel].mDataByteSize) / 4 else { return nil }
                    return data.assumingMemoryBound(to: Float.self)[frame]
                }
                guard let buffer = buffers.first, let data = buffer.mData else { return nil }
                return data.assumingMemoryBound(to: Float.self)[frame * channelCount + channel]
            }
            if !isFloat, asbd.mBitsPerChannel == 16 {
                if isNonInterleaved {
                    guard channel < buffers.count, let data = buffers[channel].mData,
                          frame < Int(buffers[channel].mDataByteSize) / 2 else { return nil }
                    return Float(data.assumingMemoryBound(to: Int16.self)[frame])
                        / Float(Int16.max)
                }
                guard let buffer = buffers.first, let data = buffer.mData else { return nil }
                return Float(data.assumingMemoryBound(to: Int16.self)[frame * channelCount + channel])
                    / Float(Int16.max)
            }
            if !isFloat, asbd.mBitsPerChannel == 32 {
                if isNonInterleaved {
                    guard channel < buffers.count, let data = buffers[channel].mData,
                          frame < Int(buffers[channel].mDataByteSize) / 4 else { return nil }
                    return Float(data.assumingMemoryBound(to: Int32.self)[frame])
                        / Float(Int32.max)
                }
                guard let buffer = buffers.first, let data = buffer.mData else { return nil }
                return Float(data.assumingMemoryBound(to: Int32.self)[frame * channelCount + channel])
                    / Float(Int32.max)
            }
            return nil
        }

        for frame in 0..<frameCount {
            guard let left = sample(channel: pair.left, frame: frame),
                  let right = sample(channel: pair.right, frame: frame) else {
                return sampleBuffer
            }
            stereo[frame * 2] = left
            stereo[frame * 2 + 1] = right
        }

        guard let description = formatDescription(sampleRate: asbd.mSampleRate) else {
            return sampleBuffer
        }
        let byteCount = stereo.count * MemoryLayout<Float>.size
        var outBlock: CMBlockBuffer?
        let created = stereo.withUnsafeBufferPointer { pointer in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: byteCount,
                blockAllocator: nil, customBlockSource: nil,
                offsetToData: 0, dataLength: byteCount, flags: 0,
                blockBufferOut: &outBlock)
        }
        guard created == noErr, let outBlock,
              CMBlockBufferReplaceDataBytes(
                with: stereo, blockBuffer: outBlock,
                offsetIntoDestination: 0, dataLength: byteCount) == noErr
        else { return sampleBuffer }
        var out: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: outBlock,
            formatDescription: description,
            sampleCount: frameCount,
            presentationTimeStamp: sampleBuffer.presentationTimeStamp,
            packetDescriptions: nil,
            sampleBufferOut: &out) == noErr, let out
        else { return sampleBuffer }
        return out
    }

    private func formatDescription(sampleRate: Double) -> CMAudioFormatDescription? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if let cached = formatDescriptions[sampleRate] { return cached }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size) * 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size) * 2,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 8 * UInt32(MemoryLayout<Float>.size),
            mReserved: 0
        )
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd,
                                             layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil,
                                             extensions: nil,
                                             formatDescriptionOut: &description) == noErr
        else { return nil }
        formatDescriptions[sampleRate] = description
        return description
    }
}
