import CoreMedia
import Foundation

// Command-state boundary only. The shipping session/transport/protocol/capture
// sources compile unchanged; these inert mixer methods cannot capture or emit PCM.
enum AudioChannelID: Hashable, Sendable { case application(bundleID:String) }
actor AudioMixEngine {
    nonisolated func setCaptureRouteAllowed(_ id: AudioChannelID,allowed: Bool) {}
    nonisolated func enqueue(_ id: AudioChannelID,_ sample: CMSampleBuffer) { preconditionFailure("No PCM in command fixture") }
    func reserveCaptureHoldback(token: UUID,milliseconds: Double) -> Bool { preconditionFailure("No capture in command fixture") }
    func releaseCaptureHoldback(_ token: UUID) { preconditionFailure("No capture in command fixture") }
    func resetCaptureRouteHistory(_ id: AudioChannelID) {}
    func removeChannel(_ id: AudioChannelID) {}
}
enum BrowserOverlayLoadState: Equatable, Sendable { case loading,ready,failed(String) }
@main private struct BrowserHelperCommandFixture {
    @MainActor static func main() async throws { try await BrowserHelperLifecycleChecks.run() }
}
