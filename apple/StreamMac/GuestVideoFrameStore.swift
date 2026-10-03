import CoreMedia
import CoreVideo
import Foundation

/// Runtime-owned playout for one explicitly registered remote peer. A receipt
/// never registers a slot, and neither Preview nor Program reads future pixels.
final class GuestVideoFrameStore: @unchecked Sendable {
    struct Statistics: Sendable {
        var accepted = 0
        var rejected = 0
        var overflow = 0
        var retainedFrames = 0
        var retainedBytes = 0
    }
    private struct RoleFrames {
        var frames: [GuestVideoFrame] = []
        var bytes = 0
        var enabled = false
    }
    private let lock = NSLock()
    private var lease: GuestReceiveLease?
    private var mapping: UUID?
    private var programAllowed = false
    private var closed = false
    private var roles: [GuestReceiveRole: RoleFrames] = [:]
    private var stats = Statistics()
    private let maximumFrames = 6
    private let maximumBytes = 24 * 1_024 * 1_024

    /// The caller owns admission. Replacing a peer clears every retained frame
    /// before the new generation can publish, even when its stable slot matches.
    @discardableResult
    func register(_ current: GuestReceiveLease) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, current.generation > 0 else { return false }
        if lease == current { return true }
        if let lease, lease.slot != current.slot { return false }
        lease = current; mapping = nil; programAllowed = false
        roles = [.camera: RoleFrames(enabled: true), .screen: RoleFrames()]
        return true
    }

    func allowProgram(_ allowed: Bool, lease current: GuestReceiveLease) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, lease == current else { return }
        programAllowed = allowed
    }

    func enable(_ role: GuestReceiveRole, lease current: GuestReceiveLease) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, lease == current, role != .audio else { return }
        // Re-enabling never restores pixels from an earlier screen capture.
        roles[role] = RoleFrames(enabled: true)
    }

    func disable(_ role: GuestReceiveRole, lease current: GuestReceiveLease) {
        lock.lock(); defer { lock.unlock() }
        guard lease == current, role != .audio else { return }
        roles[role] = RoleFrames()
    }

    /// Shared by audio admission and video ingest so one peer cannot route
    /// different clock generations into the same scene and mixer channel.
    func acceptClock(lease current: GuestReceiveLease, mapping generation: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return acceptClockLocked(lease: current, mapping: generation)
    }

    private func acceptClockLocked(lease current: GuestReceiveLease, mapping generation: UUID) -> Bool {
        guard !closed, lease == current else { return false }
        if let mapping { return mapping == generation }
        mapping = generation; return true
    }

    @discardableResult
    func receive(_ frame: GuestVideoFrame, arrival: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let width = CVPixelBufferGetWidth(frame.pixels), height = CVPixelBufferGetHeight(frame.pixels)
        let (bytes, byteOverflow) = CVPixelBufferGetBytesPerRow(frame.pixels).multipliedReportingOverflow(by: height)
        guard frame.role != .audio, frame.pts.isNumeric, arrival.isNumeric,
              abs((frame.pts - arrival).seconds) <= 0.5,
              CVPixelBufferGetPixelFormatType(frame.pixels) == kCVPixelFormatType_32BGRA,
              width > 0, height > 0, width <= 1_920, height <= 1_920,
              width * height <= 1_280 * 720, !byteOverflow, bytes > 0, bytes <= maximumBytes,
              var state = roles[frame.role], state.enabled,
              acceptClockLocked(lease: frame.lease, mapping: frame.mappingGeneration),
              state.frames.last.map({ frame.pts > $0.pts }) ?? true else {
            stats.rejected += 1; return false
        }
        while !state.frames.isEmpty,
              state.frames.count >= maximumFrames || state.bytes + bytes > maximumBytes {
            let removed = state.frames.removeFirst()
            state.bytes -= CVPixelBufferGetBytesPerRow(removed.pixels) * CVPixelBufferGetHeight(removed.pixels)
            stats.overflow += 1
        }
        state.frames.append(frame); state.bytes += bytes; roles[frame.role] = state
        stats.accepted += 1; return true
    }

    /// Non-destructive across canvases. Camera pixels expire; an enabled static
    /// screen retains its last due frame until an explicit track/session end.
    func pixels(slot: UUID, role: GuestReceiveRole, at time: CMTime, program: Bool,
                requiring current: GuestReceiveLease? = nil) -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard !closed, lease?.slot == slot, current == nil || current == lease,
              (!program || programAllowed), time.isNumeric,
              let state = roles[role], state.enabled,
              let index = state.frames.lastIndex(where: { $0.pts <= time }) else { return nil }
        let frame = state.frames[index]
        guard role == .screen || (time - frame.pts).seconds <= 0.25 else { return nil }
        return frame.pixels
    }

    func remove(_ current: GuestReceiveLease) {
        lock.lock(); defer { lock.unlock() }
        guard lease == current else { return }
        lease = nil; mapping = nil; programAllowed = false; roles.removeAll()
    }

    /// Retirement is permanent for this runtime, including late registrations.
    func retire() {
        lock.lock(); defer { lock.unlock() }
        closed = true; lease = nil; mapping = nil; programAllowed = false; roles.removeAll()
    }

    func statistics() -> Statistics {
        lock.lock(); defer { lock.unlock() }
        var value = stats
        value.retainedFrames = roles.values.reduce(0) { $0 + $1.frames.count }
        value.retainedBytes = roles.values.reduce(0) { $0 + $1.bytes }
        return value
    }
}
