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
        let size = CGSize(width: 320, height: 180)
        func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 60_000) }
        func render(_ seconds: Double) async throws -> [Double] {
            let pts = time(seconds)
            for _ in 0..<100 {
                await engine.renderValidationFrame(at: pts)
                let values = pixels.values(after: pts.seconds - 0.00001, before: pts.seconds + 0.00001)
                if !values.isEmpty { return values }
                try await Task.sleep(for: .milliseconds(20))
            }
            let metrics = await engine.metricsSnapshot()
            preconditionFailure("Native compositor did not deliver a frame at \(seconds); metrics=\(metrics); observed=\(pixels.values(after: 0))")
        }
        await engine.prepareValidation(scene: visible, canvasSize: size, frameRate: 30, at: time(1))
        let visibleValues = try await render(1)
        precondition(visibleValues.contains { $0 > 20 }, "Control must paint the visible comment")
        await engine.setValidationTime(time(2)); await engine.updateScene(hidden)
        let controlValues = try await render(2.1)
        precondition(controlValues.contains { $0 > 20 }, "Control must actually render an exiting comment fade")

        await engine.prepareValidation(scene: visible, canvasSize: size, frameRate: 30, at: time(3))
        _ = try await render(3)
        await engine.setValidationTime(time(4)); await engine.updateScene(hidden); gate.setScene(slate)
        for seconds in [4.01, 4.05, 4.1, 4.2] {
            let values = try await render(seconds)
            precondition(values.allSatisfy { $0 < 1 }, "An exiting comment must never paint over the private slate: \(values)")
        }
        gate.setScene(nil)
        let reopenedValues = try await render(4.4)
        precondition(reopenedValues.allSatisfy { $0 < 1 }, "An expired fade cannot reappear on reopening")
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
        await slow.setOutput(canvasSize: CGSize(width: 320, height: 180), frameRate: 7)
        try await Task.sleep(for: .milliseconds(350))
        gate.setScene(nil)
        let slowReopened = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        var slowValues: [Double] = []
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            slowValues = slowPixels.values(after: slowReopened + 1.0 / 30)
            if !slowValues.isEmpty { break }
        }
        precondition(!slowValues.isEmpty && slowValues.allSatisfy { $0 < 1 },
                     "Missed render deadlines cannot extend an expired fade: \(slowValues)")
        let slowMetrics = await slow.metricsSnapshot()
        precondition(slowMetrics.missedDeadlines > 0, "The overload control must miss render deadlines")
        await slow.stop()
        print("PASS: actual native comment fade control, private-slate pixel suppression during an exit fade, and no expired-layer leak on reopening")
    }
}
