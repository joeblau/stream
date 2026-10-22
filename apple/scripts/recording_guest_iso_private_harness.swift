import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import StreamCore

struct ISOFrameObservation: Codable, Sendable {
    let sequence: Int64
    let pts: Double
    let sourceTime: Double
    let duration: Double
    let available: Bool
    let prepared: Bool
    let pixel: [UInt8]
}
private final class ISOFrameObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ISOFrameObservation] = []
    func append(_ value: ISOFrameObservation) { lock.lock(); values.append(value); lock.unlock() }
    func snapshot() -> [ISOFrameObservation] { lock.lock(); defer { lock.unlock() }; return values }
}
private final class ISOProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var value: IsolatedVideoProgress?
    func update(_ value: IsolatedVideoProgress) { lock.lock(); self.value = value; lock.unlock() }
    func snapshot() -> IsolatedVideoProgress? { lock.lock(); defer { lock.unlock() }; return value }
}

@main enum RecordingGuestISOPrivateHarness {
    static let size = CGSize(width: 1280, height: 720)
    static let interval = CMTime(value: 1, timescale: 30)
    static let origin = CMTime(value: 300_000, timescale: 30)
    struct DirectProof: Codable {
        let frames: [ISOFrameObservation]
        let heldPrivateFrames: Int
        let sourceAllocationsWhilePrivateHeld: Int
        let privateCapacityFailure: Bool
    }
    struct Receipt: Codable {
        let scope: String
        let direct: DirectProof
        let worker: [ISOFrameObservation]
        let decodedPTS: [Double]
        let decodedPixels: [[UInt8]]
        let duration: Double
        let replacementLeaseAvailable: Bool
        let progress: IsolatedVideoProgress
        let sourceCapacity: Int
        let privateCapacity: Int
        let sourceBytes: UInt64
        let privateBytes: UInt64
        let retiredBanksCharged: Bool
    }
    static func pixel(_ buffer: CVPixelBuffer) -> [UInt8] {
        precondition(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let offset = CVPixelBufferGetBytesPerRow(buffer) * (CVPixelBufferGetHeight(buffer) / 2) + (CVPixelBufferGetWidth(buffer) / 2) * 4
        let pointer = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: pointer + offset, count: 4))
    }
    static func pixels(red: Bool) -> CVPixelBuffer {
        var value: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 32, 32, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &value) == kCVReturnSuccess)
        let buffer = value!
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<32 { for x in 0..<32 {
            let at = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
            bytes[at] = 0; bytes[at + 1] = red ? 0 : 255; bytes[at + 2] = red ? 255 : 0; bytes[at + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
    static func red(_ value: [UInt8]) -> Bool { value[2] > 220 && value[1] < 25 && value[0] < 25 }
    static func black(_ value: [UInt8]) -> Bool { value[0] < 25 && value[1] < 25 && value[2] < 25 }
    static func inspect(_ frame: IsolatedVideoRenderedFrame, bank: RawVideoResourceBank,
                        sequence: Int64, pts: CMTime, sourceTime: CMTime) -> ISOFrameObservation {
        precondition(frame.transferFailure == nil)
        guard let sample = frame.sample, let prepared = frame.preparedVideo, let image = sample.imageBuffer else {
            preconditionFailure("Actual factory did not return a prepared private sample")
        }
        precondition(prepared.bank === bank && prepared.sample === sample)
        precondition(sample.presentationTimeStamp == pts && sample.duration == interval && !sample.decodeTimeStamp.isNumeric)
        precondition(CVPixelBufferGetWidth(image) == Int(size.width) && CVPixelBufferGetHeight(image) == Int(size.height))
        // A guest-only ISO has no chat overlay; the closed copy must not invent it.
        precondition(RecordingChatPaint.read(sample).isEmpty)
        return .init(sequence: sequence, pts: pts.seconds, sourceTime: sourceTime.seconds,
                     duration: sample.duration.seconds, available: frame.sourceAvailable, prepared: true, pixel: pixel(image))
    }
    static func direct(_ source: IsolatedVideoSource, delivery: RecordingVideoFrameDelivery,
                       input: CVPixelBuffer) throws -> DirectProof {
        let render = source.makeRenderer()
        var held: [IsolatedVideoRenderedFrame] = []
        var observations: [ISOFrameObservation] = []
        for index in 0..<delivery.privateBank.allocationThreshold {
            let processing: IsolatedVideoProcessing = index % 2 == 0 ? .raw : .processed
            let pts = origin + CMTime(value: Int64(index), timescale: 30)
            let frame = render(size, pts, interval, Int64(index + 1), processing, sourceTime: origin)!
            let observation = inspect(frame, bank: delivery.privateBank, sequence: Int64(index + 1), pts: pts, sourceTime: origin)
            precondition(observation.available && red(observation.pixel), "Actual raw/processed factory pixels changed")
            let from = CVPixelBufferGetIOSurface(input)!.takeUnretainedValue()
            let to = CVPixelBufferGetIOSurface(frame.sample!.imageBuffer!)!.takeUnretainedValue()
            precondition(IOSurfaceGetID(from) != IOSurfaceGetID(to), "Guest source backing escaped to ISO native ingress")
            observations.append(observation); held.append(frame)
        }
        var sourceBuffers: [CVPixelBuffer] = []
        for _ in 0..<delivery.sourceBank.allocationThreshold {
            do { sourceBuffers.append(try delivery.sourceBank.allocatePixelBuffer()) }
            catch RawVideoResourceFailure.capacityOccupied { break }
        }
        precondition(!sourceBuffers.isEmpty, "Private held frames pinned the original source pool")
        let availableSourceBuffers = sourceBuffers.count
        sourceBuffers.removeAll()
        let exhausted = render(size, origin, interval, 99, .raw, sourceTime: origin)!
        guard case .capacity? = exhausted.transferFailure else { preconditionFailure("Opaque private holds did not report private capacity") }
        precondition(exhausted.sample == nil && held.count == delivery.privateBank.allocationThreshold)
        for frame in held { precondition(red(pixel(frame.sample!.imageBuffer!)), "Previously completed private pixels mutated") }
        print("PASS factory: raw/processed prepared private pixels/PTS, held\(held.count), source allocations\(availableSourceBuffers), counted private exhaustion")
        return .init(frames: observations, heldPrivateFrames: held.count,
                     sourceAllocationsWhilePrivateHeld: availableSourceBuffers, privateCapacityFailure: true)
    }
    static func wait(_ predicate: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() { precondition(ContinuousClock.now < deadline, "Owned ISO operation did not complete"); try await Task.sleep(for: .milliseconds(5)) }
    }
    static func main() async throws {
        setbuf(stdout, nil)
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let workspace = UUID(), generation = UUID(), slot = UUID()
        let sourceDomain = StableFrameDomainID(workspace: workspace, kind: .rendererSource, outputID: "owned-guest-iso", plane: .isolated)
        let privateDomain = StableFrameDomainID(workspace: workspace, kind: .isolatedRecording, outputID: "owned-guest-iso", plane: .isolated)
        let resources = try RawVideoResourceCoordinator.shared.reserveBatch([
            .init(domain: sourceDomain, descriptor: .init(width: 1280, height: 720, capacity: 4), sessionGeneration: generation),
            .init(domain: privateDomain, descriptor: .init(width: 1280, height: 720, capacityPolicy:
                .recording(videoCapacity: 6, maxQueuedBytes: 48_000_000, headroom: 2)), sessionGeneration: generation)])
        let sourceBank = resources.bank(for: sourceDomain)!, privateBank = resources.bank(for: privateDomain)!
        let delivery = RecordingVideoFrameDelivery(sourceBank: sourceBank, privateBank: privateBank)
        let store = GuestVideoFrameStore()
        let lease = GuestReceiveLease(slot: slot, peerID: UUID(), negotiation: UUID(), generation: 1)
        let mapping = UUID(), original = pixels(red: true)
        precondition(store.register(lease)); store.allowProgram(true, lease: lease)
        precondition(store.receive(.init(lease: lease, role: .camera, pixels: original, pts: origin, duration: interval,
            mappingGeneration: mapping, clockQuality: .senderReportAligned), arrival: origin))
        let definition = SourceDefinition(name: "Owned guest", payload: .guest(.init(slotID: slot, role: .camera)))
        let source = RecordingVideoSourceFactory.makeGuest(source: definition, lease: lease, frames: store, deliveryProvider: { delivery })!
        let directProof = try direct(source, delivery: delivery, input: original)
        let observed = ISOFrameObservations(), progress = ISOProgress(), timeline = RecordingTimeline()
        let probeSource = IsolatedVideoSource {
            let render = source.makeRenderer()
            return .init { size, pts, duration, sequence, processing, sourceTime in
                guard let frame = render(size, pts, duration, sequence, processing, sourceTime: sourceTime) else { return nil }
                observed.append(inspect(frame, bank: privateBank, sequence: sequence, pts: pts, sourceTime: sourceTime))
                return frame
            }
        }
        let url = folder.appendingPathComponent("owned-guest-iso.mp4")
        let selection = IsolatedVideoSelection(targetID: "owned-guest", name: "Owned guest", processing: .processed, resolution: .hd720, frameRate: 30)
        let worker = IsolatedVideoRecorder(outputURL: url, selection: selection, source: probeSource,
            sessionID: UUID().uuidString, segmentIndex: 1, programFile: "owned-program.mp4", context: .init(),
            budget: .current, timeline: timeline, frameDelivery: delivery, event: progress.update)
        timeline.begin(at: origin)
        for index in 1...6 {
            if index > 1 {
                let pts = origin + CMTime(value: Int64(index - 1), timescale: 30)
                precondition(store.receive(.init(lease: lease, role: .camera, pixels: original, pts: pts, duration: interval,
                    mappingGeneration: mapping, clockQuality: .senderReportAligned), arrival: pts))
            }
            let frontier = origin + CMTime(value: Int64(index), timescale: 30)
            timeline.update(end: frontier, videoPTS: frontier)
            try await wait { observed.snapshot().count == index }
            try await wait { (progress.snapshot()?.videoSamples ?? 0) >= index }
        }
        store.remove(lease)
        let replacement = GuestReceiveLease(slot: slot, peerID: UUID(), negotiation: UUID(), generation: 2)
        precondition(store.register(replacement)); store.allowProgram(true, lease: replacement)
        let replacementPTS = origin + CMTime(value: 6, timescale: 30)
        precondition(store.receive(.init(lease: replacement, role: .camera, pixels: pixels(red: false), pts: replacementPTS, duration: interval,
            mappingGeneration: UUID(), clockQuality: .senderReportAligned), arrival: replacementPTS))
        let replacementAvailable = store.pixels(slot: slot, role: .camera, at: replacementPTS, program: true, requiring: replacement) != nil
        precondition(replacementAvailable && store.pixels(slot: slot, role: .camera, at: replacementPTS, program: true, requiring: lease) == nil)
        for index in 7...12 {
            let frontier = origin + CMTime(value: Int64(index), timescale: 30)
            timeline.update(end: frontier, videoPTS: frontier)
            try await wait { observed.snapshot().count == index }
            try await wait { (progress.snapshot()?.videoSamples ?? 0) >= index }
        }
        let end = origin + CMTime(value: 12, timescale: 30)
        timeline.seal(end: end, videoPTS: end)
        await withCheckedContinuation { continuation in worker.finish { continuation.resume() } }
        let final = progress.snapshot()!
        precondition(final.status == "complete" && final.videoSamples == 12 && final.renderDrops == 0 && final.videoTransfer == nil,
            "Actual ISO writer did not finish every prepared factory frame")
        precondition(final.missingVideoFrames == 6)
        let frames = observed.snapshot()
        precondition(frames.prefix(6).allSatisfy { $0.available && red($0.pixel) } && frames.suffix(6).allSatisfy { !$0.available && black($0.pixel) },
            "Pinned ISO substituted a replacement lease or failed to render black gaps")
        let asset = AVURLAsset(url: url), tracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        precondition(tracks.count == 1 && audioTracks.isEmpty)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); precondition(reader.startReading())
        var decodedPTS: [Double] = [], decodedPixels: [[UInt8]] = []
        while let sample = output.copyNextSampleBuffer() { decodedPTS.append(sample.presentationTimeStamp.seconds); decodedPixels.append(pixel(sample.imageBuffer!)) }
        precondition(reader.status == .completed && decodedPTS.count == 12)
        for index in 0..<12 {
            precondition(abs(decodedPTS[index] - Double(index) / 30) < 0.002)
            precondition(index < 6 ? red(decodedPixels[index]) : black(decodedPixels[index]), "Decoded ISO pixels violate retained lease cutoff")
        }
        let duration = try await asset.load(.duration).seconds
        precondition(abs(duration - 0.4) < 0.002)
        let journal = try JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathExtension("video-isolated.json"))) as! [String: Any]
        let gaps = journal["gaps"] as! [[String: Any]]
        precondition(gaps.count == 1 && gaps[0]["reason"] as? String == "source-unavailable-black")
        precondition(abs((gaps[0]["startSeconds"] as! Double) - 0.2) < 0.002 && abs((gaps[0]["durationSeconds"] as! Double) - 0.2) < 0.002)
        for bank in resources.banks { RawVideoResourceCoordinator.shared.retire(bankID: bank.id) }
        RawVideoResourceCoordinator.shared.rollback(resources); store.retire()
        let entries = RawVideoResourceCoordinator.shared.snapshot().banks
        let charged = resources.banks.allSatisfy { bank in entries.contains { $0.reservation.bankGeneration == bank.id && $0.state == .quarantined } && !bank.isOpen }
        precondition(charged)
        let receipt = Receipt(scope: "Actual guest Factory raw/processed renderer + IsolatedVideoRecorder + native writer/video decoder, owned guest store/leases/BGRA and timeline only. No Receiver/RTC/audio/mixer/capture/device/StudioRuntime/StreamController or performance qualification.",
            direct: directProof, worker: frames, decodedPTS: decodedPTS, decodedPixels: decodedPixels, duration: duration,
            replacementLeaseAvailable: replacementAvailable, progress: final,
            sourceCapacity: sourceBank.allocationThreshold, privateCapacity: privateBank.allocationThreshold,
            sourceBytes: sourceBank.reservation.reservedBytes, privateBytes: privateBank.reservation.reservedBytes,
            retiredBanksCharged: charged)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: folder.appendingPathComponent("observations.json"), options: .atomic)
        print("PASS actual ISO: prepared factory -> worker -> writer, decoded6 old-red +6 black, replacement refused, PTS0...11/30, gap.2...4, charged retirement")
    }
}
