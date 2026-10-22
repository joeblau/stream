import AudioToolbox
import CoreMedia
import Foundation

/// Owned-fixture observation only. The shipping sender/codec/send decisions are
/// unchanged. Retain at most64 received+64 admitted PCM chunks and128 actual emitted Opus packets;
/// no raw PCM, packet bytes, peer IDs, credentials or SDP enter the receipt.
final class ReturnSenderDiagnostic: @unchecked Sendable {
    static let shared = ReturnSenderDiagnostic()
    private struct PCM { let pts: CMTime; let samples: [Float] }
    private struct Packet { let data: Data; let pts: CMTime; let rtp: UInt32; let sent: Bool }
    private let lock = NSLock()
    private var pcm: [PCM] = [], admittedPCM: [PCM] = [], packets: [Packet] = []
    private var received = 0, admitted = 0, attempted = 0, sent = 0, errors = 0
    private var youngest = Double.infinity, oldest = -Double.infinity
    private var revision: UInt64 = 0

    private static func copiedPCM(_ frame: GuestReturnAudioFrame) -> PCM? {
        guard frame.sample.numSamples == 512, let block = frame.sample.dataBuffer,
              CMBlockBufferGetDataLength(block) == 4096 else { return nil }
        var values = [Float](repeating: 0, count: 1024)
        guard values.withUnsafeMutableBytes({ CMBlockBufferCopyDataBytes(block, atOffset: 0,
            dataLength: $0.count, destination: $0.baseAddress!) }) == noErr else { return nil }
        return .init(pts: frame.pts, samples: values)
    }
    func receive(_ frame: GuestReturnAudioFrame, age: Double) {
        guard let value = Self.copiedPCM(frame) else { return }
        lock.lock(); defer { lock.unlock() }
        received += 1; revision = frame.routingRevision
        if age.isFinite { youngest = min(youngest, age); oldest = max(oldest, age) }
        if pcm.count == 64 { pcm.removeFirst() }; pcm.append(value)
    }
    func admit(_ frame: GuestReturnAudioFrame) {
        guard let value = Self.copiedPCM(frame) else { return }
        lock.lock(); defer { lock.unlock() }; admitted += 1
        if admittedPCM.count == 64 { admittedPCM.removeFirst() }; admittedPCM.append(value)
    }
    func failed() { lock.lock(); errors += 1; lock.unlock() }
    func packet(_ packet: NativeGuestReturnOpusPacket, sent success: Bool) {
        lock.lock(); defer { lock.unlock() }
        attempted += 1; if success { sent += 1 }
        if packets.count == 128 { packets.removeFirst() }
        packets.append(.init(data: packet.data, pts: packet.pts, rtp: packet.rtp, sent: success))
    }
    private static func spectrum(_ chunks: [(CMTime, [Float])]) -> [String: Any] {
        let frequencies = [1000.0, 1700.0, 440.0, 880.0]
        var real = Array(repeating: Array(repeating: 0.0, count: 4), count: 2)
        var imaginary = real, squared = [0.0, 0.0], frames = 0
        for (pts, values) in chunks where pts.isNumeric {
            let count = values.count / 2; frames += count
            for index in 0..<count { for side in 0..<2 {
                let v = Double(values[index * 2 + side]); squared[side] += v * v
            } }
            for (f, frequency) in frequencies.enumerated() {
                let phase = pts.seconds.truncatingRemainder(dividingBy: 1) * 2 * .pi * frequency
                let step = 2 * .pi * frequency / 48000
                let cs = cos(step), sn = sin(step)
                var c = cos(phase), s = sin(phase)
                for index in 0..<count {
                    for side in 0..<2 {
                        let v = Double(values[index * 2 + side]); real[side][f] += v * c; imaginary[side][f] += v * s
                    }
                    let next = c * cs - s * sn; s = s * cs + c * sn; c = next
                }
            }
        }
        return ["frames": frames, "rate": 48000, "channels": (0..<2).map { side in
            ["rms": frames > 0 ? sqrt(squared[side] / Double(frames)) : 0,
             "amplitudes1000_1700_440_880": (0..<4).map { f in frames > 0
                ? 2 * hypot(real[side][f], imaginary[side][f]) / Double(frames) : 0 }] as [String: Any]
        }]
    }
    func snapshot(decode: Bool = false) -> [String: Any] {
        lock.lock()
        let chunks = pcm, eligible = admittedPCM, compressed = packets
        var result: [String: Any] = ["receivedChunks": received, "admittedChunks": admitted,
            "packetAttempts": attempted, "successfulSends": sent, "encoderErrors": errors,
            "routingRevision": revision, "retainedPackets": compressed.count,
            "minimumAgeSeconds": youngest.isFinite ? youngest : 0, "maximumAgeSeconds": oldest.isFinite ? oldest : 0]
        lock.unlock()
        result["receivedPCM"] = Self.spectrum(chunks.map { ($0.pts, $0.samples) })
        result["preEncoderPCM"] = Self.spectrum(eligible.map { ($0.pts, $0.samples) })
        if let last = chunks.last { result["lastPCMPTSSeconds"] = last.pts.seconds }
        result["rtpSteps"] = zip(compressed, compressed.dropFirst()).map { $1.rtp &- $0.rtp }
        if decode {
            result["emittedOpusDecode"] = Self.decode(compressed)
            result["successfullySentOpusDecode"] = Self.decode(compressed.filter(\.sent))
        }
        return result
    }
    /// Independent public AudioCodec decoder: no network, playback device or
    /// replacement encoder, and no assertion that metadata alone is PCM.
    private static func decode(_ packets: [Packet]) -> [String: Any] {
        var description = AudioComponentDescription(componentType: kAudioDecoderComponentType,
            componentSubType: kAudioFormatOpus, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { return ["unavailable": "decoder-component"] }
        var instance: AudioComponentInstance?
        let created = AudioComponentInstanceNew(component, &instance)
        guard created == noErr, let decoder = instance else { return ["unavailable": "decoder-create", "status": created] }
        defer { AudioCodecUninitialize(decoder); AudioComponentInstanceDispose(decoder) }
        var prime = AudioCodecPrimeInfo(leadingFrames: 0, trailingFrames: 0)
        let primed = AudioCodecSetProperty(decoder, kAudioCodecPropertyPrimeInfo, UInt32(MemoryLayout<AudioCodecPrimeInfo>.size), &prime)
        guard primed == noErr else { return ["unavailable": "decoder-prime", "status": primed] }
        var input = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var output = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        let initialized = AudioCodecInitialize(decoder, &input, &output, nil, 0)
        guard initialized == noErr else { return ["unavailable": "decoder-initialize", "status": initialized] }
        var decoded: [(CMTime, [Float])] = []
        for packet in packets {
            var bytes = UInt32(packet.data.count), count: UInt32 = 1
            var descriptor = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 960, mDataByteSize: bytes)
            let appended = packet.data.withUnsafeBytes { AudioCodecAppendInputData(decoder, $0.baseAddress!, &bytes, &count, &descriptor) }
            guard appended == noErr, count == 1, bytes == packet.data.count else { return ["unavailable": "decoder-append", "status": appended] }
            var samples = [Float](repeating: 0, count: 5760 * 2)
            var outputBytes: UInt32 = 5760 * 8, frames: UInt32 = 5760, status: UInt32 = 0
            let produced = AudioCodecProduceOutputPackets(decoder, &samples, &outputBytes, &frames, nil, &status)
            guard produced == noErr, frames == 960, outputBytes == 960 * 8 else {
                return ["unavailable": "decoder-output", "status": produced, "frames": frames, "bytes": outputBytes]
            }
            decoded.append((packet.pts, Array(samples.prefix(1920))))
        }
        var result = spectrum(decoded); result["packets"] = packets.count; return result
    }
}
