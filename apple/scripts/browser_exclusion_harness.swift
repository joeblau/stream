import Foundation
import AVFoundation
import CoreMedia

@MainActor private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = false
    func wait() async { entered = true; let waiters = enteredWaiters; enteredWaiters = []; for waiter in waiters { waiter.resume() }; await withCheckedContinuation { continuation = $0 } }
    func untilEntered() async { if !entered { await withCheckedContinuation { enteredWaiters.append($0) } } }
    func release() { let waiter = continuation; continuation = nil; waiter?.resume() }
}
private final class Event: @unchecked Sendable {
    private let lock = NSLock(); private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() {
        lock.lock(); fired = true; let pending = waiters; waiters = []; lock.unlock()
        for waiter in pending { waiter.resume() }
    }
    func wait() async {
        await withCheckedContinuation { waiter in
            lock.lock()
            if fired { lock.unlock(); waiter.resume() }
            else { waiters.append(waiter); lock.unlock() }
        }
    }
}
private final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var stored = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
    func add() { lock.lock(); stored += 1; lock.unlock() }
}
private struct SampleBox: @unchecked Sendable { let value: CMSampleBuffer }
@main private struct BrowserExclusionHarness {
    @MainActor static func main() async throws {
        let boundaries = CaptureAudioBoundaryOwners(), firstOwner = UUID(), secondOwner = UUID()
        let old = UUID(), current = UUID(), second = UUID()
        boundaries.close(owner: firstOwner, revision: old); boundaries.close(owner: firstOwner, revision: current)
        boundaries.close(owner: secondOwner, revision: second)
        boundaries.release(owner: firstOwner, revision: old)
        precondition(boundaries.revision(for: firstOwner) == current)
        boundaries.release(owner: firstOwner, revision: current); precondition(!boundaries.isEmpty)
        boundaries.release(owner: secondOwner, revision: second); precondition(boundaries.isEmpty)
        let retiredOwner = BrowserCaptureExclusionOwner()
        _ = retiredOwner.beginInstallation(helperPID: 42); retiredOwner.publish(.failed)
        precondition(retiredOwner.needsFreshHelper(43) && !retiredOwner.needsFreshHelper(42))
        _ = retiredOwner.beginRetirement(); retiredOwner.publish(.failed)
        precondition(!retiredOwner.needsFreshHelper(43), "New helper skipped failed old stream cleanup")
        let delivery = CaptureAudioDeliveryGate(), oldDelivery = delivery.token!
        delivery.setOpen(false); delivery.setOpen(true)
        precondition(!delivery.accepts(oldDelivery) && delivery.accepts(delivery.token!))
        // The production transaction, not a duplicate scheduler, holds each external boundary.
        do {
            let owner = BrowserCaptureExclusionOwner(), install = Gate(), drain = Gate()
            let revision = owner.publish(.pending)
            var opened = false
            let work = Task { await owner.finishInstallation(revision: revision, helperPID: 42,
                install: { await install.wait(); return true }, drain: { await drain.wait() },
                current: { true }, reopen: { opened = true }) }
            await install.untilEntered()
            precondition(!opened && !owner.accepts(helperPID: 42, demanded: true))
            install.release(); await drain.untilEntered()
            precondition(!opened && !owner.accepts(helperPID: 42, demanded: true), "Install ACK skipped the old input/history drain")
            drain.release(); await work.value
            precondition(opened && owner.accepts(helperPID: 42, demanded: true) && !owner.accepts(helperPID: 43, demanded: true))
            let epoch = UUID(); var currentEpoch = epoch
            let permit = BrowserCaptureExclusionPermit(id: epoch, helperPID: 42, isCurrent: { currentEpoch == epoch && owner.accepts(helperPID: 42, demanded: true) })
            precondition(permit.allows(42) && !permit.allows(43)); currentEpoch = UUID(); precondition(!permit.allows(42))
        }
        // Same production owner, close/release callbacks and start occupancy as
        // a rapid retire -> re-demand while the old SCStream start is held.
        do {
            let owner = BrowserCaptureExclusionOwner(), boundaries = CaptureAudioBoundaryOwners()
            let starts = CaptureAudioPendingStarts(), starting = starts.begin(), stopEntered = Event()
            let oldDrain = Gate(); var generation = UUID(), stopCalls = 0
            owner.changed = {
                if owner.state == .stopped, let token = boundaries.revision(for: owner.id) {
                    boundaries.release(owner: owner.id, revision: token)
                }
            }
            let oldGeneration = generation, oldRevision = owner.beginRetirement()
            boundaries.close(owner: owner.id, revision: oldRevision)
            let first = Task {
                await starts.waitUntilDrained()
                return await owner.finishRetirement(revision: oldRevision, stop: {
                    stopCalls += 1; stopEntered.signal(); return true
                }, drain: { await oldDrain.wait() }, current: { generation == oldGeneration })
            }
            // Re-demand publishes pending, then its actual start owns a fresh
            // retirement boundary even though the old stream field is nil.
            generation = UUID(); owner.publish(.pending)
            let currentGeneration = generation, nextRevision = owner.beginRetirement()
            boundaries.close(owner: owner.id, revision: nextRevision)
            let second = Task {
                _ = await first.value
                return await owner.finishRetirement(revision: nextRevision,
                    stop: { true }, drain: {}, current: { generation == currentGeneration })
            }
            precondition(stopCalls == 0 && !boundaries.isEmpty)
            // Late successful start releases occupancy only: retirement is the
            // single stop owner; the counter below requires exactly one Stop.
            starts.finish(starting); await stopEntered.wait(); await oldDrain.untilEntered()
            precondition(stopCalls == 1 && boundaries.revision(for: owner.id) == nextRevision)
            oldDrain.release(); _ = await first.value; _ = await second.value
            precondition(stopCalls == 1 && boundaries.isEmpty && owner.state == .stopped,
                         "Rapid same-owner re-demand lost its release or stopped twice")
        }
        for retired in [false, true] {
            let owner = BrowserCaptureExclusionOwner(), held = Gate()
            let revision = owner.publish(.pending); var opened = false, drained = false
            let work = Task { await owner.finishInstallation(revision: revision, helperPID: 42,
                install: { await held.wait(); return true }, drain: { drained = true },
                current: { true }, reopen: { opened = true }) }
            await held.untilEntered()
            owner.publish(retired ? .stopped : .pending) // newer stop/reconfigure wins
            held.release(); await work.value
            precondition(!opened && !drained && owner.state == (retired ? .stopped : .pending))
        }
        do {
            let owner = BrowserCaptureExclusionOwner(), stop = Gate(), history = Gate()
            let revision = owner.publish(.pending)
            let work = Task { await owner.finishRetirement(revision: revision,
                stop: { await stop.wait(); return true }, drain: { await history.wait() }, current: { true }) }
            await stop.untilEntered(); precondition(!owner.accepts(helperPID: 42, demanded: false))
            stop.release(); await history.untilEntered(); precondition(owner.state == .pending)
            history.release(); let retired = await work.value; precondition(retired); precondition(owner.accepts(helperPID: 42, demanded: false))
            let failed = owner.publish(.pending)
            let result = await owner.finishRetirement(revision: failed, stop: { false }, drain: {}, current: { true })
            precondition(!result && owner.state == .failed && !owner.accepts(helperPID: 42, demanded: false))
            let recovered = owner.publish(.pending)
            await owner.finishInstallation(revision: recovered, helperPID: 43, install: { true }, drain: {}, current: { true }, reopen: {})
            precondition(owner.accepts(helperPID: 43, demanded: true))
            enum InstallFailure: Error { case refused }
            let failedInstall = owner.publish(.pending)
            var drained = false
            await owner.finishInstallation(revision: failedInstall, helperPID: 43,
                install: { throw InstallFailure.refused }, drain: { drained = true }, current: { true }, reopen: {})
            precondition(drained && owner.state == .failed && !owner.accepts(helperPID: 43, demanded: true))
        }
        try await actualMixerDrain()
        print("PASS: production exclusion transactions hold install/retirement/input/history boundaries; reject old PID/demand/owner generations and failed cleanup; valid new generation recovers. Actual mixer PCM/reset and serial entered callback drain preserve unrelated channel. No SCK/helper/device/mixer-clock/UI/runtime qualification.")
    }
    static func sample(_ pts: CMTime) -> CMSampleBuffer {
        let frames = 512, values = [Float](repeating: 0.3, count: 1024)
        var format: CMAudioFormatDescription?, block: CMBlockBuffer?, sample: CMSampleBuffer?
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        precondition(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr)
        precondition(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: 4096, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: 4096, flags: 0, blockBufferOut: &block) == noErr)
        precondition(values.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: $0.count) } == noErr)
        precondition(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sample) == noErr)
        return sample!
    }
    @MainActor static func actualMixerDrain() async throws {
        let mixer = AudioMixEngine(), owner = BrowserCaptureExclusionOwner()
        let broad = AudioChannelID.application(bundleID: "owned.broad"), unrelated = AudioChannelID.application(bundleID: "owned.other")
        await mixer.setChannelGain(broad, volume: 0.5, isMuted: false)
        await mixer.setChannelGain(unrelated, volume: 1, isMuted: false)
        let inputEntered = Event(), inputCount = Flag(), inputReleased = DispatchSemaphore(value: 0), reset = Flag(), unrelatedReset = Flag()
        await mixer.addChannel(broad, resetInsert: { reset.add() }, insert: { sample in
            inputCount.add()
            if inputCount.value == 1 { inputEntered.signal(); precondition(inputReleased.wait(timeout: .now() + 10) == .success) }
            return sample
        })
        await mixer.addChannel(unrelated, resetInsert: { unrelatedReset.add() })
        mixer.enqueue(unrelated, sample(CMClockGetTime(CMClockGetHostTimeClock())))
        let queue = DispatchQueue(label: "owned.capture.serial-callback"), delivered = CaptureAudioDeliveryGate()
        let buffer = SampleBox(value: sample(CMClockGetTime(CMClockGetHostTimeClock())))
        // Real entered mixer insert on the capture's serial callback queue.
        queue.async { if delivered.isOpen { mixer.enqueue(broad, buffer.value) } }
        await inputEntered.wait()
        delivered.setOpen(false); mixer.setCaptureRouteAllowed(broad, allowed: false)
        let revision = owner.publish(.pending), historyEntered = Flag(), drainEntered = Event()
        var opened = false
        let work = Task { await owner.finishInstallation(revision: revision, helperPID: 42,
            install: { true }, drain: {
                drainEntered.signal()
                await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
                historyEntered.add(); await mixer.resetCaptureRouteHistory(broad)
            }, current: { true }, reopen: { opened = true; mixer.setCaptureRouteAllowed(broad, allowed: true) }) }
        await drainEntered.wait()
        precondition(!opened && historyEntered.value == 0 && reset.value == 0, "Entered old callback was not drained")
        inputReleased.signal(); await work.value
        let retiredPCM = await mixer.exclusionFixtureProgram(broad)
        let unrelatedPCM = await mixer.exclusionFixtureProgram(unrelated)
        precondition(opened && reset.value == 1 && unrelatedReset.value == 0)
        precondition(retiredPCM.allSatisfy { $0 == 0 } && unrelatedPCM.allSatisfy { abs($0 - 0.3) < 0.00001 },
                     "Owned history reset retained old PCM or cleared unrelated audio")
        // The explicit empty read above consumed its synthetic window. A second
        // real history boundary creates a fresh ring; no autonomous mixer clock
        // or invented future capture timestamps are needed for this gain check.
        await mixer.resetCaptureRouteHistory(broad)
        mixer.enqueue(broad, sample(CMClockGetTime(CMClockGetHostTimeClock())))
        let freshPCM = await mixer.exclusionFixtureProgram(broad)
        precondition(freshPCM.allSatisfy { abs($0 - 0.15) < 0.00001 }, "History reset changed the saved channel gain or refused fresh original-clock PCM")
    }
}
