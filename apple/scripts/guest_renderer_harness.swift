import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

private final class GuestAdmissionFixtureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    let release = DispatchSemaphore(value: 0)
    func mark() { lock.lock(); active = true; lock.unlock() }
    func entered() -> Bool { lock.lock(); defer { lock.unlock() }; return active }
    func hold() { mark(); precondition(release.wait(timeout: .now() + 3) == .success) }
}
private extension AudioMixEngine {
    /// Hold the actual actor executor, rather than substituting a registration
    /// implementation, to exercise a real pending controller request.
    func holdGuestFixture(_ gate: GuestAdmissionFixtureGate) { gate.hold() }
}

@main
enum GuestRendererHarness {
    @MainActor static func controllerAdmission() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stream-guest-admission-\(UUID().uuidString)")
        try DesktopStorage.prepare(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scenes = SceneStore(directory: directory)
        let mixer = AudioMixEngine()
        let controller = StreamController(sceneStore: scenes, previewProgram: PreviewProgramModel(selected: scenes.selected),
                                          permissions: PermissionsManager(), audioEngine: mixer)
        let initialSources = scenes.sources.count
        let canceledLease = GuestReceiveLease(slot: UUID(), peerID: UUID(), negotiation: UUID(), generation: 1)
        let hold = GuestAdmissionFixtureGate(), started = GuestAdmissionFixtureGate()
        let blocked = Task { await mixer.holdGuestFixture(hold) }
        for _ in 0..<100 where !hold.entered() { try await Task.sleep(for: .milliseconds(1)) }
        precondition(hold.entered())
        let registering = Task { @MainActor in
            started.mark()
            return await controller.registerGuestMedia(canceledLease, name: "Pending Guest")
        }
        for _ in 0..<100 where !started.entered() { try await Task.sleep(for: .milliseconds(1)) }
        precondition(started.entered())
        controller.removeGuestMedia(canceledLease)
        hold.release.signal()
        await blocked.value
        let canceled = await registering.value
        precondition(!canceled && mixer.registeredGuestChannelID(slot: canceledLease.slot) == nil)
        precondition(scenes.sources.count == initialSources, "Canceled admission cannot resurrect scene sources")
        let canceledRetry = await controller.registerGuestMedia(canceledLease, name: "Stale Retry")
        precondition(!canceledRetry, "A retry needs a fresh session generation")
        let second = GuestReceiveLease(slot: canceledLease.slot, peerID: UUID(), negotiation: UUID(), generation: 2)
        let admitted = await controller.registerGuestMedia(second, name: "Registered Guest")
        precondition(admitted && scenes.sources.count == initialSources + 2)
        let duplicateHold = GuestAdmissionFixtureGate(), duplicateStarted = GuestAdmissionFixtureGate()
        let heldAgain = Task { await mixer.holdGuestFixture(duplicateHold) }
        for _ in 0..<100 where !duplicateHold.entered() { try await Task.sleep(for: .milliseconds(1)) }
        precondition(duplicateHold.entered())
        let lease = GuestReceiveLease(slot: second.slot, peerID: UUID(), negotiation: UUID(), generation: 3)
        let winningRegistration = Task { @MainActor in
            duplicateStarted.mark()
            return await controller.registerGuestMedia(lease, name: "Rejoined Guest")
        }
        for _ in 0..<100 where !duplicateStarted.entered() { try await Task.sleep(for: .milliseconds(1)) }
        precondition(duplicateStarted.entered())
        let duplicate = await controller.registerGuestMedia(lease, name: "Duplicate Pending Guest")
        precondition(!duplicate)
        duplicateHold.release.signal()
        await heldAgain.value
        let winner = await winningRegistration.value
        precondition(winner && mixer.registeredGuestChannelID(slot: lease.slot) != nil)
        precondition(scenes.sources.count == initialSources + 2, "A rejoin retains the two stable source identities")
        let camera = scenes.sources.first { source in
            guard case .guest(let payload) = source.payload else { return false }
            return payload.slotID == lease.slot && payload.role == .camera
        }!
        precondition(controller.addRecordingAudioTap(targetID: "channel.guest.\(UUID().uuidString)", processing: .beforeEffects, sink: { _ in }) == nil)
        let recording = controller.addRecordingVideoSource(targetID: "source.\(camera.id)")!
        let render = recording.1.makeRenderer()
        await mixer.run()
        let now = CMClockGetTime(CMClockGetHostTimeClock()), due = now + CMTime(value: 5_760, timescale: 48_000)
        let clock = UUID(), format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let invalidPCM = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        invalidPCM.frameLength = 512
        for channel in 0..<2 { for sample in 0..<512 { invalidPCM.floatChannelData![channel][sample] = 0 } }
        invalidPCM.floatChannelData![0][0] = .nan
        controller.receiveGuestAudio(.init(lease: lease, pcm: invalidPCM, pts: due,
                                          duration: CMTime(value: 512, timescale: 48_000),
                                          mappingGeneration: UUID(), clockQuality: .senderReportAligned))
        precondition(mixer.guestAdmissionSnapshot().mappingGeneration == nil)
        controller.receiveGuestVideo(.init(lease: lease, role: .camera, pixels: pixels(red: 255, green: 0, blue: 0),
                                          pts: due, duration: .invalid, mappingGeneration: clock, clockQuality: .senderReportAligned))
        let validPCM = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        validPCM.frameLength = 512
        for channel in 0..<2 { for sample in 0..<512 { validPCM.floatChannelData![channel][sample] = 0 } }
        controller.receiveGuestAudio(.init(lease: lease, pcm: validPCM, pts: due,
                                          duration: CMTime(value: 512, timescale: 48_000),
                                          mappingGeneration: UUID(), clockQuality: .senderReportAligned))
        precondition(mixer.guestAdmissionSnapshot().mappingGeneration == nil, "Audio cannot replace the registered video clock")
        controller.receiveGuestAudio(.init(lease: lease, pcm: validPCM, pts: due,
                                          duration: CMTime(value: 512, timescale: 48_000),
                                          mappingGeneration: clock, clockQuality: .senderReportAligned))
        precondition(mixer.guestAdmissionSnapshot().mappingGeneration == clock)
        let size = CGSize(width: 320, height: 180), duration = CMTime(value: 1, timescale: 30)
        precondition(!render(size, due, duration, 0, .raw)!.sourceAvailable)
        precondition(controller.setGuestMediaRouting(lease, programAllowed: true, monitorAllowed: false))
        precondition(render(size, due, duration, 1, .raw)!.sourceAvailable)
        precondition(controller.setGuestMediaRouting(lease, programAllowed: false, monitorAllowed: true))
        precondition(!render(size, due, duration, 2, .raw)!.sourceAvailable)
        controller.removeRecordingVideoSource(recording.0)
        controller.retireGuestMedia()
        let afterRetirement = await controller.registerGuestMedia(lease, name: "Retired Guest")
        precondition(!afterRetirement && mixer.registeredGuestChannelID(slot: lease.slot) == nil)
        await mixer.stop()
        print("Guest controller: actual pending admission/remove barrier, no source/channel resurrection, separate stable camera/screen sources, unknown ISO rejection, Program/ISO grant/revoke and permanent retirement PASS")
    }

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
    @MainActor static func main() async throws {
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
        let definition = SourceDefinition(name: "Registered Guest", payload: .guest(payload))
        let iso = RecordingVideoSourceFactory.makeGuest(source: definition, lease: lease, frames: store)!.makeRenderer()
        let size = CGSize(width: 320, height: 180), duration = CMTime(value: 1, timescale: 30)
        let future = iso(size, now, duration, 0, .raw)!
        precondition(!future.sourceAvailable && future.sample != nil)
        // Program may run ahead of the ISO worker. Reading the newer image
        // must not consume the older due receipt needed by that worker.
        _ = render(at: next, program: true)
        let delayed = iso(size, due + CMTime(value: 1, timescale: 60), duration, 1, .raw)!
        precondition(delayed.sourceAvailable && delayed.sample != nil)
        let delayedPixels = CMSampleBufferGetImageBuffer(delayed.sample!)!
        CVPixelBufferLockBaseAddress(delayedPixels, .readOnly)
        let delayedBytes = CVPixelBufferGetBaseAddress(delayedPixels)!.assumingMemoryBound(to: UInt8.self)
        precondition(delayedBytes[90 * CVPixelBufferGetBytesPerRow(delayedPixels) + 160 * 4 + 2] > 240,
                     "A later Program read must preserve the earlier red ISO frame")
        CVPixelBufferUnlockBaseAddress(delayedPixels, .readOnly)
        let raw = iso(size, next, duration, 1, .raw)!
        let processed = iso(size, next, duration, 2, .processed)!
        precondition(raw.sourceAvailable && processed.sourceAvailable)
        let rawPixels = CMSampleBufferGetImageBuffer(raw.sample!)!
        CVPixelBufferLockBaseAddress(rawPixels, .readOnly)
        let rawBytes = CVPixelBufferGetBaseAddress(rawPixels)!.assumingMemoryBound(to: UInt8.self)
        precondition(rawBytes[90 * CVPixelBufferGetBytesPerRow(rawPixels) + 160 * 4] > 240)
        CVPixelBufferUnlockBaseAddress(rawPixels, .readOnly)
        store.allowProgram(false, lease: lease)
        precondition(!iso(size, next, duration, 3, .raw)!.sourceAvailable, "Backstage media must not enter guest ISO")
        store.allowProgram(true, lease: lease)
        let successor = GuestReceiveLease(slot: lease.slot, peerID: UUID(), negotiation: UUID(), generation: 2)
        precondition(store.register(successor))
        store.allowProgram(true, lease: successor)
        precondition(store.receive(.init(lease: successor, role: .camera, pixels: pixels(red: 0, green: 255, blue: 0),
                                        pts: next, duration: .invalid, mappingGeneration: UUID(), clockQuality: .senderReportAligned), arrival: now))
        precondition(!iso(size, next, duration, 4, .raw)!.sourceAvailable, "An ISO must not adopt a replacement peer")
        precondition(color(render(at: next, program: true)).1 > 240)
        store.retire()
        precondition(color(render(at: next, program: false)).2 < 5)
        try await controllerAdmission()
        print("Guest renderer: old document defaults, stable slot/role persistence, exact registered source, future-frame withholding, backstage/Program gate, dynamic nested pixels and runtime retirement PASS")
        print("Qualification: actual Core Image raster and raw/processed generation-pinned ISO source workers from generated CoreVideo receipts; codec transport and combined Program/ISO AV decode remain separate")
    }
}
