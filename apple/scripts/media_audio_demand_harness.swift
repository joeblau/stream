import AVFoundation
import CoreMedia
import Foundation
import StreamCore

// Opaque desktop identities only; the demand fence, actor mutations, rings,
// converter and Program PCM below are shipping implementations.
struct CaptureSourceKey: Hashable, Sendable { let id: UUID }
struct SourceDefinitionID: Hashable, Sendable, CustomStringConvertible {
    let id: UUID
    var description: String { id.uuidString }
}
private final class DemandPCM: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Float] = []
    func receive(_ sample: CMSampleBuffer) {
        guard let block = sample.dataBuffer else { return }
        var pcm = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
        let status = pcm.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        precondition(status == noErr)
        lock.withLock { values += pcm; if values.count > 48_000 { values.removeFirst(values.count - 48_000) } }
    }
    func rms() -> Double {
        lock.withLock {
            let tail = values.suffix(16_384)
            return sqrt(tail.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, tail.count)))
        }
    }
}
@main struct MediaAudioDemandHarness {
    static func main() async throws {
        let engine = AudioMixEngine(), demand = MediaAudioChannelDemand()
        let channel = AudioChannelID.media(SourceDefinitionID(id: UUID()))
        let retired = UUID(), current = UUID()
        demand.replace([channel: retired]); let retiredRevision = demand.currentRevision()
        // A later reconciliation installs the replacement before the older
        // multi-channel task resumes its next actor call.
        demand.replace([channel: current])
        await engine.run()
        await engine.addChannel(channel, ifCurrent: { demand.matches(channel, identity: current) }, insert: { sample in
            try! ProgramRecordingFixtures.audio(at: sample.presentationTimeStamp.seconds, timestampBase: 0, constantTone: true, amplitude: 0.2)
        })
        await engine.setChannelGain(channel, volume: 1, isMuted: false)
        await engine.addChannel(channel, ifCurrent: { demand.matches(channel, identity: retired) }, insert: { sample in
            try! ProgramRecordingFixtures.audio(at: sample.presentationTimeStamp.seconds, timestampBase: 0, constantTone: true, amplitude: 0.05)
        })
        await engine.removeChannel(channel, ifCurrent: { demand.matches(channel, identity: nil) })
        await engine.pruneChannels(keeping: [], ifCurrent: { demand.matches(revision: retiredRevision) })
        let probe = DemandPCM(), token = UUID()
        await engine.addTap(bus: .program, token: token, capacity: 16) { probe.receive($0) }
        let clock = ContinuousClock(), started = ContinuousClock.now
        let origin = CMClockGetTime(CMClockGetHostTimeClock()).seconds + 0.02
        for chunk in 0..<50 {
            // A stale remove/prune would auto-create an insert-less channel
            // and emit0.8-amplitude PCM; a stale add would emit0.05 instead.
            engine.enqueue(channel, try ProgramRecordingFixtures.audio(at: origin + Double(chunk) / 100, timestampBase: 0, constantTone: true, amplitude: 0.8))
            try await clock.sleep(until: started.advanced(by: .milliseconds((chunk + 1) * 10)))
        }
        let measured = probe.rms()
        print("TRACE demand identity current=\(demand.matches(channel, identity: current)); actual mixer stats=\(await engine.statsSnapshot()); RMS=\(measured)")
        precondition(measured > 0.13 && measured < 0.15, "Stale reconciliation replaced/removed current insert: RMS=\(measured)")
        demand.replace([:])
        await engine.removeChannel(channel, ifCurrent: { demand.matches(channel, identity: nil) })
        precondition(!demand.matches(channel, identity: current), "Retirement did not revoke insert identity")
        await engine.removeTap(token); await engine.stop()
        print("PASS: actor-side current insert identity rejects stale add/remove/prune after replacement; actual Program PCM RMS=\(measured) retains current0.2-amplitude insert (stale0.05/raw0.8 rejected)")
    }
}
