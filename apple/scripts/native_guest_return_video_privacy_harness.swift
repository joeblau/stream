import AppKit
import CoreMedia
import CoreVideo
import Foundation
import StreamCore

private func require(_ value: Bool, _ message: String) { precondition(value, message) }

private struct Receipt: Sendable {
    let pts: CMTime, accepted: Bool, red: Int, green: Int, blue: Int
}
private final class SnapshotState: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var override: Scene?, hold = false
    private var receipts: [Receipt] = []
    func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 3) == .success }
    func arm() { lock.lock(); hold = true; lock.unlock() }
    func setOverride(_ scene: Scene) { lock.lock(); override = scene; lock.unlock() }
    func read() -> Scene? {
        lock.lock(); let captured = override, pause = hold; hold = false; lock.unlock()
        if pause {
            entered.signal()
            require(resume.wait(timeout: .now() + 5) == .success, "Held native tick was not resumed")
        }
        return captured
    }
    func receive(_ frame: GuestReturnVideoFrame, sink: NativeGuestMediaSink) {
        let accepted = sink.sendReturnVideoIfCurrent(frame) { true }
        guard let image = frame.sample.imageBuffer else { return }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        let pointer = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
        let offset = CVPixelBufferGetBytesPerRow(image) * (CVPixelBufferGetHeight(image) / 2) + (CVPixelBufferGetWidth(image) / 2) * 4
        let receipt = Receipt(pts: frame.pts, accepted: accepted, red: Int(pointer[offset + 2]), green: Int(pointer[offset + 1]), blue: Int(pointer[offset]))
        CVPixelBufferUnlockBaseAddress(image, .readOnly)
        lock.lock(); receipts.append(receipt); lock.unlock()
    }
    func snapshot() -> [Receipt] { lock.lock(); defer { lock.unlock() }; return receipts }
}

@main struct HeldSnapshotReview {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let red = Scene(name: "Owned public red", layers: [], background: .solid(colorHex: "#FF0000"))
        let black = Scene(name: "Owned private slate", layers: [], background: .solid(colorHex: "#000000"))
        let state = SnapshotState(), authority = NativeGuestProgramReturnAuthority()
        authority.change(active: true)
        let engine = CompositionEngine(screenProvider: { nil }, cameraProvider: { nil },
            sourcePayloadProvider: { [:] }, overlayContextProvider: { .empty }, sceneRegistryProvider: { [:] },
            transitionRequestProvider: { nil }, annotationProvider: { .empty },
            canvasSize: CGSize(width: 64, height: 36), frameRate: 30, frameOverrideProvider: { state.read() })
        let lease = GuestReceiveLease(slot: UUID(), peerID: UUID(), negotiation: UUID(), generation: 1)
        let audio = AudioMixEngine(), frames = GuestVideoFrameStore()
        require(frames.register(lease), "Owned video registration")
        require(await audio.registerGuest(lease), "Owned audio registration")
        let sink = NativeGuestMediaSink(registered: lease, video: frames, audio: audio)
        sink.bindProgramReturn(.init(authority: authority, install: { token, consume in
            await engine.addSink(token: token, capacity: 1) { consume($0.sampleBuffer) }; return true
        }, remove: { token in await engine.removeSink(token) }))
        let original = UUID()
        require(sink.claimReturnVideo(original), "Owned original token claim")
        require(await sink.installReturnVideo(token: original) { state.receive($0, sink: sink) }, "Owned original subscription")
        // This boundary models sender retirement; the token removal itself is
        // the shipping sink API and fences old callbacks synchronously.
        sink.bindVideoRetirement { [weak sink] in sink?.removeReturnVideo(token: original) }
        await engine.run(scene: red, canvasSize: CGSize(width: 64, height: 36), frameRate: 30)
        for _ in 0..<200 {
            if state.snapshot().contains(where: { $0.accepted && $0.red > 200 && $0.green < 10 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        require(state.snapshot().contains(where: { $0.accepted && $0.red > 200 }), "Actual warm red pixels missing")
        state.arm()
        let entered = await Task.detached { state.waitUntilEntered() }.value
        require(entered, "Actual shipping override read did not pause")
        let cutoff = CMClockGetTime(CMClockGetHostTimeClock())
        if !CommandLine.arguments.contains("--unsafe-cutoff-only") { sink.stopProgramReturn() }
        authority.change()
        state.setOverride(black)
        state.resume.signal()
        for _ in 0..<100 {
            if state.snapshot().contains(where: { $0.pts >= cutoff && $0.red > 200 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let stale = state.snapshot().filter { $0.pts >= cutoff && $0.red > 200 }
        require(!stale.isEmpty, "Held old snapshot was not actually rendered with newer source PTS")
        print("Actual held old Program: \(stale.count) red frames stamped after privacy cutoff, accepted=\(stale.map(\.accepted))")
        if CommandLine.arguments.contains("--unsafe-cutoff-only") {
            require(stale.allSatisfy { !$0.accepted }, "Timestamp-only privacy cutoff admits old Program pixels")
        } else {
            require(stale.allSatisfy { !$0.accepted }, "Revoked old return token admitted private pixels")
            let current = UUID()
            require(sink.claimReturnVideo(current), "Fresh token claim")
            require(await sink.installReturnVideo(token: current) { state.receive($0, sink: sink) }, "Explicit fresh actor-serialized subscription")
            for _ in 0..<100 {
                if state.snapshot().contains(where: { $0.pts >= cutoff && $0.accepted && $0.red < 10 && $0.green < 10 && $0.blue < 10 }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            require(state.snapshot().contains(where: { $0.pts >= cutoff && $0.accepted && $0.red < 10 && $0.green < 10 && $0.blue < 10 }), "Fresh actual slate pixels missing")
            sink.removeReturnVideo(token: current)
            print("PASS: actual compositor held old snapshot receives newer host PTS; synchronous token revoke rejects old pixels; explicit actor-barrier install admits only fresh black slate")
        }
        await engine.stop(); sink.close()
    }
}
