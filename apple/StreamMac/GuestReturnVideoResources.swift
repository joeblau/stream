import CoreGraphics
import CoreVideo
import Foundation
import StreamCore

/// The return encoder's actual conversion pools, admitted before its native
/// codec is created. These banks contain only independently backed pixels.
final class GuestReturnVideoResources: @unchecked Sendable {
    struct Raster: Hashable, Sendable {
        let width: Int
        let height: Int
    }
    struct Plan: Sendable {
        let requests: [RawVideoResourceRequest]
        let rasters: [Raster]
    }
    private let banks: [Raster: RawVideoResourceBank]

    static func raster(sourceWidth: Int, sourceHeight: Int,
                       profile: NativeGuestReturnVideoProfile) throws -> Raster {
        guard sourceWidth >= 2, sourceHeight >= 2,
              sourceWidth <= 8192, sourceHeight <= 8192 else {
            throw RawVideoResourceFailure.invalidRequest
        }
        let scale = min(1, min(Double(profile.width) / Double(sourceWidth),
                               Double(profile.height) / Double(sourceHeight)))
        return Raster(width: max(2, Int(Double(sourceWidth) * scale) / 2 * 2),
                      height: max(2, Int(Double(sourceHeight) * scale) / 2 * 2))
    }

    static func plan(workspace: UUID, outputID: String, generation: UUID,
                     sourceSize: CGSize, maximumProfile: NativeGuestReturnVideoProfile) throws -> Plan {
        guard sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width >= 2, sourceSize.height >= 2,
              sourceSize.width <= 8192, sourceSize.height <= 8192 else {
            throw RawVideoResourceFailure.invalidRequest
        }
        var rasters: [Raster] = []
        for profile in NativeGuestReturnVideoProfile.all where profile.width <= maximumProfile.width
            && profile.height <= maximumProfile.height {
            let raster = try raster(sourceWidth: Int(sourceSize.width), sourceHeight: Int(sourceSize.height), profile: profile)
            if !rasters.contains(raster) { rasters.append(raster) }
        }
        guard !rasters.isEmpty else { throw RawVideoResourceFailure.invalidRequest }
        let requests = rasters.map { raster in
            RawVideoResourceRequest(domain: .init(workspace: workspace, kind: .guestReturn,
                outputID: "\(outputID)-encode-\(raster.width)x\(raster.height)", plane: .isolated),
                descriptor: .init(width: raster.width, height: raster.height, capacity: 2),
                sessionGeneration: generation)
        }
        return Plan(requests: requests, rasters: rasters)
    }

    init(plan: Plan, receipt: RawVideoResourceReceipt) throws {
        var banks: [Raster: RawVideoResourceBank] = [:]
        for (raster, request) in zip(plan.rasters, plan.requests) {
            guard let bank = receipt.bank(for: request.domain), bank.reservation.request == request,
                  bank.isOpen else { throw RawVideoResourceFailure.unknownReservation }
            banks[raster] = bank
        }
        self.banks = banks
    }

    func allocate(_ raster: Raster) throws -> CVPixelBuffer {
        guard let bank = banks[raster] else { throw RawVideoResourceFailure.invalidRequest }
        return try bank.allocatePixelBuffer()
    }
}
