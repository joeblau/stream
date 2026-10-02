import Foundation

public struct StreamPreflightCheck: Equatable, Identifiable, Sendable {
    public enum Status: String, Sendable { case passed, warning, failed, unverified }
    public var id: String
    public var title: String
    public var status: Status
    public var detail: String
    public init(id: String, title: String, status: Status, detail: String) {
        self.id = id; self.title = title; self.status = status; self.detail = detail
    }
}

/// Facts come from the live studio; this pure evaluator is independently testable.
public struct StreamPreflightFacts: Sendable {
    public var permissionIssues: [String] = []
    public var sourceCount = 0
    public var missingSources: [String] = []
    public var unverifiedSources: [String] = []
    public var previewRunning = false
    public var programAudioPeak: Float?
    public var destinationErrors: [String] = []
    public var destinationCount = 0
    public var profileErrors: [String] = []
    public var storageAvailableBytes: Int64?
    public var storageWritable = false
    public var encoderCount = 0
    public var testedEncoderBudget: Int?
    public var requiredUplinkMbps = 0.0
    public var measuredUplinkMbps: Double?
    public init() {}

    public var checks: [StreamPreflightCheck] {
        var checks: [StreamPreflightCheck] = []
        checks.append(.init(id: "permissions", title: "Permissions", status: permissionIssues.isEmpty ? .passed : .failed,
                            detail: permissionIssues.isEmpty ? "Required capture permissions are granted." : permissionIssues.joined(separator: " ")))
        checks.append(.init(id: "sources", title: "Program sources",
                            status: !missingSources.isEmpty ? .failed : sourceCount == 0 ? .warning : !unverifiedSources.isEmpty ? .unverified : previewRunning ? .passed : .unverified,
                            detail: !missingSources.isEmpty ? missingSources.joined(separator: " ") :
                                sourceCount == 0 ? "The program has no visible layers." :
                                !unverifiedSources.isEmpty ? unverifiedSources.joined(separator: " ") :
                                previewRunning ? "\(sourceCount) visible program layers; no reported missing sources." : "Start preview or a local rehearsal to verify source capture."))
        let audible = (programAudioPeak ?? 0) >= 0.001 // -60 dBFS peak, post-fader program bus.
        checks.append(.init(id: "audio", title: "Audible program audio",
                            status: !previewRunning || programAudioPeak == nil ? .unverified : audible ? .passed : .warning,
                            detail: !previewRunning ? "Start preview, speak and play media to check the program mix." :
                                audible ? "Program audio was detected during the last three seconds." : "No audible program audio detected. Check channel mutes, faders and input routing."))
        checks.append(.init(id: "credentials", title: "Destination credentials",
                            status: destinationCount == 0 || !destinationErrors.isEmpty ? .failed : .passed,
                            detail: destinationCount == 0 ? "Enable a destination for public streaming; local rehearsal needs none." :
                                destinationErrors.isEmpty ? "\(destinationCount) enabled destinations have complete, valid local fields. Ingest acceptance is verified only on connection." : destinationErrors.joined(separator: " ")))
        checks.append(.init(id: "profile", title: "Canvas and output profiles", status: profileErrors.isEmpty ? .passed : .failed,
                            detail: profileErrors.isEmpty ? "Program geometry and destination limits are compatible." : profileErrors.joined(separator: " ")))
        let storageStatus: StreamPreflightCheck.Status = !storageWritable ? .failed :
            storageAvailableBytes == nil ? .unverified : storageAvailableBytes! < 1_000_000_000 ? .failed : .passed
        checks.append(.init(id: "storage", title: "Local recording storage", status: storageStatus,
                            detail: !storageWritable ? "The recording folder is unavailable or unwritable." :
                                storageAvailableBytes.map { "\(String(format: "%.1f", Double($0) / 1_000_000_000)) GB free; local recording requires at least 1 GB." } ?? "Free capacity could not be read."))
        checks.append(.init(id: "encoders", title: "Encoder capacity",
                            status: testedEncoderBudget.map { encoderCount > $0 ? .failed : .passed } ?? .unverified,
                            detail: "\(encoderCount) publishing encoders + one if recording. " +
                                (testedEncoderBudget.map { "Your tested publishing budget is \($0)." } ?? "Set a tested session budget after rehearsing this Mac; capacity is not guaranteed by its hardware tier.")))
        checks.append(.init(id: "uplink", title: "Uplink headroom",
                            status: measuredUplinkMbps.map { $0 >= requiredUplinkMbps ? .passed : .failed } ?? .unverified,
                            detail: "Estimated requirement including headroom: \(String(format: "%.1f", requiredUplinkMbps)) Mbps. " +
                                (measuredUplinkMbps.map { "Latest measurement: \(String(format: "%.1f", $0)) Mbps; your ingest route may differ." } ?? "Run the explicit uplink test to measure this connection.")))
        return checks
    }
}
