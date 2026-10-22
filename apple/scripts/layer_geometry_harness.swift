import AVFoundation
import Foundation
import StreamCore

private final class GeometryPixels: @unchecked Sendable {
    let buffer: CVPixelBuffer
    init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}

@MainActor
enum LayerGeometryHarness {
    private static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "LayerGeometryHarness", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func run(workspace: StudioWorkspace) async throws {
        let runtime = workspace.runtime, dispatcher = runtime.dispatcher
        let store = runtime.sceneStore, preview = runtime.previewProgram
        let layer = LayerNode(name: "Keyboard geometry shape", payload: .shape(.init()),
                              transform: .init(position: .init(x: 0.123456789123, y: 0.2),
                                               size: .init(width: 0.5, height: 0.4), anchor: .center))
        let other = LayerNode(name: "Other layer", payload: .shape(.init()), transform: .fullscreen)
        let scene = Scene(name: "Geometry scene", layers: [layer, other])
        let second = Scene(name: "Other scene", layers: [layer, other])
        store.scenes = [scene, second]; store.selectedID = scene.id
        store.selectedLayerIDs = [layer.id]
        preview.stage(scene); _ = preview.take()
        let program = preview.programScene
        func current() -> LayerNode { preview.stagedScene!.layers.first { $0.id == layer.id }! }
        func editor() -> LayerGeometryEditor {
            LayerGeometryEditor(workspace: workspace, runtime: runtime, sceneID: scene.id, layer: current())
        }
        let edit = editor()
        edit.draft.values[.width] = "60"
        edit.draft.values[.rotation] = "15"
        try require(current() == layer && preview.programScene == program && !dispatcher.state.canUndo,
                    "Typing geometry mutated scene, Program or undo history")
        let savedDraft = edit.draft
        // Real same-scene publications, analogous to inspector refreshes, must
        // not replace this draft or its stable StateObject-owned presentation.
        for _ in 0..<50 { preview.stage(preview.stagedScene) }
        try require(edit.draft == savedDraft && !edit.isRetired, "Unrelated scene publications lost the draft")
        var live = current(); live.style.opacity = 0.7; live.transform.anchor = .bottomRight
        live.transform.position.y = 0.3; live.name = "Renamed geometry layer"
        var liveScene = preview.stagedScene!; liveScene.layers[0] = live
        preview.applyStagedEdit(liveScene)
        try require(edit.layerName == live.name && edit.anchor == .bottomRight && edit.draft == savedDraft,
                    "Live metadata update lost draft or retained stale operation name")
        // Adjacent drag→Apply→Apply: no sleeps and no undo-history reset.
        var dragged = live.transform; dragged.position.x = 0.35
        dispatcher.execute(.setLayerTransform(layer.id, dragged, in: scene.id))
        try require(edit.apply(), "First explicit Apply failed")
        let applied = current().transform
        try require(applied.size.width == 0.6 && applied.rotationDegrees == 15 && applied.position == dragged.position
                    && applied.anchor == dragged.anchor && current().style == live.style,
                    "Apply lost nonedited transform/style fields")
        edit.draft.values[.height] = "50"
        try require(edit.apply(), "Second explicit Apply failed")
        let appliedTwice = current().transform
        dispatcher.execute(.undo)
        try require(current().transform == applied, "Second Apply merged with first Apply")
        dispatcher.execute(.undo)
        try require(current().transform == dragged, "Apply merged with preceding drag")
        dispatcher.execute(.undo)
        try require(current().transform == live.transform, "Preceding drag undo was lost")
        dispatcher.execute(.redo); dispatcher.execute(.redo); dispatcher.execute(.redo)
        try require(current().transform == appliedTwice && preview.programScene == program
                    && store.selectedLayerIDs == [layer.id] && store.selectedID == scene.id,
                    "Redo/Apply changed Program, scene selection or layer identity")
        let conflict = editor(); conflict.draft.values[.width] = "70"
        var concurrent = current().transform; concurrent.size.width = 0.65
        dispatcher.execute(.setLayerTransform(layer.id, concurrent, in: scene.id))
        try require(!conflict.apply() && current().transform == concurrent && conflict.error != nil,
                    "Draft silently overwrote a newer edit to the same geometry field")
        conflict.reload(); conflict.draft.values[.width] = "70"
        try require(conflict.apply(), "Explicit reload did not recover a conflicted draft")
        let locked = editor(); locked.draft.values[.rotation] = "30"
        dispatcher.execute(.setLayerLocked(layer.id, locked: true, in: scene.id))
        let beforeLockAttempt = current()
        try require(!locked.apply() && current() == beforeLockAttempt, "Numeric Apply bypassed current layer lock")
        dispatcher.execute(.setLayerLocked(layer.id, locked: false, in: scene.id))
        let staleSelection = editor(); staleSelection.draft.values[.rotation] = "45"
        store.selectedLayerIDs = [other.id]; store.selectedLayerIDs = [layer.id]
        try require(staleSelection.isRetired && !staleSelection.apply(), "Selection A→B→A revived old draft authority")
        let staleScene = editor(); staleScene.draft.values[.rotation] = "45"
        let retainedScene = preview.stagedScene!
        preview.stage(second); preview.stage(retainedScene)
        try require(staleScene.isRetired && !staleScene.apply(), "Staged scene A→B→A revived old draft authority")
        try boundaries(current().transform, canvas: dispatcher.state.activeProfile.canvasSize)
        try cameraRendering()
        let profileEdit = editor(); profileEdit.draft.values[.rotation] = "45"
        let originalProfile = dispatcher.state.activeProfile
        runtime.settings.draft.outputProfile = originalProfile.with(canvasWidth: 640, canvasHeight: 360)
        dispatcher.execute(.applySettings)
        try require(dispatcher.state.activeProfile != originalProfile && profileEdit.isRetired && !profileEdit.apply(),
                    "Actual applied output profile replacement did not retire geometry draft")
        let staleRuntime = editor(); staleRuntime.draft.values[.rotation] = "60"
        let oldScene = preview.stagedScene
        workspace.create(named: "Geometry ownership replacement")
        await workspace.applyPending()
        let replacementScene = workspace.runtime.previewProgram.stagedScene
        try require(workspace.runtime !== runtime && staleRuntime.isRetired && !staleRuntime.apply()
                    && preview.stagedScene == oldScene && workspace.runtime.previewProgram.stagedScene == replacementScene,
                    "Actual project switch allowed an old geometry Apply to edit a project")
        try require(!runtime.controller.isPreviewing && !workspace.runtime.controller.isPreviewing,
                    "Geometry fixture activated physical capture")
        print("PASS: shipping geometry draft/editor/dispatcher; no mutation while typing, live refresh preservation, field merge/conflict, drag→Apply→Apply undo/redo, locks, selection/scene/profile/runtime retirement")
    }

    private static func boundaries(_ base: LayerTransform, canvas: CGSize) throws {
        func resolve(_ field: LayerGeometryDraft.Field, _ value: String) -> Result<LayerTransform, LayerGeometryDraft.GeometryError> {
            var draft = LayerGeometryDraft(base); draft.values[field] = value
            return draft.resolved(baseline: base, current: base, canvas: canvas)
        }
        for value in ["", "unfinished-", "nan", "inf", "-inf", "1e309", "0", "-10", "0.00000001"] {
            if case .success = resolve(.width, value) { throw NSError(domain: "GeometryBoundary", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid width accepted: \(value)"]) }
        }
        for (field, value) in [(LayerGeometryDraft.Field.x, "1e307"), (.rotation, "1e308"), (.height, "1e308")] {
            if case .success = resolve(field, value) { throw NSError(domain: "GeometryBoundary", code: 2, userInfo: [NSLocalizedDescriptionKey: "Nonfinite downstream arithmetic accepted"]) }
        }
        var hugeRaster = LayerGeometryDraft(base)
        hugeRaster.values[.width] = "1000000000"; hugeRaster.values[.height] = "1000000000"
        if case .success = hugeRaster.resolved(baseline: base, current: base, canvas: canvas) {
            try require(false, "Individually safe dimensions overflowed renderer width*height*4 accounting")
        }
        var nearCacheOverflow = base
        nearCacheOverflow.size = .init(width: 4 / canvas.width,
                                      height: Double(Int.max / 16 - 2048) / canvas.height)
        let heightPixels = Int((nearCacheOverflow.size.height * canvas.height).rounded(.up))
        let pixelProduct = 4.multipliedReportingOverflow(by: heightPixels)
        let byteProduct = pixelProduct.partialValue.multipliedReportingOverflow(by: 4)
        try require(!pixelProduct.overflow && !byteProduct.overflow
                    && byteProduct.partialValue.addingReportingOverflow(SceneRenderer.generatedCacheByteLimit).overflow,
                    "Cache-addition negative control did not isolate safe product/overflowing sum")
        var cacheDraft = LayerGeometryDraft(nearCacheOverflow); cacheDraft.values[.rotation] = "30"
        if case .success = cacheDraft.resolved(baseline: nearCacheOverflow, current: nearCacheOverflow, canvas: canvas) {
            try require(false, "Safe raster byte count overflowed existing-cache addition")
        }
        if case .success(let value) = resolve(.x, "-25") {
            try require(value.position.x == -0.25, "Off-canvas position was clamped")
        } else { try require(false, "Valid off-canvas position refused") }
        if case .success(let value) = resolve(.width, "150") {
            try require(value.size.width == 1.5, "Enlarged layer was clamped")
        } else { try require(false, "Valid enlarged width refused") }
        var precise = base; precise.position.x = 0.123456789123
        var unchanged = LayerGeometryDraft(precise); unchanged.values[.rotation] = "90"
        if case .success(let value) = unchanged.resolved(baseline: precise, current: precise, canvas: canvas) {
            try require(value.position == precise.position && value.anchor == precise.anchor, "Formatted untouched values lost precision")
            let rect = CanvasGeometry.rect(for: value, canvas: canvas)
            let corners = CanvasGeometry.corners(of: rect, degrees: value.rotationDegrees)
            try require(corners.allSatisfy { $0.x.isFinite && $0.y.isFinite }
                        && CanvasGeometry.midpoint(corners[0], corners[1]).x.isFinite,
                        "Accepted geometry produced nonfinite actual selection chrome")
        } else { try require(false, "Valid rotation refused") }
        print("PASS: actual geometry parsing rejects invalid/overflow/midpoint cases; preserves ordinary off-canvas/enlarged values and untouched precision")
    }

    private static func cameraRendering() throws {
        let base = LayerTransform(position: .init(x: 0.5, y: 0.5), size: .init(width: 0.4, height: 0.9), anchor: .center)
        let canvas = CGSize(width: 320, height: 180)
        func proposal(_ width: String, _ height: String? = nil) -> Result<LayerTransform, LayerGeometryDraft.GeometryError> {
            var draft = LayerGeometryDraft(base); draft.values[.width] = width
            if let height { draft.values[.height] = height }
            return draft.resolved(baseline: base, current: base, canvas: canvas, isCamera: true)
        }
        for width in ["5", "75"] {
            if case .success = proposal(width) { try require(false, "Camera input silently accepted renderer-clamped PIP width") }
        }
        if case .success = proposal("30", "50") { try require(false, "Camera input accepted ignored PIP height") }
        guard case .success(let pip) = proposal("30"), case .success(let box) = proposal("100", "50") else {
            try require(false, "Valid camera PIP/box transition refused"); return
        }
        let buffer = CMSampleBufferGetImageBuffer(try ProgramRecordingFixtures.video(at: 0.5))!
        let pixels = GeometryPixels(buffer)
        let frames = SourceFrameLookup(camera: { _ in .init(buffer: pixels.buffer, position: .back) }, screen: { _ in nil })
        let renderer = SceneRenderer()
        func bounds(_ transform: LayerTransform) throws -> CGSize {
            let layer = LayerNode(name: "Owned synthetic camera", payload: .camera(.init()), transform: transform)
            let scene = Scene(name: "Owned synthetic camera geometry", layers: [layer])
            guard let frame = renderer.render(scene: scene, overlayContext: .empty, canvasSize: canvas, frames: frames,
                sourcePayloads: [:], scenes: [scene.id: scene], presentationTime: .zero,
                frameDuration: CMTime(value: 1, timescale: 30), sequence: 1), let output = frame.pixelBuffer else {
                throw NSError(domain: "GeometryRender", code: 1)
            }
            CVPixelBufferLockBaseAddress(output, .readOnly); defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
            let bytes = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(output)
            var minX = 320, maxX = -1, minY = 180, maxY = -1
            for y in 0..<180 { for x in 0..<320 where bytes[y * stride + x * 4 + 2] > 128 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            } }
            return CGSize(width: maxX - minX + 1, height: maxY - minY + 1)
        }
        let pipBounds = try bounds(pip), boxBounds = try bounds(box)
        try require(abs(pipBounds.width - 96) <= 2 && abs(pipBounds.height - 54) <= 2,
                    "Actual camera PIP did not use width/source-aspect semantics: \(pipBounds)")
        try require(abs(boxBounds.width - 160) <= 2 && abs(boxBounds.height - 90) <= 2,
                    "Actual camera box did not retain source aspect fit: \(boxBounds)")
        print("PASS: actual synthetic SceneRenderer camera PIP \(pipBounds) and ordinary box \(boxBounds), matching disclosed source framing; no device capture")
    }
}
