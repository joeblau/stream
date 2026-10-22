import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import StreamCore

private struct ProgramPacket: @unchecked Sendable { let sample: CMSampleBuffer; let frame: Int64; let floats: [Float] }
private final class ProgramProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [ProgramPacket] = []
    func receive(_ sample: CMSampleBuffer) {
        guard let pcm = CanonicalAudioConverter.makePCMBuffer(from: sample),
              let floats = CanonicalAudioConverter.interleavedFloats(pcm) else { return }
        let frame = CMTimeConvertScale(sample.presentationTimeStamp, timescale: 48_000, method: .roundHalfAwayFromZero).value
        lock.withLock { if packets.count < 128 { packets.append(.init(sample: sample, frame: frame, floats: floats)) } }
    }
    var values: [ProgramPacket] { lock.withLock { packets } }
}

private final class OwnedHAL: StudioProgramHALSyscalls, @unchecked Sendable {
    private let lock = NSLock()
    private var handles: [UUID: StudioProgramRenderOwner] = [:]
    private var listeners: [UUID: @Sendable () -> Void] = [:]
    var available = true, failDestroy = false, failWatch = false, cancelAfterStart = false
    private(set) var finds = 0, creates = 0, starts = 0, stops = 0, destroys = 0
    func find() -> AudioDeviceID { lock.withLock { finds += 1; return available ? StudioProgramFixtureFind() : 0 } }
    func preflight(_ device: AudioDeviceID) -> Bool { StudioProgramFixturePreflight(device) }
    func createIO(_ device: AudioDeviceID, render: StudioProgramRenderOwner) throws -> UUID {
        lock.withLock { precondition(handles.isEmpty); let token = UUID(); handles[token] = render; creates += 1; return token }
    }
    func start(_ handle: UUID) throws {
        try lock.withLock {
            precondition(handles[handle] != nil)
            guard StudioProgramFixtureStart(1) == noErr else { throw StudioProgramProducerError.unavailable }
            starts += 1
            if cancelAfterStart { withUnsafeCurrentTask { $0?.cancel() } }
        }
    }
    func stop(_ handle: UUID) throws {
        try lock.withLock {
            precondition(handles[handle] != nil)
            guard StudioProgramFixtureStop(1) == noErr else { throw StudioProgramProducerError.unavailable }
            stops += 1
        }
    }
    func destroy(_ handle: UUID) throws {
        try lock.withLock {
            if failDestroy { throw StudioProgramProducerError.unavailable }
            precondition(handles.removeValue(forKey: handle) != nil); destroys += 1
        }
    }
    func watch(_ device: AudioDeviceID, address: AudioObjectPropertyAddress,
               changed: @escaping @Sendable () -> Void) throws -> UUID {
        try lock.withLock {
            if failWatch { throw StudioProgramProducerError.unavailable }
            let token = UUID(); listeners[token] = changed; return token
        }
    }
    func removeWatch(_ token: UUID) throws { lock.withLock { listeners[token] = nil } }
    func changed() { let callbacks = lock.withLock { Array(listeners.values) }; for callback in callbacks { callback() } }
    var liveCount: Int { lock.withLock { handles.count } }
}
private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock(); private var stored = false
    var value: Bool { lock.withLock { stored } }
    func finish() { lock.withLock { stored = true } }
}

@main struct StudioProgramProducerHarness {
    static func waitEntered(_ semaphore: DispatchSemaphore) -> Bool { semaphore.wait(timeout: .now() + 2) == .success }
    @MainActor static func until(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
        preconditionFailure("Owned Program boundary timed out")
    }
    static func sample(pts: CMTime, frames: Int = 512, rate: Double = 48_000) throws -> CMSampleBuffer {
        let floats = (0..<frames).flatMap { _ in [Float(0.4), Float(-0.2)] }
        var format: CMAudioFormatDescription?
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        precondition(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr)
        var block: CMBlockBuffer?
        precondition(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: floats.count * 4,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: floats.count * 4, flags: 0, blockBufferOut: &block) == noErr)
        precondition(floats.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: $0.count) } == noErr)
        var result: CMSampleBuffer?
        precondition(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!,
            sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &result) == noErr)
        return result!
    }
    static func time(hostFrame: Int64, deviceFrame: Int64) -> AudioTimeStamp {
        var time = AudioTimeStamp()
        time.mSampleTime = Double(deviceFrame)
        time.mHostTime = CMClockConvertHostTimeToSystemUnits(CMTime(value: hostFrame, timescale: 48_000))
        time.mFlags = [.hostTimeValid, .sampleTimeValid]
        return time
    }
    static func render(_ core: StudioProgramRenderOwner, time: AudioTimeStamp, frames: Int = 512) -> (OSStatus, [Float]) {
        var values = [Float](repeating: .nan, count: frames * 2)
        var time = time
        let status = values.withUnsafeMutableBytes { data -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(data.count), mData: data.baseAddress))
            return StreamProgramHALIOProc(3, &time, nil, nil, &list, &time, UnsafeMutableRawPointer(core.pointer))
        }
        return (status, values)
    }
    @MainActor static func main() async throws {
        precondition(CommandLine.arguments.count == 3)
        let artifacts = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: false)
        precondition(StudioProgramFixtureLoad(CommandLine.arguments[1]))
        precondition(StudioProgramFixtureStart(99) == noErr)
        let mixer = AudioMixEngine(), calls = OwnedHAL(), producer = StudioProgramProducer(mixer: mixer, calls: calls)
        do { try await producer.start(acknowledgeUnqualifiedHALRoute: false); preconditionFailure("Implicit evaluation admitted") } catch {}
        precondition(calls.finds == 0)
        calls.available = false
        do { try await producer.start(acknowledgeUnqualifiedHALRoute: true); preconditionFailure("Missing device admitted") } catch {}
        calls.available = true
        StudioProgramFixtureForeignUID(true)
        do { try await producer.start(acknowledgeUnqualifiedHALRoute: true); preconditionFailure("Foreign device admitted") } catch {}
        StudioProgramFixtureForeignUID(false)
        precondition(StudioProgramFixtureRate(44_100) == noErr)
        do { try await producer.start(acknowledgeUnqualifiedHALRoute: true); preconditionFailure("44.1k silently changed or admitted") } catch {}
        precondition(calls.creates == 0)
        precondition(StudioProgramFixtureRate(48_000) == noErr)
        calls.failWatch = true
        do { try await producer.start(acknowledgeUnqualifiedHALRoute: true); preconditionFailure("Unwatched device admitted") } catch {}
        precondition(calls.starts == 0 && calls.liveCount == 0)
        calls.failWatch = false
        calls.cancelAfterStart = true
        let canceledStart = Task { try await producer.start(acknowledgeUnqualifiedHALRoute: true) }
        do { try await canceledStart.value; preconditionFailure("Cancellation during HAL start left output running") }
        catch { precondition(error is CancellationError) }
        precondition(calls.liveCount == 0 && calls.starts == calls.stops)
        calls.cancelAfterStart = false

        let probe = ProgramProbe(), oracle = UUID(), source = AudioChannelID.media(SourceDefinitionID())
        await mixer.addTap(bus: .program, token: oracle, capacity: 2, sink: probe.receive)
        await mixer.setChannelGain(source, volume: 0.5, isMuted: false)
        await mixer.addChannel(source)
        await mixer.setBusGain(.program, gain: 0.75)
        try await producer.start(acknowledgeUnqualifiedHALRoute: true)
        let firstCore = producer.render!
        await mixer.run()
        try await until { !probe.values.isEmpty }
        let base = probe.values[0].sample.presentationTimeStamp
        for n in 1..<48 { mixer.enqueue(source, try sample(pts: base + CMTime(value: Int64(n * 512), timescale: 48_000))) }
        try await until { probe.values.count >= 12 }
        await mixer.setChannelGain(source, volume: 0.5, isMuted: true)
        try await until { probe.values.count >= 24 }
        let packets = Array(probe.values.prefix(24))
        precondition(packets.contains { abs(($0.floats.first ?? 0) - 0.15) < 0.00001 }, "Real Program fader and bus gain must affect PCM")
        precondition(packets.suffix(6).allSatisfy { $0.floats.allSatisfy { abs($0) < 0.000001 } }, "Real Program mute must reach silence after its existing ramp")
        var deviceSample: Double = 0, deviceTicks: UInt64 = 0
        precondition(StudioProgramFixtureTime(&deviceSample, &deviceTicks))
        let zeroHostFrame = StreamProgramHostFrameAtTicks(deviceTicks) - Int64(deviceSample)
        let firstDeviceFrame = packets[0].frame + Int64(STREAM_PROGRAM_DELAY_FRAMES) - zeroHostFrame
        var lastDeviceFrame = firstDeviceFrame
        var maxError: Float = 0
        for packet in packets {
            let outputHostFrame = packet.frame + Int64(STREAM_PROGRAM_DELAY_FRAMES)
            var stamp = time(hostFrame: outputHostFrame, deviceFrame: firstDeviceFrame + packet.frame - packets[0].frame)
            while mach_absolute_time() < stamp.mHostTime { try await Task.sleep(for: .milliseconds(1)) }
            var rendered = [Float](repeating: .nan, count: 1024), received = rendered
            let status = rendered.withUnsafeMutableBufferPointer { output in received.withUnsafeMutableBufferPointer { input in
                StudioProgramFixtureTransfer(firstCore.pointer, &stamp, 512, output.baseAddress, input.baseAddress)
            } }
            precondition(status == noErr)
            for n in 0..<1024 {
                maxError = max(maxError, max(abs(rendered[n] - packet.floats[n]), abs(received[n] - packet.floats[n])))
            }
            lastDeviceFrame = Int64(stamp.mSampleTime) + 512
        }
        precondition(maxError < 0.000001, "Actual Program→HAL IOProc→driver input must preserve exact independently tapped PCM")
        let priorCount = probe.values.count
        try await producer.stop()
        precondition(!StreamProgramRenderSnapshot(firstCore.pointer).active && calls.liveCount == 0)
        let retired = render(firstCore, time: time(hostFrame: packets.last!.frame + Int64(STREAM_PROGRAM_DELAY_FRAMES) + 512, deviceFrame: lastDeviceFrame))
        precondition(retired.0 == noErr && retired.1.allSatisfy { $0 == 0 })
        firstCore.receive(packets[0].sample)
        var postStop = [Float](repeating: .nan, count: 1024)
        precondition(postStop.withUnsafeMutableBufferPointer { StudioProgramFixtureRead(Double(lastDeviceFrame + 512), 512, $0.baseAddress) } == noErr)
        precondition(postStop.allSatisfy { $0 == 0 }, "Independent actual driver consumer must receive underrun silence after producer stops")
        try await until { probe.values.count > priorCount }

        // Shared stop barrier: hold the ACTUAL mix actor using its existing
        // admission closure, so both stops await removal while a restart refuses.
        try await producer.start(acknowledgeUnqualifiedHALRoute: true)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let blocker = Task.detached {
            await mixer.addChannel(source, ifCurrent: { entered.signal(); precondition(release.wait(timeout: .now() + 3) == .success); return false })
        }
        let blocked = await Task.detached { waitEntered(entered) }.value
        precondition(blocked)
        let doneA = CompletionFlag(), doneB = CompletionFlag()
        let stopA = Task { try await producer.stop(); doneA.finish() }
        try await until { producer.render.map { !StreamProgramRenderSnapshot($0.pointer).active } == true }
        let stopB = Task { try await producer.stop(); doneB.finish() }
        do { try await producer.start(acknowledgeUnqualifiedHALRoute: true); preconditionFailure("Restart bypassed pending retirement") } catch {}
        try await Task.sleep(for: .milliseconds(10))
        precondition(!doneA.value && !doneB.value)
        release.signal(); await blocker.value
        try await stopA.value; try await stopB.value
        try await producer.start(acknowledgeUnqualifiedHALRoute: true)
        let secondCore = producer.render!
        precondition(secondCore !== firstCore && !StreamProgramRenderSnapshot(firstCore.pointer).active)
        calls.failDestroy = true
        do { try await producer.stop(); preconditionFailure("Failed IO cleanup hidden") } catch {}
        precondition(calls.liveCount == 1 && !StreamProgramRenderSnapshot(secondCore.pointer).active)
        do { try await producer.start(acknowledgeUnqualifiedHALRoute: true); preconditionFailure("Failed IO cleanup lost ownership") } catch {}
        calls.failDestroy = false; try await producer.stop()
        try await producer.start(acknowledgeUnqualifiedHALRoute: true)
        let invalidated = producer.render!
        calls.changed()
        precondition(!StreamProgramRenderSnapshot(invalidated.pointer).active)
        try await until { calls.liveCount == 0 }
        try await producer.stop()
        await mixer.removeTap(oracle); await mixer.stop()

        // Bounded render-core negatives, with explicit controlled HAL time
        // pairs. These do not represent installed/device callback observations.
        let core = try StudioProgramRenderOwner()
        let now = StreamProgramHostFrameAtTicks(mach_absolute_time())
        let old = now - Int64(STREAM_PROGRAM_CAPACITY) + 1024
        let pattern = [Float](repeating: 0.25, count: 1024)
        precondition(pattern.withUnsafeBufferPointer { StreamProgramRenderSubmit(core.pointer, old, 512, $0.baseAddress) })
        precondition(pattern.withUnsafeBufferPointer { StreamProgramRenderSubmit(core.pointer, old + Int64(STREAM_PROGRAM_CAPACITY), 512, $0.baseAddress) })
        let overwritten = render(core, time: time(hostFrame: old + Int64(STREAM_PROGRAM_DELAY_FRAMES), deviceFrame: 0))
        precondition(overwritten.0 == noErr && overwritten.1.allSatisfy { $0 == 0 }, "Ring wrap must never substitute newer samples for the requested timestamp")
        precondition(!pattern.withUnsafeBufferPointer { StreamProgramRenderSubmit(core.pointer, old, 512, $0.baseAddress) })
        let clockFault = render(core, time: time(hostFrame: old + Int64(STREAM_PROGRAM_DELAY_FRAMES) + 515, deviceFrame: 512))
        precondition(clockFault.0 != noErr && clockFault.1.allSatisfy { $0 == 0 } && StreamProgramRenderSnapshot(core.pointer).clockFault)
        let latched = render(core, time: time(hostFrame: old + Int64(STREAM_PROGRAM_DELAY_FRAMES) + 1024, deviceFrame: 1024))
        precondition(latched.1.allSatisfy { $0 == 0 })
        let before = StreamProgramRenderSnapshot(core.pointer).submittedFrames
        core.receive(try sample(pts: CMClockGetTime(CMClockGetHostTimeClock()), rate: 44_100))
        precondition(StreamProgramRenderSnapshot(core.pointer).submittedFrames == before)
        core.retire()
        precondition(!pattern.withUnsafeBufferPointer { StreamProgramRenderSubmit(core.pointer, now, 512, $0.baseAddress) })
        let bounded = try StudioProgramRenderOwner()
        let oversizedFrames = Int(STREAM_PROGRAM_MAX_CALLBACK) + 1
        let oversized = [Float](repeating: 0.25, count: oversizedFrames * 2)
        let ordinaryStart = StreamProgramHostFrameAtTicks(mach_absolute_time()) - Int64(STREAM_PROGRAM_MAX_CALLBACK)
        // This fresh ACTIVE core has no prior timestamp or retired-state reason
        // to refuse; the fully allocated buffer isolates the size admission.
        precondition(!oversized.withUnsafeBufferPointer { StreamProgramRenderSubmit(bounded.pointer, ordinaryStart, UInt32(oversizedFrames), $0.baseAddress) })
        precondition(StreamProgramRenderSnapshot(bounded.pointer).submittedFrames == 0)
        bounded.retire()
        precondition(StudioProgramFixtureConcurrentRender(), "Concurrent ring replacement must return old timestamp's whole stereo pair or silence")
        precondition(StudioProgramFixtureStop(99) == noErr)
        let report: [String: Any] = [
            "evaluationOnly": true, "installedHALQualified": false, "receivingAppQualified": false,
            "sandboxIPCQualified": false, "syscallsOwned": true, "realHALSyscallsExecuted": false,
            "programPacketsCompared": packets.count, "interleavedSamplesCompared": packets.count * 1024,
            "maximumPCMError": maxError, "sampleRate": 48_000, "channels": 2,
            "producerSchedulingDelayFrames": Int(STREAM_PROGRAM_DELAY_FRAMES), "driverInputDelayFrames": 512,
            "schedule": packets.map { ["sourceHostFrame": $0.frame,
                "outputHostFrame": $0.frame + Int64(STREAM_PROGRAM_DELAY_FRAMES),
                "driverOutputFrame": firstDeviceFrame + $0.frame - packets[0].frame] },
            "producerRetired": !StreamProgramRenderSnapshot(firstCore.pointer).active,
            "independentDriverConsumerSilence": postStop.allSatisfy { $0 == 0 },
            "concurrentTimestampStereoWrapPasses": 32,
            "canceledHALStartCleaned": true,
            "sharedStopBarrierPassed": doneA.value && doneB.value, "cleanupRetryPassed": calls.liveCount == 0]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: artifacts.appendingPathComponent("program-producer-report.json"))
        print("PASS: actual AudioMixEngine Program host-clock tap→same production HAL IOProc→actual loaded AudioServerPlugIn PCM, fader/bus gain/mute, explicit256ms scheduling, driver512-frame transfer, independent stop/silence, retired callbacks, bounded wrap/underflow/clock fault, UID/format/approval refusal, shared stop barrier and cleanup retry; max PCM error \(maxError). Syscalls owned; no installed HAL, OS device/rate/default mutation, playback/capture, signing or target-app/sandbox qualification.")
    }
}
