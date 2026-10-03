import CoreMedia
import CoreVideo
import Foundation

@main
enum GuestRendererHarness {
    static func pixels(red: UInt8, green: UInt8, blue: UInt8) -> CVPixelBuffer {
        var result: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, nil, &result) == kCVReturnSuccess)
        let pixels = result!
        CVPixelBufferLockBaseAddress(pixels, []); defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<180 { for x in 0..<320 {
            let index = y * CVPixelBufferGetBytesPerRow(pixels) + x * 4
            bytes[index] = blue; bytes[index + 1] = green; bytes[index + 2] = red; bytes[index + 3] = 255
        } }
        return pixels
    }
    static func color(_ frame: CompositedFrame) -> (Int, Int, Int) {
        let pixels = frame.pixelBuffer!
        CVPixelBufferLockBaseAddress(pixels, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let index = CVPixelBufferGetBytesPerRow(pixels) * 90 + 160 * 4
        let p = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        return (Int(p[index + 2]), Int(p[index + 1]), Int(p[index]))
    }
    static func main() throws {
        let store = GuestVideoFrameStore()
        let lease = GuestReceiveLease(slot: UUID(), peerID: UUID(), negotiation: UUID(), generation: 1)
        let clock = UUID(), sourceID = SourceDefinitionID()
        let payload = GuestSourcePayload(slotID: lease.slot)
        let old = try JSONDecoder().decode(GuestSourcePayload.self, from: Data("{}".utf8))
        precondition(old.slotID == nil && old.role == .camera)
        let roundTrip = try JSONDecoder().decode(GuestSourcePayload.self, from: JSONEncoder().encode(payload))
        precondition(roundTrip == payload)
        do {
            _ = try JSONDecoder().decode(GuestSourcePayload.self, from: Data("{\"role\":\"future-role\"}".utf8))
            preconditionFailure("Unknown roles must not substitute a camera")
        } catch DecodingError.dataCorrupted { }
        let child = Scene(name: "Guest child", layers: [LayerNode(name: "Guest", sourceID: sourceID, payload: .guest(payload), transform: .fullscreen)])
        let root = Scene(name: "Nested guest", layers: [LayerNode(name: "Child", payload: .scene(.init(sceneID: child.id)), transform: .fullscreen)])
        let renderer = SceneRenderer(usesSoftwareRendering: true)
        let sources: [SourceDefinitionID: LayerPayload] = [sourceID: .guest(payload)]
        let scenes = [child.id: child, root.id: root]
        func lookup(program: Bool) -> SourceFrameLookup {
            SourceFrameLookup(camera: { _ in nil }, screen: { _ in nil }, guest: { payload, pts in
                guard let slot = payload.slotID else { return nil }
                return store.pixels(slot: slot, role: payload.role == .camera ? .camera : .screen, at: pts, program: program)
            })
        }
        func render(at time: CMTime, program: Bool, values: [SourceDefinitionID: LayerPayload]? = nil) -> CompositedFrame {
            renderer.render(scene: root, overlayContext: .empty, canvasSize: CGSize(width: 320, height: 180),
                            frames: lookup(program: program), sourcePayloads: values ?? sources, scenes: scenes,
                            presentationTime: time, frameDuration: CMTime(value: 1, timescale: 30), sequence: 0)!
        }
        let now = CMTime(seconds: 100, preferredTimescale: 48_000), due = now + CMTime(value: 5_760, timescale: 48_000)
        precondition(store.register(lease))
        precondition(store.receive(.init(lease: lease, role: .camera, pixels: pixels(red: 255, green: 0, blue: 0),
                                        pts: due, duration: .invalid, mappingGeneration: clock, clockQuality: .senderReportAligned), arrival: now))
        precondition(color(render(at: now, program: false)).0 < 5)
        precondition(color(render(at: due, program: false)).0 > 240)
        precondition(color(render(at: due, program: true)).0 < 5)
        store.allowProgram(true, lease: lease)
        precondition(color(render(at: due, program: true)).0 > 240)
        let next = due + CMTime(value: 1, timescale: 30)
        precondition(store.receive(.init(lease: lease, role: .camera, pixels: pixels(red: 0, green: 0, blue: 255),
                                        pts: next, duration: .invalid, mappingGeneration: clock, clockQuality: .senderReportAligned), arrival: now))
        let updated = color(render(at: next, program: true))
        precondition(updated.0 < 5 && updated.2 > 240, "Nested guests must not reuse a static cached image")
        precondition(color(render(at: next, program: true, values: [:])).2 < 5, "Unknown bound source must not use inline guest pixels")
        store.retire()
        precondition(color(render(at: next, program: false)).2 < 5)
        print("Guest renderer: old document defaults, stable slot/role persistence, exact registered source, future-frame withholding, backstage/Program gate, dynamic nested pixels and runtime retirement PASS")
        print("Qualification: actual software Core Image raster from generated CoreVideo receipts; codec transport and combined Program/ISO AV decode remain separate")
    }
}
