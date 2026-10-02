import CoreMedia
import CoreVideo
import Foundation
import StreamCore

private final class PrivacyPixels: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(Double, Double)] = []
    func receive(_ frame: CompositedFrame) {
        guard let pixels = frame.pixelBuffer else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        var total = 0, count = 0
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                let offset = y * rowBytes + x * 4
                total += Int(base[offset]) + Int(base[offset + 1]) + Int(base[offset + 2]); count += 3
            }
        }
        lock.lock(); samples.append((frame.presentationTime.seconds, Double(total) / Double(count)))
        if samples.count > 256 { samples.removeFirst() }; lock.unlock()
    }
    func values(after start: Double, before end: Double = .infinity) -> [Double] {
        lock.lock(); defer { lock.unlock() }
        return samples.filter { $0.0 >= start && $0.0 < end }.map { $0.1 }
    }
}

@main struct StudioPrivacyHarness {
    static func main() async throws {
        let gate = ProgramPrivacyGate(), pixels = PrivacyPixels()
        var title = TextSourcePayload(text: "Public comment")
        title.colorHex = "#000000"; title.backgroundColorHex = "#FFFFFF"; title.boxSizing = .fixed
        let comment = LayerNode(name: "Comment Slot", payload: .text(title), transform: .fullscreen)
        let visible = Scene(name: "Program", layers: [comment], background: .solid(colorHex: "#000000"))
        var hidden = visible; hidden.layers[0].isVisible = false
        let slate = Scene(name: "Private Slate", layers: [], background: .solid(colorHex: "#000000"))
        let engine = CompositionEngine(screenProvider: { nil }, cameraProvider: { nil },
            sourcePayloadProvider: { [:] }, overlayContextProvider: { gate.overlays() },
            sceneRegistryProvider: { [:] }, transitionRequestProvider: { nil },
            annotationProvider: { gate.annotations() }, canvasSize: CGSize(width: 320, height: 180), frameRate: 30,
            frameOverrideProvider: { gate.sceneSnapshot() })
        await engine.addSink(token: UUID(), capacity: 2, sink: pixels.receive)
        await engine.run(scene: visible, canvasSize: CGSize(width: 320, height: 180), frameRate: 30)
        try await Task.sleep(for: .milliseconds(250))
        let controlStart = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        await engine.updateScene(hidden)
        try await Task.sleep(for: .milliseconds(150))
        precondition(pixels.values(after: controlStart).contains { $0 > 20 }, "Control must actually render an exiting comment fade")
        await engine.stop()

        await engine.run(scene: visible, canvasSize: CGSize(width: 320, height: 180), frameRate: 30)
        try await Task.sleep(for: .milliseconds(150))
        await engine.updateScene(hidden)
        gate.setScene(slate)
        let privateStart = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        try await Task.sleep(for: .milliseconds(300))
        // Ignore a frame whose override snapshot preceded the gate change.
        // The remaining window still overlaps the 250 ms exit fade.
        let privateValues = pixels.values(after: privateStart + 1.0 / 30, before: privateStart + 0.23)
        precondition(privateValues.count >= 3, "The regression must inspect native rendered frames during the fade")
        precondition(privateValues.allSatisfy { $0 < 1 }, "An exiting comment must never paint over the private slate: \(privateValues)")
        gate.setScene(nil)
        let reopened = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        try await Task.sleep(for: .milliseconds(150))
        precondition(pixels.values(after: reopened + 1.0 / 30).allSatisfy { $0 < 1 }, "An expired fade cannot reappear on reopening")
        await engine.stop()
        // Deliberately miss output deadlines: a fade must expire in media
        // time even when fewer than eight frames have actually rendered.
        let slowPixels = PrivacyPixels()
        let slow = CompositionEngine(screenProvider: { nil }, cameraProvider: { nil },
            sourcePayloadProvider: { Thread.sleep(forTimeInterval: 0.12); return [:] },
            overlayContextProvider: { gate.overlays() }, sceneRegistryProvider: { [:] },
            transitionRequestProvider: { nil }, annotationProvider: { gate.annotations() },
            canvasSize: CGSize(width: 320, height: 180), frameRate: 30,
            frameOverrideProvider: { gate.sceneSnapshot() })
        await slow.addSink(token: UUID(), capacity: 2, sink: slowPixels.receive)
        await slow.run(scene: visible, canvasSize: CGSize(width: 320, height: 180), frameRate: 30)
        try await Task.sleep(for: .milliseconds(300))
        await slow.updateScene(hidden)
        gate.setScene(slate)
        try await Task.sleep(for: .milliseconds(350))
        gate.setScene(nil)
        let slowReopened = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        try await Task.sleep(for: .milliseconds(350))
        let slowValues = slowPixels.values(after: slowReopened + 1.0 / 30)
        precondition(!slowValues.isEmpty && slowValues.allSatisfy { $0 < 1 },
                     "Missed render deadlines cannot extend an expired fade: \(slowValues)")
        let slowMetrics = await slow.metricsSnapshot()
        precondition(slowMetrics.missedDeadlines > 0, "The overload control must miss render deadlines")
        await slow.stop()
        print("PASS: actual native comment fade control, private-slate pixel suppression during an exit fade, and no expired-layer leak on reopening")
    }
}
