import CoreMedia
import CoreVideo
import Foundation

@main
enum GuestFrameStoreHarness {
    static func main() {
        let store = GuestVideoFrameStore()
        let lease = GuestReceiveLease(slot: UUID(), peerID: UUID(), negotiation: UUID(), generation: 1)
        let clock = UUID()
        let now = CMTime(seconds: 100, preferredTimescale: 48_000)
        var pixels: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, nil, &pixels) == kCVReturnSuccess)
        let frame = GuestVideoFrame(lease: lease, role: .camera, pixels: pixels!,
                                   pts: now + CMTime(value: 5_760, timescale: 48_000), duration: .invalid,
                                   mappingGeneration: clock, clockQuality: .senderReportAligned)
        precondition(!store.receive(frame, arrival: now), "Unregistered media must not admit itself")
        precondition(store.register(lease))
        precondition(!store.register(.init(slot: UUID(), peerID: UUID(), negotiation: UUID(), generation: 1)),
                     "A second slot must not silently evict the admitted peer")
        precondition(store.receive(frame, arrival: now))
        precondition(store.pixels(slot: lease.slot, role: .camera, at: now, program: false) == nil,
                     "Preview must not show future decoded pixels")
        precondition(store.pixels(slot: lease.slot, role: .camera, at: frame.pts, program: false) === pixels)
        precondition(store.pixels(slot: lease.slot, role: .camera, at: frame.pts, program: true) == nil,
                     "Backstage media must not reach Program")
        store.allowProgram(true, lease: lease)
        precondition(store.pixels(slot: lease.slot, role: .camera, at: frame.pts, program: true) === pixels)
        precondition(store.pixels(slot: UUID(), role: .camera, at: frame.pts, program: true) == nil)
        precondition(store.pixels(slot: lease.slot, role: .camera, at: frame.pts + CMTime(value: 12_001, timescale: 48_000), program: false) == nil)

        let screen = GuestVideoFrame(lease: lease, role: .screen, pixels: pixels!, pts: frame.pts,
                                    duration: .invalid, mappingGeneration: clock, clockQuality: .senderReportAligned)
        precondition(!store.receive(screen, arrival: now))
        store.enable(.screen, lease: lease)
        precondition(store.receive(screen, arrival: now))
        precondition(store.pixels(slot: lease.slot, role: .screen, at: frame.pts + CMTime(seconds: 20, preferredTimescale: 48_000), program: false) === pixels)
        store.disable(.screen, lease: lease)
        precondition(store.pixels(slot: lease.slot, role: .screen, at: screen.pts, program: true) == nil)
        precondition(!store.receive(screen, arrival: now), "Ended screen callbacks must remain rejected")

        for index in 1...100 {
            let time = frame.pts + CMTime(value: Int64(index), timescale: 48_000)
            precondition(store.receive(.init(lease: lease, role: .camera, pixels: pixels!, pts: time,
                                            duration: .invalid, mappingGeneration: clock, clockQuality: .senderReportAligned), arrival: now))
        }
        let bounds = store.statistics()
        precondition(bounds.retainedFrames <= 16 && bounds.retainedBytes <= 32 * 1_024 * 1_024 && bounds.overflow > 0)
        precondition(!store.acceptClock(lease: lease, mapping: UUID()), "One peer must retain one common clock")
        let replacement = GuestReceiveLease(slot: lease.slot, peerID: lease.peerID, negotiation: UUID(), generation: 2)
        precondition(store.register(replacement))
        precondition(!store.receive(frame, arrival: now), "Old peer generations must not repopulate a stable slot")
        store.allowProgram(true, lease: lease)
        precondition(store.pixels(slot: replacement.slot, role: .camera, at: frame.pts, program: true) == nil)
        store.retire()
        precondition(!store.register(replacement))
        precondition(store.statistics().retainedFrames == 0)
        history()
        print("Guest frame store: explicit registration, due-frame playout, backstage/Program separation, exact slot/role, stale camera, static-screen stop, bounded overflow, common mapping and permanent runtime retirement PASS")
        print("Qualification: generated CoreVideo receipts exercise the real store; transport, renderer, mixer and hardware are separate proofs")
    }
    static func history() {
        let store = GuestVideoFrameStore()
        let lease = GuestReceiveLease(slot: UUID(), peerID: UUID(), negotiation: UUID(), generation: 8)
        let clock = UUID(), host = CMTime(value: 100_000, timescale: 1_000)
        precondition(store.register(lease)); store.allowProgram(true, lease: lease)
        var inputs: [CVPixelBuffer] = []
        for index in 0..<9 {
            var pixels: CVPixelBuffer?
            precondition(CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, nil, &pixels) == kCVReturnSuccess)
            inputs.append(pixels!)
            let pts = host + CMTime(value: 120, timescale: 1_000) - CMTime(value: Int64(8-index), timescale: 30)
            precondition(store.receive(.init(lease: lease, role: .camera, pixels: pixels!, pts: pts, duration: .invalid,
                mappingGeneration: clock, clockQuality: .senderReportAligned), arrival: host))
        }
        let program = store.pixels(slot: lease.slot, role: .camera, at: host, program: true)
        precondition(program === inputs[4], "Program must select its actual due frame")
        let isoTime = host - CMTime(value: 90, timescale: 1_000)
        precondition(store.pixels(slot: lease.slot, role: .camera, at: isoTime, program: true, requiring: lease) === inputs[1],
                     "120ms future playout must preserve the real30fps frame for a90ms historical ISO query")
        precondition(store.pixels(slot: lease.slot, role: .camera, at: host, program: true) === program,
                     "ISO history lookup must never consume the Program frame")
        store.allowProgram(false, lease: lease)
        precondition(store.pixels(slot: lease.slot, role: .camera, at: isoTime, program: true, requiring: lease) == nil)
        store.allowProgram(true, lease: lease)
        // Exercise both independent byte caps with real-sized CoreVideo
        // buffers. A high-rate producer remains bounded even after the
        // history accommodates the normal browser playout/ISO offset.
        store.enable(.screen, lease: lease)
        var large: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA, nil, &large) == kCVReturnSuccess)
        for index in 1...100 {
            let pts = host + CMTime(value: 120+Int64(index), timescale: 1_000)
            for role in [GuestReceiveRole.camera, .screen] {
                precondition(store.receive(.init(lease: lease, role: role, pixels: large!, pts: pts, duration: .invalid,
                    mappingGeneration: clock, clockQuality: .senderReportAligned), arrival: host))
            }
        }
        let bounds = store.statistics()
        precondition(bounds.retainedFrames <= 32 && bounds.retainedBytes <= 64 * 1_024 * 1_024 && bounds.overflow > 0)
        store.retire(); precondition(store.statistics().retainedFrames == 0)
        print("Guest frame store: actual30fps future+ISO history, nondestructive Program query, immediate backstage and dual-role memory caps PASS")
    }
}
