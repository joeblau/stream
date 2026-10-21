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

private final class SecondaryGeometryProof: @unchecked Sendable {
    private let lock = NSLock()
    private var dimensions: [[Int]] = [], stale = 0
    func receive(_ frame: CompositedFrame, old: Bool) {
        lock.lock(); defer { lock.unlock() }
        if old { stale += 1 }
        else if let image = frame.pixelBuffer, dimensions.count < 8 { dimensions.append([CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image)]) }
    }
    var qualified: Bool { lock.lock(); defer { lock.unlock() }; return !dimensions.isEmpty && dimensions.allSatisfy { $0 == [64, 112] } && stale == 0 }
}

private struct CleanPixels: Sendable {
    let pts: CMTime
    let center: [Int], left: [Int], right: [Int]
}
private final class CleanPixelProof: @unchecked Sendable {
    private let lock = NSLock()
    private var program: [CleanPixels] = [], clean: [CleanPixels] = []
    func receive(_ frame: CompositedFrame, clean isClean: Bool) {
        guard let pixels = frame.pixelBuffer else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        func read(_ x: Double, _ y: Double) -> [Int] {
            let offset = Int(Double(CVPixelBufferGetHeight(pixels)) * y) * CVPixelBufferGetBytesPerRow(pixels) + Int(Double(CVPixelBufferGetWidth(pixels)) * x) * 4
            return [Int(bytes[offset + 2]), Int(bytes[offset + 1]), Int(bytes[offset])]
        }
        let value = CleanPixels(pts: frame.presentationTime, center: read(0.5, 0.5), left: read(0.25, 0.25), right: read(0.75, 0.25))
        CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        lock.lock(); defer { lock.unlock() }
        if isClean { if clean.count == 32 { clean.removeFirst() }; clean.append(value) }
        else { if program.count == 32 { program.removeFirst() }; program.append(value) }
    }
    func hasQualifiedPair() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return program.contains { p in clean.contains { c in
            p.pts == c.pts && p.center[0] > 200 && p.center[1] < 60 && p.center[2] < 60 &&
            p.left[1] > 200 && p.right[1] > 200 &&
            c.left[0] < 40 && c.left[1] < 60 && c.left[2] > 200 &&
            c.right[0] > 100 && c.right[1] < 80 && c.right[2] > 140 &&
            c.center[0] > 100 && c.center[1] < 80 && c.center[2] > 140
        }}
    }
}

@main struct HeldSnapshotReview {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let canvas: OutputCanvas = CommandLine.arguments.contains("--secondary") ? .secondary : .program
        let red = Scene(name: "Owned public red", layers: [], background: .solid(colorHex: "#FF0000"), secondaryCanvas: .init(size: .init(width: 64, height: 36)))
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
            await engine.addSink(token: token, capacity: 1, canvas: canvas) { consume($0.sampleBuffer) }; return true
        }, remove: { token in await engine.removeSink(token) }))
        if canvas == .secondary {
            sink.bindSecondaryReturn(.init(authority: authority, install: { token, consume in
                await engine.addSink(token: token, capacity: 1, canvas: .secondary) { consume($0.sampleBuffer) }; return true
            }, remove: { token in await engine.removeSink(token) }))
            require(sink.selectReturnVideoSource(.secondary), "Select actual Secondary subscription")
        }
        if CommandLine.arguments.contains("--clean") {
            sink.bindCleanReturn(.init(authority: authority, install: { token, consume in
                await engine.addCleanSink(token: token, capacity: 1) { consume($0.sampleBuffer) }; return true
            }, remove: { token in await engine.removeSink(token) }))
            require(sink.selectReturnVideoSource(.clean), "Select actual Clean subscription")
        }
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
            print("PASS \(CommandLine.arguments.contains("--clean") ? "clean" : canvas.rawValue): actual compositor held old snapshot receives newer host PTS; synchronous token revoke rejects old pixels; explicit actor-barrier install admits only fresh black slate")
        }
        await engine.stop(); sink.close()
        if CommandLine.arguments.contains("--clean") { try await proveCleanPixels() }
        if canvas == .secondary { try await proveCancelledSecondaryGeometry() }
    }
    @MainActor private static func proveCancelledSecondaryGeometry() async throws {
        let scene = Scene(name: "Owned secondary geometry", layers: [], background: .solid(colorHex: "#0000FF"),
            secondaryCanvas: .init(size: .init(width: 64, height: 112)))
        let engine = CompositionEngine(screenProvider: { nil }, cameraProvider: { nil }, overlayContextProvider: { .empty },
            sceneRegistryProvider: { [:] }, transitionRequestProvider: { nil }, annotationProvider: { .empty },
            canvasSize: .init(width: 112, height: 64), frameRate: 30)
        let proof = SecondaryGeometryProof(), old = UUID(), current = UUID()
        // An entered old install captured landscape geometry before Off.
        // Its actor call arrives only after removal and a new portrait install.
        await engine.removeSink(old)
        await engine.addSink(token: current, capacity: 1, canvas: .secondary, canvasSize: .init(width: 64, height: 112)) { proof.receive($0, old: false) }
        await engine.addSink(token: old, capacity: 1, canvas: .secondary, canvasSize: .init(width: 112, height: 64)) { proof.receive($0, old: true) }
        await engine.run(scene: scene, canvasSize: .init(width: 112, height: 64), frameRate: 30)
        for _ in 0..<100 { if proof.qualified { break }; try await Task.sleep(for: .milliseconds(10)) }
        let count = await engine.subscriberCount
        require(proof.qualified && count == 1, "Canceled old install cannot mutate replacement Secondary geometry or attach a stale tap")
        await engine.removeSink(current); await engine.stop()
        print("PASS actual Secondary actor installation: canceled late landscapeA cannot mutate current portraitB geometry or add its tap")
    }

    @MainActor private static func proveCleanPixels() async throws {
        let layer = LayerNode(name: "Owned blue scene layer", payload: .shape(.init(fillColorHex: "#0000FF")),
            transform: .init(position: .init(x: 0, y: 0), size: .init(width: 0.5, height: 1), anchor: .topLeft))
        let scene = Scene(name: "Owned clean semantics", layers: [layer])
        let overlay = LayerNode(name: "Owned green project overlay", payload: .shape(.init(fillColorHex: "#00FF00")), transform: .fullscreen)
        let context = OverlayContext(overlays: [overlay], defaultBackground: .solid(colorHex: "#A020D0"))
        let stroke = AnnotationStroke(tool: .pen, colorHex: "#FF0000", width: 64,
            points: [.init(x: 0.1, y: 0.5), .init(x: 0.9, y: 0.5)])
        let annotations = AnnotationRenderSnapshot(strokes: [scene.id: [stroke]])
        let engine = CompositionEngine(screenProvider: { nil }, cameraProvider: { nil }, sourcePayloadProvider: { [:] },
            overlayContextProvider: { context }, sceneRegistryProvider: { [:] }, transitionRequestProvider: { nil },
            annotationProvider: { annotations }, canvasSize: .init(width: 320, height: 180), frameRate: 30)
        let proof = CleanPixelProof(), program = UUID(), clean = UUID()
        await engine.addSink(token: program, capacity: 1) { proof.receive($0, clean: false) }
        await engine.addCleanSink(token: clean, capacity: 1) { proof.receive($0, clean: true) }
        await engine.run(scene: scene, canvasSize: .init(width: 320, height: 180), frameRate: 30)
        for _ in 0..<200 { if proof.hasQualifiedPair() { break }; try await Task.sleep(for: .milliseconds(10)) }
        require(proof.hasQualifiedPair(), "Same-PTS actual Program must show green overlay/red annotation; Clean must preserve blue scene layer/purple project background and omit both")
        await engine.removeSink(program); await engine.removeSink(clean)
        require(await engine.subscriberCount == 0, "Clean and Program subscriptions both retired")
        await engine.stop()
        print("PASS clean semantics: actual same-PTS Program green overlay/red annotation; Clean blue scene layer/purple project background, no overlay/annotation; zero remaining subscriptions")
    }

}
