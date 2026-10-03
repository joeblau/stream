import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import StreamCore

private enum GuestSlotsFailure: Error { case failed(String) }
private func require(_ value: Bool, _ reason: String) throws {
    if !value { throw GuestSlotsFailure.failed(reason) }
}

@main @MainActor enum GuestSlotsHarness {
    static func color(_ pixels: CVPixelBuffer, x: Int = 24, y: Int = 24) -> [Int] {
        CVPixelBufferLockBaseAddress(pixels, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let row = CVPixelBufferGetBytesPerRow(pixels), p = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let offset = y * row + x * 4
        return [Int(p[offset + 2]), Int(p[offset + 1]), Int(p[offset])]
    }
    static func solid(_ rgb: [Int]) -> CVPixelBuffer {
        var output: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, nil, &output) == noErr)
        let pixels = output!
        CVPixelBufferLockBaseAddress(pixels, []); defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let row = CVPixelBufferGetBytesPerRow(pixels), p = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<180 { for x in 0..<320 {
            let i = y * row + x * 4; p[i] = UInt8(rgb[2]); p[i + 1] = UInt8(rgb[1]); p[i + 2] = UInt8(rgb[0]); p[i + 3] = 255
        } }
        return pixels
    }
    static func fingerprint(_ pixels: CVPixelBuffer) -> UInt64 {
        CVPixelBufferLockBaseAddress(pixels, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        var value: UInt64 = 1_469_598_103_934_665_603
        for i in 0..<(CVPixelBufferGetBytesPerRow(pixels) * CVPixelBufferGetHeight(pixels)) { value = (value ^ UInt64(p[i])) &* 1_099_511_628_211 }
        return value
    }
    static func encodeDecode(_ frames: [CVPixelBuffer], to url: URL) async throws -> [[Int]] {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        writer.add(input)
        try require(writer.startWriting(), "Actual H264 writer failed to start")
        writer.startSession(atSourceTime: .zero)
        for (index, pixels) in frames.enumerated() {
            let deadline = ContinuousClock.now + .seconds(5)
            while !input.isReadyForMoreMediaData && writer.status == .writing && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
            try require(input.isReadyForMoreMediaData, "H264 append readiness deadline")
            try require(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(index), timescale: 30)), "H264 append refused")
        }
        input.markAsFinished(); await writer.finishWriting()
        try require(writer.status == .completed, "Actual H264 finalization failed")
        let asset = AVURLAsset(url: url), track = try await asset.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); try require(reader.startReading(), "Actual H264 decoder failed to start")
        var result: [[Int]] = []
        while let sample = output.copyNextSampleBuffer() { result.append(color(CMSampleBufferGetImageBuffer(sample)!)) }
        try require(reader.status == .completed && result.count == frames.count, "Actual H264 decoded count mismatch")
        return result
    }
    static func main() async {
        do { try await run() }
        catch { print("FAIL: \(error)"); exit(1) }
    }
    static func run() async throws {
        setbuf(stdout, nil)
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let directory = root.appendingPathComponent("Project")
        try DesktopStorage.prepare(directory)
        let store = SceneStore(directory: directory), preview = PreviewProgramModel(selected: nil), mixer = AudioMixEngine()
        let controller = StreamController(sceneStore: store, previewProgram: preview, permissions: PermissionsManager(), audioEngine: mixer)
        let settings = SettingsSession(store: DesktopSettingsStore(directory: directory), controller: controller)
        let suite = "stream.fixture.guest-slots.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = RecordingController(defaults: defaults, defaultDirectory: root.appendingPathComponent("Recordings"))
        let dispatcher = StudioCommandDispatcher(controller: controller, sceneStore: store, session: settings, recorder: recorder, previewProgram: preview)
        let peer = UUID()
        var slot = store.createGuestSlot(name: "Saved Interview Position")!
        slot.cameraPlaceholder.colorHex = "#00FF00"; slot.cameraPlaceholder.message = ""; slot.title = "Engineer"
        store.replaceGuestSlot(slot)
        try require(store.assignGuest(peer, to: slot.id, displayName: "Ada"), "Explicit public peer assignment failed")
        _ = store.createGuestSlot(name: "Prepared position 2"); _ = store.createGuestSlot(name: "Prepared position 3")
        slot = store.guestSlots.first!
        let sources = store.sources.filter { if case .guest = $0.payload { return true }; return false }
        try require(sources.count == 6 && Set(sources.map(\.id)).count == 6, "Pre-arrival camera/screen sources are not distinct")
        var templates: [Scene] = []
        for template in GuestSceneTemplate.allCases {
            let scene = template.scene(slots: store.guestSlots, sources: store.sources, hostCamera: nil)!
            try require(scene.layers.contains { if case .guest = $0.payload { return true }; return false }, "Layout has no ordinary guest layers")
            try require(dispatcher.execute(.insertScene(scene)).error == nil, "Shipping dispatcher refused template")
            try require(dispatcher.execute(.take).error == nil, "Shipping Take refused template")
            templates.append(scene)
        }
        var solo = templates.first!
        try require(dispatcher.execute(.selectScene(solo.id)).error == nil, "Template selection failed")
        solo.layers[0].transform.size.width = 0.8
        try require(dispatcher.execute(.updateScene(solo)).error == nil, "Template layer is not editable")
        try require(preview.programScene?.layers[0].transform.size.width == 0.75, "Preview edit changed the prior screen layout")
        try require(dispatcher.execute(.take).error == nil && preview.programScene?.layers[0].transform.size.width == 0.8,
                    "Take did not publish ordinary layer transform")
        solo.layers[0].transform = .fullscreen
        let renderer = SceneRenderer(usesSoftwareRendering: true)
        func render(_ scene: Scene, at pts: CMTime, program: Bool, scenes: [SceneID: Scene] = [:]) -> CVPixelBuffer {
            let lookup = SourceFrameLookup(camera: { _ in nil }, screen: { _ in nil }, guest: { payload, time in
                guard let id = payload.slotID else { return nil }
                return controller.guestVideoFrames.pixels(slot: id, role: payload.role == .camera ? .camera : .screen, at: time, program: program)
            })
            return renderer.render(scene: scene, overlayContext: .empty, canvasSize: .init(width: 320, height: 180), frames: lookup,
                sourcePayloads: Dictionary(uniqueKeysWithValues: store.sources.map { ($0.id, $0.payload) }), scenes: scenes,
                presentationTime: pts, frameDuration: .init(value: 1, timescale: 30), sequence: 0)!.pixelBuffer!
        }
        let now = CMClockGetTime(CMClockGetHostTimeClock()), due = now + CMTime(value: 960, timescale: 48_000)
        // Generated colors use the renderer's existing Core Graphics color
        // conversion. Compare the card with an independent ordinary shape,
        // rather than assuming device RGB equals encoded canvas RGB.
        let reference = Scene(name: "Configured card color", layers: [LayerNode(name: "Reference", payload: .shape(.init(fillColorHex: "#00FF00")), transform: .fullscreen)])
        let cardRGB = color(render(reference, at: now, program: true))
        try require(cardRGB[1] > 240 && cardRGB[0] < 5 && cardRGB[2] < 5, "Ordinary configured shape did not render green")
        let offline = render(solo, at: now, program: true)
        try require(color(offline) == cardRGB, "Configured offline card differs from the ordinary shape color contract")
        let lease = GuestReceiveLease(slot: slot.id, peerID: peer, negotiation: UUID(), generation: 1), mapping = UUID()
        let admitted = await controller.registerGuestMedia(lease, name: "Ada")
        try require(admitted && store.sources.filter { if case .guest = $0.payload { return true }; return false }.map(\.id) == sources.map(\.id),
                    "Admission replaced prepared source identities")
        controller.receiveGuestVideo(.init(lease: lease, role: .camera, pixels: solid([255, 0, 0]), pts: due, duration: .invalid,
                                          mappingGeneration: mapping, clockQuality: .senderReportAligned))
        try require(color(render(solo, at: due, program: false)) == [255, 0, 0], "Preview did not receive prepared camera")
        try require(color(render(solo, at: due, program: true)) == cardRGB, "Backstage pixels bypassed Program placeholder")
        try require(controller.setGuestMediaRouting(lease, programAllowed: true, monitorAllowed: false), "Actual controller Program grant failed")
        let onair = render(solo, at: due, program: true)
        try require(color(onair) == [255, 0, 0], "Bound camera did not render Program")
        controller.setGuestScreenEnabled(true, lease: lease)
        controller.receiveGuestVideo(.init(lease: lease, role: .screen, pixels: solid([0, 0, 255]), pts: due, duration: .invalid,
                                          mappingGeneration: mapping, clockQuality: .senderReportAligned))
        for (template, scene) in zip(GuestSceneTemplate.allCases, templates) {
            let pixels = render(scene, at: due, program: true)
            switch template {
            case .solo, .grid: try require(color(pixels) == [255, 0, 0], "Guest solo/grid position did not render bound camera")
            case .sideBySide: try require(color(pixels, x: 240, y: 70) == [255, 0, 0], "Side-by-side position did not render camera")
            case .pip: try require(color(pixels, x: 260, y: 125) == [255, 0, 0], "PIP position did not render camera")
            case .screenAndGuests:
                try require(color(pixels, x: 24, y: 30) == [0, 0, 255] && color(pixels, x: 280, y: 25) == [255, 0, 0],
                            "Screen-plus-guests did not preserve distinct camera/screen identities")
            }
        }
        let other = GuestReceiveLease(slot: store.guestSlots[1].id, peerID: UUID(), negotiation: UUID(), generation: 2)
        let second = await controller.registerGuestMedia(other, name: "Second")
        try require(!second, "Configured offline positions widened actual one-peer capacity")
        let caption = solo.layers.first { if case .text(let text) = $0.payload { return text.guestBinding?.field == .name }; return false }!
        let title = solo.layers.first { if case .text(let text) = $0.payload { return text.guestBinding?.field == .title }; return false }!
        let names = Scene(name: "Names", layers: [caption, title]), nested = Scene(name: "Nested Names", layers: [
            LayerNode(name: "Name Scene", payload: .scene(.init(sceneID: names.id)), transform: .fullscreen)])
        func literalMetadata(_ name: String, _ title: String) -> UInt64 {
            var literal = names
            for index in literal.layers.indices {
                if case .text(var text) = literal.layers[index].payload, let binding = text.guestBinding {
                    text.guestBinding = nil; text.text = binding.field == .name ? name : title
                    literal.layers[index].payload = .text(text)
                }
            }
            return fingerprint(render(nested, at: due, program: true, scenes: [literal.id: literal]))
        }
        let before = fingerprint(render(nested, at: due, program: true, scenes: [names.id: names]))
        try require(before == literalMetadata("Ada", "Engineer"), "Typed metadata pixels do not equal the independent literal caption raster")
        var metadata = store.guestSlots[0]; metadata.title = "Admiral"
        store.replaceGuestSlot(metadata)
        let changedTitle = fingerprint(render(nested, at: due, program: true, scenes: [names.id: names]))
        try require(before != changedTitle, "Bound title in a nested scene reused stale cached pixels")
        try require(changedTitle == literalMetadata("Ada", "Admiral"), "Title binding resolved the wrong metadata field")
        metadata.displayName = "Grace Hopper"
        store.replaceGuestSlot(metadata)
        let after = fingerprint(render(nested, at: due, program: true, scenes: [names.id: names]))
        try require(changedTitle != after, "Bound name in a nested scene reused stale cached pixels")
        try require(after == literalMetadata("Grace Hopper", "Admiral"), "Name binding resolved the wrong slot metadata")
        controller.removeGuestMedia(lease)
        let lost = render(solo, at: due, program: true)
        try require(color(lost) == cardRGB, "Source loss did not restore configured card")
        controller.receiveGuestVideo(.init(lease: lease, role: .camera, pixels: solid([0, 0, 255]), pts: due, duration: .invalid,
                                          mappingGeneration: mapping, clockQuality: .senderReportAligned))
        try require(color(render(solo, at: due, program: false)) == cardRGB, "Retired lease restored old pixels")
        store.flushPendingWrites(); settings.flushPendingWrites()
        let savedIDs = store.sources.map(\.id), savedSlots = store.guestSlots
        let persisted = try Data(contentsOf: directory.appendingPathComponent("stream.scenes.v2.json"))
        let reopened = SceneStore(directory: directory)
        try require(reopened.guestSlots == savedSlots && reopened.sources.map(\.id) == savedIDs, "Real project reload changed slot/source metadata or IDs")
        try require(reopened.guestSlots.first(where: { $0.reconnectPeerID == peer })?.id == slot.id, "Reload lost saved public reconnect identity")
        let newController = StreamController(sceneStore: reopened, previewProgram: .init(selected: reopened.selected), permissions: PermissionsManager())
        let rejoin = GuestReceiveLease(slot: slot.id, peerID: peer, negotiation: UUID(), generation: 1)
        let restored = await newController.registerGuestMedia(rejoin, name: "Grace Hopper")
        try require(restored && reopened.sources.map(\.id) == savedIDs, "Fresh runtime rejoin replaced prepared source IDs")
        let legacy = try JSONSerialization.jsonObject(with: persisted) as! [String: Any]
        var old = legacy; old["guestSlots"] = nil
        let decoded = try JSONDecoder().decode(SceneDocument.self, from: JSONSerialization.data(withJSONObject: old))
        try require(decoded.guestSlots.isEmpty, "Older document did not decode additive slot default")
        let legacyDirectory = root.appendingPathComponent("LegacyProject")
        try DesktopStorage.prepare(legacyDirectory)
        try JSONSerialization.data(withJSONObject: old).write(to: legacyDirectory.appendingPathComponent("stream.scenes.v2.json"))
        let migrated = SceneStore(directory: legacyDirectory)
        try require(migrated.guestSlots.map(\.id) == savedSlots.map(\.id) && migrated.sources.map(\.id) == savedIDs,
                    "Actual older project load did not derive slots from existing stable source UUIDs")
        var remapping: [String: String] = [:]
        let imported = try JSONDecoder().decode(SceneDocument.self, from: PortableShow.redact(persisted, remappingIDs: true, idMap: &remapping))
        let mapped = imported.guestSlots.first!
        try require(mapped.id != slot.id && mapped.resolvedName == "Grace Hopper", "Portable import did not remap slot while preserving public name")
        try require(imported.sources.contains { if case .guest(let p) = $0.payload { return p.slotID == mapped.id }; return false }, "Portable import broke source-slot reference")
        try require(imported.scenes.flatMap(\.layers).contains { if case .text(let p) = $0.payload { return p.guestBinding?.slotID == mapped.id }; return false }, "Portable import broke typed caption-slot reference")
        let decodedPixels = try await encodeDecode([offline, onair, lost], to: root.appendingPathComponent("slot-lifecycle.mov"))
        for (actual, expected) in zip(decodedPixels, [cardRGB, [255, 0, 0], cardRGB]) {
            try require(zip(actual, expected).allSatisfy { abs($0 - $1) <= 5 }, "Actual H264 decoded lifecycle pixels \(actual) differ from renderer \(expected)")
        }
        var capacity = reopened.guestSlots.count
        while reopened.createGuestSlot() != nil { capacity += 1 }
        try require(capacity == 16 && reopened.createGuestSlot() == nil, "Saved slot catalogue is unbounded")
        newController.retireGuestMedia(); controller.retireGuestMedia()
        print("PASS: actual persisted slot/source IDs, five editable templates/Take, configured offline/Program pixels, dynamic nested metadata, old lease rejection, project reload/rejoin, portable reference remapping, H264 decoded lifecycle and one-peer/capped-slot limits")
        print("Artifacts: \(root.path); synthetic registered receipts qualify scene software, not browser/relay/return-feed/device support")
    }
}
