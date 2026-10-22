import AVFoundation
import CoreMedia
import Foundation
import StreamCore

struct CaptureSourceKey: Hashable, Sendable { let id: UUID }
struct SourceDefinitionID: Hashable, Sendable, CustomStringConvertible {
    let id = UUID(); var description: String { id.uuidString }
}
private func require(_ value: Bool, _ text: String) { precondition(value, text) }
private final class UnitReturnSink: @unchecked Sendable {
    let encoder: NativeGuestReturnAudioEncoder
    init() throws { encoder = try NativeGuestReturnAudioEncoder() }
    func receive(_ frame: GuestReturnAudioFrame) {
        let age = (CMClockGetTime(CMClockGetHostTimeClock()) - frame.pts).seconds
        let diagnostic = ReturnSenderDiagnostic.shared
        diagnostic.receive(frame, age: age)
        guard age >= 0 && age <= 0.25 else { return }
        diagnostic.admit(frame)
        do { for packet in try encoder.encode(frame) { diagnostic.packet(packet, sent: false) } }
        catch { diagnostic.failed() }
    }
}
@main struct ReturnSenderLocalDiagnostic {
    static func main() async throws {
        let mixer = AudioMixEngine(), mic = AudioChannelID.microphone(deviceUID: nil)
        let lease = GuestReceiveLease(slot: UUID(), peerID: UUID(), negotiation: UUID(), generation: 1)
        let sink = try UnitReturnSink(), token = UUID()
        require(await mixer.registerGuest(lease), "Actual recipient registration")
        require(mixer.setGuestReturnAllowed(lease, allowed: true), "Actual recipient return permission")
        require(await mixer.addGuestReturnTap(lease, token: token, sink: { sink.receive($0) }), "Actual recipient mailbox")
        await mixer.setChannelGain(mic, volume: 1, isMuted: false)
        await mixer.run()
        let producer = Task.detached {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
            let origin = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(value: 3840, timescale: 48000)
            var index: Int64 = 0
            let start = ContinuousClock.now, clock = ContinuousClock()
            while !Task.isCancelled {
                let pts = origin + CMTime(value: index * 512, timescale: 48000)
                let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!; pcm.frameLength = 512
                for frame in 0..<512 {
                    let time = pts.seconds + Double(frame) / 48000
                    pcm.floatChannelData![0][frame] = Float(0.4 * sin(time * 2 * .pi * 1000))
                    pcm.floatChannelData![1][frame] = Float(0.2 * sin(time * 2 * .pi * 1700))
                }
                mixer.enqueue(mic, sample(pcm, pts: pts)); index += 1
                try? await clock.sleep(until: start + .seconds(Double(index * 512) / 48000))
            }
        }
        try await Task.sleep(for: .milliseconds(2200))
        producer.cancel(); await producer.value
        await mixer.removeTap(token); await mixer.stop()
        let receipt = ReturnSenderDiagnostic.shared.snapshot(decode: true)
        let pcm = receipt["preEncoderPCM"] as! [String: Any], decoded = receipt["emittedOpusDecode"] as! [String: Any]
        func amplitude(_ source: [String: Any], _ side: Int, _ frequency: Int) -> Double {
            ((source["channels"] as! [[String: Any]])[side]["amplitudes1000_1700_440_880"] as! [Double])[frequency]
        }
        require((receipt["packetAttempts"] as! Int) >= 80 && (receipt["successfulSends"] as! Int) == 0 && (receipt["encoderErrors"] as! Int) == 0,
                "Bounded actual encoder observation failed; no socket send is claimed by this unit")
        require(abs(amplitude(pcm,0,0)-0.4) < 0.035 && abs(amplitude(pcm,1,1)-0.2) < 0.025, "Actual recipient PCM is not the owned stereo tone")
        require(abs(amplitude(decoded,0,0)-0.4) < 0.04 && abs(amplitude(decoded,1,1)-0.2) < 0.03, "Actual emitted Opus does not decode the owned stereo tone in a separate AudioCodec instance")
        #if STREAM_GUEST_RFC_OPUS_VALIDATION
        let reference = receipt["referenceOpusDecode"] as! [String: Any]
        require(reference["unavailable"] == nil, "Reference libopus decoder unavailable: \(reference)")
        require(reference["packetFrames"] as? Int == 960 && reference["packetChannels"] as? Int == 2,
                "Actual payload is not RFC stereo20ms Opus")
        require(reference["frames"] as? Int == (reference["packets"] as! Int) * 960 && reference["sourceRTPAll960"] as? Bool == true
                && reference["sourcePTSAll960"] as? Bool == true, "Reference count/source clock framing changed")
        require(reference["malformedTOCRejected"] as? Bool == true, "Reference parser accepted malformedTOC control")
        require(abs(amplitude(reference,0,0)-0.4) < 0.04 && abs(amplitude(reference,1,1)-0.2) < 0.03,
                "Reference decoded stereo source amplitudes differ")
        require(amplitude(reference,0,1) < 0.005 && amplitude(reference,1,0) < 0.005,
                "Reference decoder lost stereo channel identity")
        require((0..<2).allSatisfy { amplitude(reference,$0,2) < 0.005 && amplitude(reference,$0,3) < 0.005 },
                "Reference decoder created absent440/880Hz tones")
        let rms = (reference["channels"] as! [[String: Any]]).map { $0["rms"] as! Double }
        require(abs(rms[0] - 0.4 / sqrt(2)) < 0.025 && abs(rms[1] - 0.2 / sqrt(2)) < 0.02,
                "Reference decoded RMS differs from generated stereo amplitudes")
        print("PASS: shipping encoder raw20ms/stereo payloads decode through actual existing reference libopus; original PTS/RTP960 grid, stereo frequency/amplitude identity and malformedTOC negative control")
        #endif
        print(String(decoding: try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]), as: UTF8.self))
        print("PASS:2.2s actual mixer/rings/recipient-return mailbox→shipping native Opus encoder→separate Apple AudioCodec stereo PCM decode; no transport/browser/device/capture/permissions claim")
    }
    static func sample(_ pcm: AVAudioPCMBuffer, pts: CMTime) -> CMSampleBuffer {
        let frames = Int(pcm.frameLength)
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames { for side in 0..<2 { samples[frame * 2 + side] = pcm.floatChannelData![side][frame] } }
        var block: CMBlockBuffer?
        samples.withUnsafeBytes {
            require(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: $0.count,
                blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: $0.count, flags: 0,
                blockBufferOut: &block) == noErr, "Owned PCM block allocation")
            _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: $0.count)
        }
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
            mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?, result: CMSampleBuffer?
        require(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, "Owned PCM format")
        require(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!,
            formatDescription: format!, sampleCount: frames, presentationTimeStamp: pts,
            packetDescriptions: nil, sampleBufferOut: &result) == noErr, "Owned timed PCM")
        return result!
    }
}
