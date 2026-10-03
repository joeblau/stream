import AVFoundation
import CoreMedia
import Foundation

/// Immutable, application-owned decoded media receipts. They do not register
/// a source or authorize routing. Playout selects frames due at original host PTS.
struct GuestReceiveLease: Sendable, Equatable {
    let slot: UUID
    let peerID: UUID
    let negotiation: UUID
    let generation: UInt64
}
enum GuestReceiveRole: Int32, Sendable { case camera = 0, screen = 1, audio = 2 }
enum GuestClockQuality: Sendable { case senderReportAligned }
struct GuestVideoFrame: @unchecked Sendable {
    let lease: GuestReceiveLease, role: GuestReceiveRole, pixels: CVPixelBuffer, pts: CMTime, duration: CMTime
    let mappingGeneration: UUID
    let clockQuality: GuestClockQuality
}
struct GuestAudioFrame: @unchecked Sendable {
    let lease: GuestReceiveLease, pcm: AVAudioPCMBuffer, pts: CMTime, duration: CMTime
    let mappingGeneration: UUID
    let clockQuality: GuestClockQuality
}

/// A recipient-specific public Program sum, excluding that full lease's own
/// channel before any bus clamp. Revision fences queued PCM across revocation.
struct GuestReturnAudioFrame: @unchecked Sendable {
    let lease: GuestReceiveLease
    let routingRevision: UInt64
    let sample: CMSampleBuffer
    var pts: CMTime { sample.presentationTimeStamp }
}
