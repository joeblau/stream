import AVFoundation
import CoreMedia
import Foundation
import StreamCore

// Opaque identity substitutes only; the actual mixer/rings/gates/taps run.
struct CaptureSourceKey: Hashable, Sendable { let id: UUID }
struct SourceDefinitionID: Hashable, Sendable, CustomStringConvertible {
    let id = UUID()
    var description: String { id.uuidString }
}
private func require(_ value: Bool, _ text: String) { precondition(value, text) }
private func now() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }
private func floats(_ sample: CMSampleBuffer) -> [Float] {
    let block = sample.dataBuffer!
    var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
    values.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
    return values
}
private struct Packet: Sendable {
    let pts: CMTime, values: [Float], revision: UInt64
}
private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [Packet] = []
    func receive(_ sample: CMSampleBuffer, revision: UInt64 = 0) {
        let packet = Packet(pts: sample.presentationTimeStamp, values: floats(sample), revision: revision)
        lock.lock(); defer { lock.unlock() }
        require(packets.count < 2_000, "Owned evidence inventory exceeded bound")
        packets.append(packet)
    }
    func snapshot() -> [Packet] { lock.lock(); defer { lock.unlock() }; return packets }
}
private final class Blocked: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let probe = Probe()
    private var first = true // One real mailbox serial consumer owns this flag.
    func waitEntered() -> Bool { entered.wait(timeout: .now() + 1) == .success }
    func receive(_ frame: GuestReturnAudioFrame) {
        if first {
            first = false; entered.signal()
            require(release.wait(timeout: .now() + 3) == .success, "Owned blocked return cleanup exceeded bound")
        }
        probe.receive(frame.sample, revision: frame.routingRevision)
    }
}
private final class TalkbackTone: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Float = 0
    func set(_ value: Float) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> Float { lock.lock(); defer { lock.unlock() }; return value }
}
private final class TalkbackInsert: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = (process: 0, reset: 0)
    func process(_ sample: CMSampleBuffer) -> CMSampleBuffer { lock.lock(); counts.process += 1; lock.unlock(); return sample }
    func reset() { lock.lock(); counts.reset += 1; lock.unlock() }
    func snapshot() -> (process: Int, reset: Int) { lock.lock(); defer { lock.unlock() }; return counts }
}
private final class TalkbackReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: GuestReturnAudioFrame?
    func receive(_ frame: GuestReturnAudioFrame) { lock.lock(); self.frame = frame; lock.unlock() }
    func last() -> GuestReturnAudioFrame? { lock.lock(); defer { lock.unlock() }; return frame }
}
@main struct GuestReturnAudioHarness {
    private static func privateTalkback() async throws {
        let engine = AudioMixEngine(), mic = AudioChannelID.microphone(deviceUID: nil)
        let lease = GuestReceiveLease(slot: UUID(), peerID: UUID(), negotiation: UUID(), generation: 1)
        let music = AudioChannelID.media(SourceDefinitionID()), tone = TalkbackTone(), insert = TalkbackInsert(), receipt = TalkbackReceipt()
        let program = Probe(), monitor = Probe(), aux = Probe(), pre = Probe(), post = Probe(), returned = Probe()
        require(await engine.registerGuest(lease), "Talkback guest registration")
        require(engine.setGuestReturnAllowed(lease, allowed: true), "Talkback return route")
        _ = await engine.reserveCaptureHoldback(token: UUID(), milliseconds: 60)
        await engine.run()
        await engine.addChannel(mic, resetInsert: insert.reset, insert: insert.process)
        await engine.setChannelGain(mic, volume: 0.6, isMuted: false)
        await engine.setChannelAuxSend(mic, gain: 0.3)
        await engine.setChannelDelays([mic.label: 140])
        await engine.setChannelGain(music, volume: 1, isMuted: false)
        await engine.addTap(bus: .program, token: UUID(), sink: { program.receive($0) })
        await engine.addTap(bus: .monitor, token: UUID(), sink: { monitor.receive($0) })
        await engine.addTap(bus: .aux, token: UUID(), sink: { aux.receive($0) })
        await engine.addIsolatedTap(channel: mic, token: UUID(), processing: .beforeEffects, sink: { pre.receive($0) })
        await engine.addIsolatedTap(channel: mic, token: UUID(), processing: .afterEffects, sink: { post.receive($0) })
        require(await engine.addGuestReturnTap(lease, token: UUID(), sink: { receipt.receive($0); returned.receive($0.sample, revision: $0.routingRevision) }), "Talkback return tap")
        let producer = Task {
            let origin = now() - CMTime(value: 512, timescale: 48_000)
            var index: Int64 = 0
            while !Task.isCancelled {
                let pts = origin + CMTime(value: index * 512, timescale: 48_000)
                engine.enqueue(mic, sample(pcm(pts, frequency: 2_000, amplitude: Double(tone.get())), pts: pts))
                engine.enqueue(music, sample(pcm(pts, frequency: 1_000, amplitude: 0.4), pts: pts))
                index += 1
                try? await Task.sleep(for: .seconds(max(0, (origin + CMTime(value: index * 512 + 512, timescale: 48_000) - now()).seconds)))
            }
        }
        defer { producer.cancel() }
        try await Task.sleep(for: .milliseconds(160))
        let press = UUID()
        require(engine.beginGuestTalkback(lease, source: mic, press: press), "Recent already-running mic refused private route")
        var ducking = DuckingSettings()
        ducking.isEnabled = true; ducking.sidechainLabels = [mic.label]; ducking.targetLabels = [music.label]
        ducking.thresholdDb = -30; ducking.reductionDb = 12; ducking.attackMs = 1; ducking.holdMs = 0; ducking.releaseMs = 10
        await engine.setDucking(.init(ducking, chunkDurationSeconds: 512.0 / 48_000))
        let calls = insert.snapshot().process
        tone.set(0.25)
        let start = now().seconds + 0.12
        try await Task.sleep(for: .milliseconds(480))
        let end = program.snapshot().last!.pts.seconds
        for probe in [program, monitor, aux, pre, post] {
            require(amplitude(probe.snapshot(), frequency: 2_000, from: start, to: end) < 0.003,
                    "Private talkback leaked into a public/private bus or pre/post ISO")
        }
        require(abs(amplitude(returned.snapshot(), frequency: 2_000, from: start, to: end) - 0.25) < 0.015,
                "Addressed return did not carry unity private mic independently of its0.6 public fader")
        require(abs(amplitude(program.snapshot(), frequency: 1_000, from: start, to: end) - 0.4) < 0.015,
                "Private routing disturbed unrelated Program audio")
        require(insert.snapshot().process == calls && insert.snapshot().reset == 1, "Private capture entered public insert history")
        let oldPrivatePTS = now() - CMTime(value: 512, timescale: 48_000)
        let retainedPrivateFrame = receipt.last()!
        require(engine.endGuestTalkback(lease, press: press), "Matching release failed")
        require(!engine.guestReturnFrameIsCurrent(retainedPrivateFrame), "Release left queued private PCM/Opus authority current")
        tone.set(0)
        engine.enqueue(mic, sample(pcm(oldPrivatePTS, frequency: 2_000, amplitude: 1), pts: oldPrivatePTS))
        try await Task.sleep(for: .milliseconds(300))
        let releasedEnd = program.snapshot().last!.pts.seconds
        for probe in [program, monitor, aux, pre, post, returned] {
            require(amplitude(probe.snapshot(), frequency: 2_000, from: releasedEnd - 0.16, to: releasedEnd) < 0.003,
                    "Released private tail or late captured buffer escaped its privacy boundary")
        }
        require(insert.snapshot().reset == 2, "Release retained public insert history")
        require(abs(amplitude(program.snapshot(), frequency: 1_000, from: releasedEnd - 0.16, to: releasedEnd) - 0.4) < 0.015,
                "Private meter history modulated public music through ducking after release")
        await engine.setDucking(nil)
        tone.set(0.25)
        try await Task.sleep(for: .milliseconds(520))
        let restoredEnd = program.snapshot().last!.pts.seconds
        for (probe, expected) in [(program, 0.15), (monitor, 0.15), (aux, 0.075), (pre, 0.25), (post, 0.25)] {
            require(abs(amplitude(probe.snapshot(), frequency: 2_000, from: restoredEnd - 0.16, to: restoredEnd) - expected) < 0.015,
                    "Release changed the saved microphone fader/Aux/delay/ISO routing")
        }
        tone.set(0)
        await engine.addChannel(mic, resetInsert: insert.reset, insert: insert.process)
        engine.enqueue(mic, sample(pcm(oldPrivatePTS, frequency: 2_000, amplitude: 1), pts: oldPrivatePTS))
        try await Task.sleep(for: .milliseconds(300))
        let rebuiltEnd = program.snapshot().last!.pts.seconds
        require(amplitude(pre.snapshot(), frequency: 2_000, from: rebuiltEnd - 0.16, to: rebuiltEnd) < 0.003,
                "Channel replacement forgot the capture rejection floor")
        let secondPress = UUID()
        require(engine.beginGuestTalkback(lease, source: mic, press: secondPress), "Explicit next hold refused")
        require(!engine.endGuestTalkback(lease, press: press) && engine.guestTalkbackIsActive(lease, source: mic, press: secondPress),
                "Old release altered a new deliberate hold")
        require(engine.removeGuest(lease), "Talkback removal failed")
        require(!engine.guestTalkbackIsActive(lease, source: mic, press: secondPress), "Removed guest retained private route")
        require(!engine.beginGuestTalkback(lease, source: mic, press: UUID()), "Retired context reactivated private capture")
        producer.cancel(); await producer.value; await engine.stop()
        print("PASS: addressed private mic only in current recipient return; Program/Monitor/Aux/pre+post ISO silent for private voice, insert bypass+reset, unaffected music, late-buffer release, exact press and full-lease retirement")
    }
    private static func opusCodec() throws {
        let encoder: NativeGuestReturnAudioEncoder
        do { encoder = try NativeGuestReturnAudioEncoder() }
        catch { print("UNAVAILABLE: actual public native Opus return encoder"); throw error }
        let lease = GuestReceiveLease(slot: UUID(), peerID: UUID(), negotiation: UUID(), generation: 1)
        let origin = CMTime(value: 123_456_789_011, timescale: 1_000_000_000)
        var packets: [NativeGuestReturnOpusPacket] = [], original: [Float] = [], originalRight: [Float] = []
        for chunk in 0..<120 {
            let pts = origin + CMTime(value: Int64(chunk * 512), timescale: 48_000)
            let buffer = pcm(pts, frequency: 1_000, amplitude: 0.2)
            for index in 0..<512 {
                let position = chunk * 512 + index
                let value: Float = position < 2_048 ? 0 : Float(0.2 * sin(Double(position) * 2 * .pi * 1_000 / 48_000))
                let right: Float = position < 2_048 ? 0 : Float(0.1 * sin(Double(position) * 2 * .pi * 1_700 / 48_000))
                buffer.floatChannelData![0][index] = value; buffer.floatChannelData![1][index] = right
                original.append(value)
                originalRight.append(right)
            }
            packets += try encoder.encode(.init(lease: lease, routingRevision: 1, sample: sample(buffer, pts: pts)))
        }
        require(packets.count > 50 && packets.count <= 64, "Actual Opus packetization/count is unsupported")
        for index in packets.indices {
            require(packets[index].frames == 960 && packets[index].data.count <= 1275, "Native encoded Opus packet bounds/count")
            if index > 0 {
                require(packets[index].rtp &- packets[index - 1].rtp == 960,
                        "Original source grid was compressed or rebased in RTP")
            }
        }
        var description = AudioComponentDescription(componentType: kAudioDecoderComponentType,
            componentSubType: kAudioFormatOpus, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw NativeGuestReturnAudioError.unavailable }
        var instance: AudioComponentInstance?
        require(AudioComponentInstanceNew(component, &instance) == noErr && instance != nil, "Actual public Opus decoder unavailable")
        let decoder = instance!
        defer { AudioCodecUninitialize(decoder); AudioComponentInstanceDispose(decoder) }
        var prime = AudioCodecPrimeInfo(leadingFrames: 0, trailingFrames: 0)
        require(AudioCodecSetProperty(decoder, kAudioCodecPropertyPrimeInfo, UInt32(MemoryLayout<AudioCodecPrimeInfo>.size), &prime) == noErr,
                "Actual decoder exact packet count configuration")
        var input = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var output = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        require(AudioCodecInitialize(decoder, &input, &output, nil, 0) == noErr, "Actual public decoder initialize")
        var decoded: [Float] = [], decodedRight: [Float] = []
        for packet in packets {
            var bytes = UInt32(packet.data.count), count: UInt32 = 1
            var descriptor = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 960, mDataByteSize: bytes)
            let appended = packet.data.withUnsafeBytes { AudioCodecAppendInputData(decoder, $0.baseAddress!, &bytes, &count, &descriptor) }
            require(appended == noErr && count == 1 && bytes == packet.data.count, "Actual public encoded packet ingest")
            var samples = [Float](repeating: 0, count: 5_760 * 2), outputBytes: UInt32 = 5_760 * 8, frames: UInt32 = 5_760, status: UInt32 = 0
            let produced = AudioCodecProduceOutputPackets(decoder, &samples, &outputBytes, &frames, nil, &status)
            if produced != noErr || frames != 960 || outputBytes != 960 * 8 {
                let prefix = packet.data.prefix(16).map { String(format: "%02x", $0) }.joined()
                print("Actual native Opus decode: status=\(produced), frames=\(frames), bytes=\(outputBytes), producedState=\(status), packetPrefix=\(prefix)")
            }
            require(produced == noErr && frames == 960 && outputBytes == 960 * 8, "Actual encoded packet does not decode960 stereo frames")
            for index in 0..<960 {
                decoded.append(samples[index * 2])
                decodedRight.append(samples[index * 2 + 1])
            }
        }
        let leading = ProgramRecordingSession.audioFrameOffset(from: packets[0].pts, to: origin, rate: 48_000, rounding: .roundHalfAwayFromZero)
        var errors: [Int: Double] = [:]
        for offset in [0, 120, 312, 432] {
            var squared = 0.0, count = 0
            for index in 3_000..<decoded.count {
                let source = index - offset
                guard source >= 0, source < original.count else { continue }
                let error = Double(decoded[index] - original[source]); squared += error * error; count += 1
            }
            errors[offset] = sqrt(squared / Double(count))
        }
        print("Actual public Opus: \(packets.count)x960 stereo packets; sourceFrames=\(original.count), decodedFrames=\(decoded.count), declaredLeading=\(leading), waveform RMSE offsets=\(errors)")
        require(leading == 312 && errors[312]! < 0.03 && errors[312]! < errors[0]!, "Declared native codec priming does not preserve actual source cue")
        var rightSquared = 0.0, swappedSquared = 0.0
        for index in 3_000..<decodedRight.count {
            let right = Double(decodedRight[index] - originalRight[index - 312])
            let swapped = Double(decodedRight[index] - original[index - 312])
            rightSquared += right * right; swappedSquared += swapped * swapped
        }
        let rightError = sqrt(rightSquared / Double(decodedRight.count - 3_000))
        let swappedError = sqrt(swappedSquared / Double(decodedRight.count - 3_000))
        print("Actual encoded stereo right1700Hz RMSE=\(rightError), swappedleft1000Hz RMSE=\(swappedError)")
        require(rightError < 0.03 && swappedError > 0.1, "Encoded Opus collapsed/swapped independent stereo content")
        let firstCue = decoded.firstIndex { abs($0) > 0.02 }!
        let actualCue = packets[0].pts + CMTime(value: Int64(firstCue), timescale: 48_000)
        require(abs((actualCue - origin).seconds - 2_048.0 / 48_000) < 0.001,
                "Actual native encoded cue timestamp lost source alignment")
        let gapPTS = origin + CMTime(value: 120 * 512 + 2_400, timescale: 48_000)
        var afterGap: [NativeGuestReturnOpusPacket] = []
        for index in 0..<3 {
            let pts = gapPTS + CMTime(value: Int64(index * 512), timescale: 48_000)
            afterGap += try encoder.encode(.init(lease: lease, routingRevision: 2,
                sample: sample(pcm(pts, frequency: 1_000, amplitude: 0.2), pts: pts)))
        }
        require(!afterGap.isEmpty && ProgramRecordingSession.audioFrameOffset(from: afterGap[0].pts, to: gapPTS,
                rate: 48_000, rounding: .roundHalfAwayFromZero) == leading,
                "A genuine source gap/revision was filled, compressed or restamped")
        require(encoder.discardedFrames == leading, "Discontinuity must account for the actual un-emitted native codec tail")
        print("PASS: actual public native Opus encode→decode stereo/count/20ms packet bounds, declared312-frame priming source cue, nanosecond original PCM grid and genuine2400-frame discontinuity")
    }
    static func pcm(_ pts: CMTime, frequency: Double, amplitude: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        pcm.frameLength = 512
        let sourceFrame = CMTimeConvertScale(pts, timescale: 48_000, method: .roundHalfAwayFromZero).value
        for index in 0..<512 {
            let value = Float(amplitude * sin(Double(sourceFrame + Int64(index)) * 2 * .pi * frequency / 48_000))
            for side in 0..<2 { pcm.floatChannelData![side][index] = value }
        }
        return pcm
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
    private static func amplitude(_ packets: [Packet], frequency: Double, from: Double, to: Double) -> Double {
        var sine = 0.0, cosine = 0.0, count = 0
        for packet in packets {
            for index in 0..<(packet.values.count / 2) {
                let time = packet.pts.seconds + Double(index) / 48_000
                guard time >= from, time < to else { continue }
                let phase = time * 2 * .pi * frequency
                sine += Double(packet.values[index * 2]) * sin(phase)
                cosine += Double(packet.values[index * 2]) * cos(phase); count += 1
            }
        }
        require(count > 4_800, "Insufficient real mixed PCM evidence")
        return 2 * sqrt(sine * sine + cosine * cosine) / Double(count)
    }
    private static func phase(_ name: String, probe: Probe, localExpected: Double) async throws {
        // Wait for actual output to pass the command's host acknowledgment.
        // This retains independent source clocks under a delayed actor.
        let acknowledged = now().seconds
        for _ in 0..<200 {
            if (probe.snapshot().last?.pts.seconds ?? -.infinity) > acknowledged + 0.05 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let start = probe.snapshot().last!.pts.seconds + 512.0 / 48_000
        try await Task.sleep(for: .milliseconds(300))
        let end = probe.snapshot().last!.pts.seconds
        let packets = probe.snapshot()
        let local = amplitude(packets, frequency: 1_000, from: start, to: end)
        let own = amplitude(packets, frequency: 2_000, from: start, to: end)
        let privateBus = amplitude(packets, frequency: 3_000, from: start, to: end)
        print("Return \(name): original window \(start)...\(end); local=\(local), own=\(own), unaddressedPrivate=\(privateBus)")
        require(abs(local - localExpected) < 0.025 && own < 0.003 && privateBus < 0.003,
                "Actual mix-minus/preclamp/private exclusion mismatch")
    }
    static func main() async throws {
        setbuf(stdout, nil)
        try opusCodec()
        try await privateTalkback()
        let engine = AudioMixEngine(), returned = Probe(), program = Probe(), aux = Probe()
        let lease = GuestReceiveLease(slot: UUID(), peerID: UUID(), negotiation: UUID(), generation: 1)
        let foreign = GuestReceiveLease(slot: lease.slot, peerID: UUID(), negotiation: UUID(), generation: 1)
        let local = AudioChannelID.media(SourceDefinitionID()), privateSource = AudioChannelID.media(SourceDefinitionID())
        require(!(await engine.addGuestReturnTap(lease, token: UUID(), sink: { _ in })), "Unknown lease acquired return PCM")
        require(await engine.registerGuest(lease), "Owned full lease registration")
        require(!engine.setGuestReturnAllowed(foreign, allowed: true), "Foreign peer granted return")
        let returnToken = UUID()
        require(await engine.addGuestReturnTap(lease, token: returnToken, sink: { returned.receive($0.sample, revision: $0.routingRevision) }), "Owned return registration")
        await engine.addTap(bus: .program, token: UUID(), sink: { program.receive($0) })
        await engine.addTap(bus: .aux, token: UUID(), sink: { aux.receive($0) })
        await engine.setChannelGain(local, volume: 1, isMuted: false)
        await engine.setChannelGain(privateSource, volume: 0, isMuted: false)
        require(engine.setGuestRouting(lease, programAllowed: true, monitorAllowed: false), "Owned source Program grant")
        await engine.run()
        await engine.addChannel(privateSource)
        await engine.setChannelAuxSend(privateSource, gain: 1)
        let localBase = CMTimeConvertScale(now(), timescale: 48_000, method: .roundTowardZero) + CMTime(value: 3_840, timescale: 48_000)
        let guestBase = localBase + CMTime(value: 1_920, timescale: 48_000), mapping = UUID()
        let producer = Task {
            var index: Int64 = 0
            while !Task.isCancelled {
                let offset = CMTime(value: index * 512, timescale: 48_000)
                let localPTS = localBase + offset, guestPTS = guestBase + offset
                engine.enqueue(local, sample(pcm(localPTS, frequency: 1_000, amplitude: 0.6), pts: localPTS))
                engine.enqueue(privateSource, sample(pcm(localPTS, frequency: 3_000, amplitude: 0.3), pts: localPTS))
                require(engine.enqueueGuest(.init(lease: lease, pcm: pcm(guestPTS, frequency: 2_000, amplitude: 0.8),
                    pts: guestPTS, duration: CMTime(value: 512, timescale: 48_000), mappingGeneration: mapping,
                    clockQuality: .senderReportAligned)), "Valid original-clock guest PCM rejected")
                index += 1
                let due = (localBase + CMTime(value: index * 512, timescale: 48_000)).seconds - 0.08
                let delay = max(0, due - now().seconds)
                try? await Task.sleep(for: .seconds(delay))
            }
        }
        defer { producer.cancel() }
        try await Task.sleep(for: .milliseconds(200))
        require(returned.snapshot().isEmpty, "Return grant defaulted open")
        require(engine.setGuestReturnAllowed(lease, allowed: true), "Current recipient grant")
        try await phase("own-and-private-excluded-before-clamp", probe: returned, localExpected: 0.6)
        let samples = program.snapshot().flatMap(\.values)
        require(samples.contains { abs($0) == 1 }, "Real Program did not clip; preclamp exclusion remains untested")
        let end = aux.snapshot().last!.pts.seconds
        require(amplitude(aux.snapshot(), frequency: 3_000, from: end - 0.25, to: end) > 0.25,
                "Unaddressed private aux source was not actually active")
        for packet in returned.snapshot() {
            require(packet.values.count == 1_024 && program.snapshot().contains { $0.pts == packet.pts },
                    "Return PCM lost original common Program chunk PTS/count")
        }
        await engine.setChannelGain(local, volume: 1, isMuted: true)
        try await phase("local-mute", probe: returned, localExpected: 0)
        await engine.setChannelGain(local, volume: 0.4, isMuted: false)
        try await phase("local-nonunity-restore", probe: returned, localExpected: 0.24)
        let blocked = Blocked(), slowToken = UUID()
        require(await engine.addGuestReturnTap(lease, token: slowToken, capacity: 2, sink: blocked.receive), "Owned blocked return tap")
        require(await Task.detached { blocked.waitEntered() }.value, "Real return callback did not enter")
        try await Task.sleep(for: .milliseconds(100))
        require(engine.setGuestReturnAllowed(lease, allowed: false), "Synchronous return revoke")
        require(engine.setGuestReturnAllowed(lease, allowed: true), "Same lease return reopen")
        blocked.release.signal()
        try await Task.sleep(for: .milliseconds(100))
        let slow = blocked.probe.snapshot(), oldRevision = slow.first!.revision
        require(slow.dropFirst().allSatisfy { $0.revision != oldRevision }, "Reopen resurrected queued pre-revoke return PCM")
        require((await engine.statsSnapshot()).tapDrops.values.contains { $0 > 0 }, "Slow return did not exercise bounded drop-oldest queue")
        await engine.removeTap(slowToken)
        producer.cancel(); await producer.value
        require(engine.removeGuest(lease), "Owned admission removal")
        let replacement = GuestReceiveLease(slot: lease.slot, peerID: UUID(), negotiation: UUID(), generation: 2)
        require(await engine.registerGuest(replacement), "Explicit replacement full lease")
        require(!engine.setGuestReturnAllowed(lease, allowed: true), "Stale lease revived return authority")
        require(engine.setGuestReturnAllowed(replacement, allowed: true), "New admitted recipient grant")
        let count = returned.snapshot().count
        try await Task.sleep(for: .milliseconds(100))
        require(returned.snapshot().count == count, "Old recipient callback crossed replacement admission")
        engine.retireGuestAdmissions()
        require(!engine.setGuestReturnAllowed(replacement, allowed: true), "Permanent retirement reopened return")
        await engine.removeTap(returnToken); await engine.stop()
        print("PASS: actual full-lease preclamp mix-minus excludes own guest and unaddressed private aux; Program source clock/count, native PCM mutes, bounded slow return, queued revoke+reopen, stale replacement and permanent retirement")
    }
}
