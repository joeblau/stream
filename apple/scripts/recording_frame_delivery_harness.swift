import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import StreamCore

private final class AcceptedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [RecordingChatFrame] = []
    func append(_ frame: RecordingChatFrame) { lock.lock(); frames.append(frame); lock.unlock() }
    func snapshot() -> [RecordingChatFrame] { lock.lock(); defer { lock.unlock() }; return frames }
}

@main struct RecordingFrameDeliveryHarness {
    static func main() async throws {
        setbuf(stdout, nil)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await rawIsolation(directory)
        try await firstFramePin(directory)
        try await capacityAndProvenance(directory)
        try await routerRotation(directory)
        try await canceledBoundaryBeforeFinish(directory)
        print("PASS: actual recorder private ingress, original queue pin/drop semantics, decoded media, fresh bank provenance and delayed-finish cancellation")
    }

    private static func video(_ index: Int, width: Int = 320, height: Int = 180,
                              bright: UInt8 = 0, base: Double = 10_000, dts: CMTime = .invalid) throws -> CMSampleBuffer {
        var image: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &image) == kCVReturnSuccess,
            let image else { throw CocoaError(.fileWriteUnknown) }
        fill(image, bright)
        var description: CMVideoFormatDescription?
        precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &description) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: base, preferredTimescale: 48_000) + CMTime(value: Int64(index), timescale: 30), decodeTimeStamp: dts)
        var sample: CMSampleBuffer?
        precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
            formatDescription: description!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        return sample!
    }
    private static func fill(_ image: CVPixelBuffer, _ bright: UInt8) {
        precondition(CVPixelBufferLockBaseAddress(image, []) == kCVReturnSuccess)
        let row = CVPixelBufferGetBytesPerRow(image)
        let bytes = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<CVPixelBufferGetHeight(image) {
            for x in 0..<CVPixelBufferGetWidth(image) {
                let at = y * row + x * 4
                bytes[at] = bright; bytes[at + 1] = bright; bytes[at + 2] = bright; bytes[at + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(image, [])
    }
    private static func audio(frames: Int) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
            mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        precondition(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr)
        var block: CMBlockBuffer?
        precondition(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frames * 8,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: frames * 8, flags: 0, blockBufferOut: &block) == noErr)
        precondition(CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: frames * 8) == noErr)
        var sample: CMSampleBuffer?
        precondition(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: description!,
            sampleCount: frames, presentationTimeStamp: CMTime(value: 480_000_000, timescale: 48_000), packetDescriptions: nil, sampleBufferOut: &sample) == noErr)
        return sample!
    }
    private static func finish(_ session: ProgramRecordingSession, waiting: Bool = false) async -> ProgramRecordingSession.Result {
        await withCheckedContinuation { continuation in session.finish(waitingForSourceBoundary: waiting) { continuation.resume(returning: $0) } }
    }
    private static func bank(capacity: Int = 30, width: Int = 320, height: Int = 180) throws -> (RawVideoResourceBank, RawVideoResourceReceipt) {
        let generation = UUID()
        let receipt = try RawVideoResourceCoordinator.shared.reserveBatch([.init(domain:
            .init(workspace: generation, kind: .recording, outputID: "owned-recorder-validation", plane: .program),
            descriptor: .init(width: width, height: height, capacityPolicy:
                .recording(videoCapacity: capacity, maxQueuedBytes: 128_000_000, headroom: 5)), sessionGeneration: generation)])
        return (receipt.banks[0], receipt)
    }
    private static func decode(_ url: URL) async throws -> [(Double, UInt8)] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        precondition(tracks.count == 1)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); precondition(reader.startReading())
        var values: [(Double, UInt8)] = []
        while let sample = output.copyNextSampleBuffer(), let image = sample.imageBuffer {
            precondition(CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess)
            let byte = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)[CVPixelBufferGetBytesPerRow(image) * (CVPixelBufferGetHeight(image) / 2) + (CVPixelBufferGetWidth(image) / 2) * 4]
            values.append((sample.presentationTimeStamp.seconds, byte))
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
        }
        precondition(reader.status == .completed, reader.error?.localizedDescription ?? "Owned video decode failed")
        return values
    }

    private static func rawIsolation(_ directory: URL) async throws {
        let accepted = AcceptedFrames()
        var configuration = ProgramRecordingSession.Configuration(); configuration.requiresAudio = false
        configuration.onVideoAccepted = accepted.append
        let url = directory.appendingPathComponent("raw-source-mutation.mp4")
        let session = ProgramRecordingSession(outputURL: url, configuration: configuration)
        for index in 0..<24 {
            let bright: UInt8 = index % 6 < 3 ? 0 : 255
            let sample = try video(index, bright: bright)
            RecordingChatPaint.attach([.init(slotID: "owned-slot", messageID: "owned-\(index)", fingerprint: RecordingChatPaint.fingerprint("owned-\(index)"))], to: sample)
            session.appendVideo(sample)
            // The source may be legally reused immediately after synchronous
            // append returns. Encoder input must already be independently backed.
            fill(sample.imageBuffer!, 255 - bright)
            try await Task.sleep(for: .milliseconds(15))
        }
        let result = await finish(session)
        precondition(result.completed, result.error ?? "Raw-copy recording failed")
        precondition(result.progress.videoSamples == 24 && result.progress.droppedVideo == 0)
        precondition(result.progress.videoTransfer == nil)
        let values = try await decode(url)
        precondition(values.count == 24)
        for (index, value) in values.enumerated() {
            precondition(abs(value.0 - Double(index) / 30) < 0.002)
            precondition(index % 6 < 3 ? value.1 < 25 : value.1 > 230, "Native writer retained mutable source pixels")
        }
        precondition(accepted.snapshot().count == 24 && accepted.snapshot().allSatisfy { $0.painted.count == 1 }, "ShouldNotPropagate paint was lost at raw copy")
        print("PASS raw: 24 decoded original pixels/PTS after source mutation; 24 typed paint receipts")
    }

    private static func firstFramePin(_ directory: URL) async throws {
        let url = directory.appendingPathComponent("first-frame-pin-1080.mp4")
        let session = ProgramRecordingSession(outputURL: url)
        let start = ContinuousClock.now
        for index in 0..<40 { session.appendVideo(try video(index, width: 1920, height: 1080)) }
        // Audio intentionally withholds native configuration. This explicit
        // guard refuses to call a slow-host race a deterministic queue proof.
        precondition(start.duration(to: .now) < .milliseconds(750), "Owned first-pin burst exceeded preconfiguration window")
        session.appendAudio(try audio(frames: 64_000))
        let result = await finish(session)
        precondition(result.completed, result.error ?? "First-pin recording failed")
        precondition(result.progress.sessionStartSourceSeconds == 10_000)
        precondition(result.progress.videoSamples == 15 && result.progress.droppedVideo == 25,
                     "Original decimal128M/Q30 1080p queue and first-pin policy changed")
        let values = try await decode(url)
        precondition(values.count == 15 && abs(values[0].0) < 0.002 && abs(values.last!.0 - 1.3) < 0.002)
        print("PASS queue: actual1080p Q15, first origin pinned, 25 queue drops, 15 decoded frames")
    }

    private static func capacityAndProvenance(_ directory: URL) async throws {
        let (heldBank, heldReceipt) = try bank(capacity: 3)
        let (newBank, newReceipt) = try bank(capacity: 3)
        let source = try video(0)
        let timed = try video(0, dts: CMTime(value: 599_999, timescale: 60))
        let timingCopy = try FrameDeliveryConverter.copy(source: timed, into: newBank)
        precondition(timingCopy.presentationTimeStamp == timed.presentationTimeStamp && timingCopy.decodeTimeStamp == timed.decodeTimeStamp && timingCopy.duration == timed.duration)
        let paint = RecordingChatPaint(slotID: "owned", messageID: "metadata", fingerprint: RecordingChatPaint.fingerprint("metadata"))
        RecordingChatPaint.attach([paint], to: source)
        var held: [CMSampleBuffer] = []
        for _ in 0..<heldBank.allocationThreshold { held.append(try FrameDeliveryConverter.copy(source: source, into: heldBank)) }
        precondition(held.count == 8)
        precondition(held[0].presentationTimeStamp == source.presentationTimeStamp && held[0].decodeTimeStamp == source.decodeTimeStamp && held[0].duration == source.duration)
        precondition(RecordingChatPaint.read(held[0]) == [paint])
        var config = ProgramRecordingSession.Configuration(); config.requiresAudio = false; config.videoCapacity = 3; config.videoBank = heldBank
        let saturated = ProgramRecordingSession(outputURL: directory.appendingPathComponent("private-capacity.mp4"), configuration: config)
        saturated.appendVideo(source)
        let broker = FrameDeliveryBroker()
        let cancellation = FrameDeliveryCancellation()
        let lease = try broker.install(token: UUID(), domain: heldBank.reservation.request.domain,
            generation: heldBank.reservation.request.sessionGeneration, bank: heldBank,
            cancellation: cancellation, sink: { _ in preconditionFailure("Occupied bank delivered an unaccounted pixel") })
        for index in 0..<4 {
            let input = try video(index)
            broker.offer(.init(sampleBuffer: input, presentationTime: input.presentationTimeStamp,
                               frameDuration: input.duration, sequence: Int64(index + 1)))
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while broker.statistics(for: lease).privateCapacityDrops < index + 1 {
                precondition(ContinuousClock.now < deadline, "Actual private transfer did not finish before owned deadline")
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        cancellation.cancel()
        let finalStatistics = broker.remove(lease)
        precondition(finalStatistics.privateCapacityDrops == 4 && finalStatistics.drops == 4)
        saturated.updateVideoDelivery(.init(finalStatistics))
        // An already completed exact-bank packet remains valid for final
        // writer drain after the allocator has closed. No new pixel escapes.
        saturated.appendPreparedVideo(.init(sample: held[0], bank: heldBank))
        let capacityResult = await finish(saturated)
        precondition(capacityResult.completed && capacityResult.progress.videoSamples == 1)
        precondition(capacityResult.progress.droppedVideo == 0 && capacityResult.progress.videoTransfer?.privateCapacityDrops == 5)
        precondition(capacityResult.progress.videoTransfer?.broker == finalStatistics)
        let terminalJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: capacityResult.url.appendingPathExtension("recording.json"))) as! [String: Any]
        let terminalProgress = terminalJSON["progress"] as! [String: Any]
        let terminalTransfer = terminalProgress["videoTransfer"] as! [String: Any]
        precondition((terminalTransfer["broker"] as! [String: Any])["privateCapacityDrops"] as? Int == 4)
        let terminalFrames = try await decode(capacityResult.url); precondition(terminalFrames.count == 1)
        config.videoBank = newBank
        let fresh = ProgramRecordingSession(outputURL: directory.appendingPathComponent("fresh-bank.mp4"), configuration: config)
        fresh.appendPreparedVideo(.init(sample: held[0], bank: heldBank))
        let copied = try FrameDeliveryConverter.copy(source: try video(0), into: newBank)
        fresh.appendPreparedVideo(.init(sample: copied, bank: newBank))
        let freshResult = await finish(fresh)
        precondition(freshResult.completed && freshResult.progress.videoSamples == 1 && freshResult.progress.droppedVideo == 0)
        precondition(freshResult.progress.videoTransfer?.provenanceDrops == 1)
        let oldSurface = CVPixelBufferGetIOSurface(held[0].imageBuffer!)!.takeUnretainedValue()
        let freshSurface = CVPixelBufferGetIOSurface(copied.imageBuffer!)!.takeUnretainedValue()
        precondition(IOSurfaceGetID(oldSurface) != IOSurfaceGetID(freshSurface))
        let oldCost = heldBank.reservation.reservedBytes
        RawVideoResourceCoordinator.shared.retire(bankID: heldBank.id)
        RawVideoResourceCoordinator.shared.rollback(heldReceipt)
        precondition(RawVideoResourceCoordinator.shared.snapshot().committedBytes >= oldCost + newBank.reservation.reservedBytes)
        let invalid = ProgramRecordingSession(outputURL: directory.appendingPathComponent("invalid-admission.mp4"))
        invalid.appendVideo(try video(0, width: 6_000, height: 1))
        let invalidResult = await finish(invalid)
        precondition(invalidResult.progress.videoTransfer?.admissionFailures == 1 && invalidResult.progress.videoTransfer?.conversionFailures == 0)
        let timestampRejected = ProgramRecordingSession(outputURL: directory.appendingPathComponent("invalid-timestamp.mp4"))
        var badTiming = CMSampleTimingInfo(duration: source.duration, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        var invalidPTS: CMSampleBuffer?
        precondition(CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: source, sampleTimingEntryCount: 1,
            sampleTimingArray: &badTiming, sampleBufferOut: &invalidPTS) == noErr)
        timestampRejected.appendVideo(invalidPTS!)
        let timestampResult = await finish(timestampRejected)
        precondition(timestampResult.progress.droppedVideo == 1 && timestampResult.progress.videoTransfer == nil,
                     "Original invalid-PTS inlet drop was reclassified as transfer failure")
        RawVideoResourceCoordinator.shared.retire(bankID: newBank.id); RawVideoResourceCoordinator.shared.rollback(newReceipt)
        withExtendedLifetime(held) {}
        print("PASS capacity: exact finitebank occupancy, actual broker4 failure receipt retained in final writer journal + decoded1; fresh surface/old charge; admission/capacity/provenance/invalidPTS counters remain distinct")
    }

    private static func routerRotation(_ directory: URL) async throws {
        let (oldBank, oldReceipt) = try bank(); let (newBank, newReceipt) = try bank()
        var config = ProgramRecordingSession.Configuration(); config.requiresAudio = false; config.videoBank = oldBank
        let old = ProgramRecordingSession(outputURL: directory.appendingPathComponent("rotation-old.mp4"), configuration: config)
        config.videoBank = newBank
        let next = ProgramRecordingSession(outputURL: directory.appendingPathComponent("rotation-next.mp4"), configuration: config)
        let router = ProgramRecordingRouter(); let delivery = RecordingProgramFrameDelivery(router: router)
        delivery.activate(bank: oldBank, session: old)
        for index in 0..<6 { delivery.receive(try FrameDeliveryConverter.copy(source: video(index), into: oldBank), bank: oldBank) }
        delivery.activate(bank: newBank, session: next, finishing: old)
        delivery.receive(try FrameDeliveryConverter.copy(source: video(1), into: oldBank), bank: oldBank)
        delivery.receive(try FrameDeliveryConverter.copy(source: video(6), into: newBank), bank: newBank)
        let previousResult = await finish(old, waiting: true)
        delivery.stop(next)
        let nextResult = await finish(next)
        precondition(previousResult.completed && previousResult.progress.videoSamples == 6)
        precondition(nextResult.completed && nextResult.progress.videoSamples == 1 && nextResult.progress.videoTransfer == nil)
        precondition(abs(nextResult.progress.sessionStartSourceSeconds! - (10_000 + 0.2)) < 0.0001)
        let oldValues = try await decode(previousResult.url), newValues = try await decode(nextResult.url)
        precondition(oldValues.count == 6 && newValues.count == 1)
        for (bank, receipt) in [(oldBank, oldReceipt), (newBank, newReceipt)] {
            RawVideoResourceCoordinator.shared.retire(bankID: bank.id); RawVideoResourceCoordinator.shared.rollback(receipt)
        }
        print("PASS rotation: actual router rejects late old-bank callback; old6/new1 decoded files retain exact source boundary")
    }
    private static func canceledBoundaryBeforeFinish(_ directory: URL) async throws {
        var config = ProgramRecordingSession.Configuration(); config.requiresAudio = false
        let session = ProgramRecordingSession(outputURL: directory.appendingPathComponent("stop-before-finish-ack.mp4"), configuration: config)
        for index in 0..<6 { session.appendVideo(try video(index)) }
        session.cancelPendingFinishBoundary()
        let result = await finish(session, waiting: true)
        precondition(result.completed && result.progress.videoSamples == 6, result.error ?? "Earlier Stop intent was lost before delayed finish")
        let values = try await decode(result.url); precondition(values.count == 6)
        print("PASS terminal: Stop boundary cancellation queued before delayed finish cannot await a nonexistent next frame")
    }
}
