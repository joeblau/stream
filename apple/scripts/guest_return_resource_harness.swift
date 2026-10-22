import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import StreamCore

@main struct GuestReturnResourceHarness {
    static func sample(width: Int, height: Int, pts: CMTime) throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels) == kCVReturnSuccess)
        let image = pixels!
        precondition(CVPixelBufferLockBaseAddress(image, []) == kCVReturnSuccess)
        let bytes = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(image)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * stride + x * 4
                bytes[offset] = 30; bytes[offset + 1] = 80; bytes[offset + 2] = 180; bytes[offset + 3] = 255
            }
        }
        precondition(CVPixelBufferUnlockBaseAddress(image, []) == kCVReturnSuccess)
        var format: CMVideoFormatDescription?
        precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
            formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        return sample!
    }

    static func main() throws {
        let coordinator = RawVideoResourceCoordinator.shared
        let workspace = UUID(), token = UUID()
        let lease = GuestReceiveLease(slot: UUID(), peerID: UUID(), negotiation: UUID(), generation: 1)
        let plan = try GuestReturnVideoResources.plan(workspace: workspace, outputID: "owned-return", generation: token,
            sourceSize: CGSize(width: 1920, height: 1080), maximumProfile: .high)
        precondition(plan.rasters == [.init(width: 320, height: 180), .init(width: 640, height: 360), .init(width: 1280, height: 720)])
        let portrait = try GuestReturnVideoResources.plan(workspace: workspace, outputID: "portrait", generation: token,
            sourceSize: CGSize(width: 720, height: 1280), maximumProfile: .high)
        precondition(portrait.rasters == [.init(width: 100, height: 180), .init(width: 202, height: 360), .init(width: 404, height: 720)])
        let small = try GuestReturnVideoResources.plan(workspace: workspace, outputID: "small", generation: token,
            sourceSize: CGSize(width: 16, height: 16), maximumProfile: .high)
        precondition(small.rasters == [.init(width: 16, height: 16)] && small.requests.count == 1)
        let low = try GuestReturnVideoResources.plan(workspace: workspace, outputID: "low-only", generation: token,
            sourceSize: CGSize(width: 1920, height: 1080), maximumProfile: .low)
        precondition(low.rasters.count == 1)
        print("PASS exact original no-upscale/even raster geometry, portrait and qualified profile ceiling")

        let receipt = try coordinator.reserveBatch(plan.requests)
        defer { coordinator.rollback(receipt) }
        let resources = try GuestReturnVideoResources(plan: plan, receipt: receipt)
        let encoder = NativeGuestReturnVideoEncoder()
        defer { encoder.close() }
        let origin = CMClockGetTime(CMClockGetHostTimeClock())
        for (index, profile) in NativeGuestReturnVideoProfile.all.enumerated() {
            encoder.setProfile(profile)
            let pts = origin + CMTime(value: Int64(index), timescale: 1)
            let sample = try sample(width: 1920, height: 1080, pts: pts)
            let output = try encoder.encode(.init(lease: lease, token: token, sample: sample, resources: resources))
            precondition(output != nil && Int(output!.sendBytes) > output!.data.count && output!.data.prefix(4) == Data([0, 0, 0, 1]))
            precondition(output!.rtp == UInt32(truncatingIfNeeded: CMTimeConvertScale(pts, timescale: 90_000, method: .roundHalfAwayFromZero).value))
            precondition(encoder.validationDimensions.0 == plan.rasters[index].width && encoder.validationDimensions.1 == plan.rasters[index].height)
            let duplicate = try encoder.encode(.init(lease: lease, token: token, sample: sample, resources: resources))
            precondition(duplicate == nil)
        }
        precondition(encoder.privateCapacityDrops == 0)
        print("PASS actual VT low/balanced/high packets retain original RTP PTS, dimensions and duplicate/cadence rejection")

        let occupiedReceipt = try coordinator.reserveBatch(small.requests)
        let occupied = try GuestReturnVideoResources(plan: small, receipt: occupiedReceipt)
        let held = [try occupied.allocate(small.rasters[0]), try occupied.allocate(small.rasters[0])]
        let rejected = NativeGuestReturnVideoEncoder()
        let tiny = try sample(width: 16, height: 16, pts: origin + CMTime(value: 5, timescale: 1))
        do {
            _ = try rejected.encode(.init(lease: lease, token: token, sample: tiny, resources: occupied))
            preconditionFailure("A full private bank was treated as ordinary cadence or allocated outside its threshold")
        } catch NativeGuestReturnVideoError.privateCapacityOccupied {}
        precondition(rejected.privateCapacityDrops == 1 && !rejected.validationSessionActive)
        coordinator.rollback(occupiedReceipt)
        precondition(!occupiedReceipt.banks[0].isOpen)
        withExtendedLifetime(held) {}
        print("PASS actual capacity2 exhaustion is typed/counted before VT creation; retained pixels remain charged after retirement")

        let direct = NativeGuestReturnVideoEncoder()
        let directOutput = try direct.encode(.init(lease: lease, token: UUID(), sample: tiny))
        precondition(directOutput != nil && direct.validationDimensions.0 == 16 && direct.validationDimensions.1 == 16)
        direct.close()
        print("PASS direct owned encoder callers admit bounded conversion storage before VT and preserve no-upscale output")

        func preparation(_ token: UUID) throws -> GuestReturnFrameDelivery.Preparation {
            let domain = StableFrameDomainID(workspace: workspace, kind: .guestReturn, outputID: "ticket-ingress", plane: .program)
            let source = RawVideoResourceRequest(domain: .init(workspace: workspace, kind: .rendererSource, outputID: "ticket-source", plane: .program),
                descriptor: .init(width: 16, height: 16, capacity: 4), sessionGeneration: token)
            let conversions = try GuestReturnVideoResources.plan(workspace: workspace, outputID: "ticket", generation: token,
                sourceSize: CGSize(width: 16, height: 16), maximumProfile: .high)
            let receipt = try coordinator.reserveBatch([source, .init(domain: domain,
                descriptor: .init(width: 16, height: 16, capacity: 5), sessionGeneration: token)] + conversions.requests)
            let resources = try GuestReturnVideoResources(plan: conversions, receipt: receipt)
            let sourceReceipt = try receipt.selecting(domain: source.domain)
            return .init(token: token, generation: token, domain: domain, receipt: receipt,
                sourceReceipt: sourceReceipt, bank: receipt.bank(for: domain)!, resources: resources)
        }
        let gate = GuestReturnFrameDelivery()
        let first = try preparation(UUID())
        precondition(gate.isVacant && gate.begin(first) && !gate.isVacant && !gate.begin(first))
        precondition(gate.remove(token: first.token) === first && first.cancellation.isCancelled)
        let next = try preparation(UUID())
        precondition(gate.begin(next))
        let staleACK = FrameDeliveryLease(token: first.token, domain: first.domain, generation: first.generation, bankID: first.bank.id)
        precondition(!gate.adopt(staleACK, preparation: first) && gate.resources(for: next.token) === next.resources)
        precondition(gate.remove(token: first.token) == nil && next.bank.isOpen)
        coordinator.rollback(first.receipt); coordinator.rollback(first.sourceReceipt)
        precondition(next.bank.isOpen && !next.cancellation.isCancelled)
        _ = gate.remove(token: next.token)
        coordinator.rollback(next.receipt); coordinator.rollback(next.sourceReceipt)
        print("PASS pending cancellation/duplicate rejection/new preparation/stale ACK preserve exact replacement resources")
    }
}
