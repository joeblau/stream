import AppKit
import SwiftUI
import StreamCore

// MARK: - Canvas geometry (S04, issue #72)
//
// Pure normalized/canvas-point math shared by hit-testing, snapping, and the
// selection chrome. Canvas coordinates are top-left-origin POINTS on the
// active profile's canvas (e.g. 1920×1080) — the exact inverse of the
// renderer's `rectInCanvas` mapping, so what the user grabs is what the
// engine paints.

enum CanvasGeometry {
    /// The layer point `position` refers to, as a 0…1 fraction in
    /// top-left-origin layer space (same mapping as the renderer).
    static func anchorFraction(_ anchor: LayerAnchor) -> CGPoint {
        switch anchor {
        case .topLeft: return CGPoint(x: 0, y: 0)
        case .topRight: return CGPoint(x: 1, y: 0)
        case .bottomLeft: return CGPoint(x: 0, y: 1)
        case .bottomRight: return CGPoint(x: 1, y: 1)
        case .center: return CGPoint(x: 0.5, y: 0.5)
        }
    }

    /// The transform's UNROTATED rect in canvas points (top-left origin).
    static func rect(for transform: LayerTransform, canvas: CGSize) -> CGRect {
        let anchor = anchorFraction(transform.anchor)
        let width = transform.size.width * canvas.width
        let height = transform.size.height * canvas.height
        return CGRect(x: transform.position.x * canvas.width - anchor.x * width,
                      y: transform.position.y * canvas.height - anchor.y * height,
                      width: width, height: height)
    }

    /// Rotates a point by `degrees` around a center, clockwise in
    /// top-left-origin space — matching the renderer's rotation semantics.
    static func rotated(_ point: CGPoint, around center: CGPoint, degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        let dx = point.x - center.x
        let dy = point.y - center.y
        let cosine = cos(radians)
        let sine = sin(radians)
        return CGPoint(x: center.x + dx * cosine - dy * sine,
                       y: center.y + dx * sine + dy * cosine)
    }

    /// A direction vector rotated by `degrees` (no center).
    static func rotatedVector(_ vector: CGSize, degrees: Double) -> CGSize {
        let radians = degrees * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        return CGSize(width: vector.width * cosine - vector.height * sine,
                      height: vector.width * sine + vector.height * cosine)
    }

    /// The layer's four corners in canvas points, order tl/tr/br/bl of the
    /// UNROTATED rect, each mapped through the layer's rotation.
    static func corners(of rect: CGRect, degrees: Double) -> [CGPoint] {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return [CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.maxY)]
            .map { rotated($0, around: center, degrees: degrees) }
    }

    /// G03 (issue #106): the layer's corners with STYLING accounted for —
    /// the perspective tilt projects the rect's corners (matching the
    /// renderer's `CIPerspectiveTransform` quad exactly) and the S04 rotation
    /// then maps the projected quad, the same order the renderer applies
    /// them. Shadows are decorative and excluded; borders stroke inside the
    /// rect, so neither changes the bounds. Identity perspective = the plain
    /// rotated corners.
    static func styledCorners(of rect: CGRect, degrees: Double,
                              perspective: LayerPerspective) -> [CGPoint] {
        guard !perspective.isIdentity else { return corners(of: rect, degrees: degrees) }
        let projected = perspective.projectedCorners(of: rect)
        let quad = [projected.topLeft, projected.topRight,
                    projected.bottomRight, projected.bottomLeft]
        guard degrees != 0 else { return quad }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return quad.map { rotated($0, around: center, degrees: degrees) }
    }

    /// Point-in-quad test for a convex quad (the perspective projection
    /// stays convex across the clamped ±80° range), corners in tl/tr/br/bl
    /// order.
    static func quadContains(_ point: CGPoint, _ corners: [CGPoint]) -> Bool {
        guard corners.count == 4 else { return false }
        var positive = false
        var negative = false
        for index in 0..<4 {
            let a = corners[index]
            let b = corners[(index + 1) % 4]
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            if cross > 0 { positive = true } else if cross < 0 { negative = true }
            if positive && negative { return false }
        }
        return true
    }

    /// Point-in-layer test honoring rotation and G03 perspective styling.
    static func contains(_ point: CGPoint, layer: LayerNode, canvas: CGSize) -> Bool {
        let rect = rect(for: layer.transform, canvas: canvas)
        let perspective = layer.style.perspective
        if !perspective.isIdentity {
            return quadContains(point, styledCorners(of: rect,
                                                     degrees: layer.transform.rotationDegrees,
                                                     perspective: perspective))
        }
        guard layer.transform.rotationDegrees != 0 else { return rect.contains(point) }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let local = rotated(point, around: center, degrees: -layer.transform.rotationDegrees)
        return rect.contains(local)
    }

    /// The topmost visible layer at a canvas point. `layers` is back-to-front,
    /// so the frontmost match is the LAST one.
    static func hitTest(_ point: CGPoint, in scene: Scene, canvas: CGSize) -> LayerNode? {
        for layer in scene.layers.reversed() where layer.isVisible {
            if contains(point, layer: layer, canvas: canvas) { return layer }
        }
        return nil
    }

    /// The axis-aligned bounding box of layers' STYLED corners (rotation +
    /// G03 perspective) — the selection bounds the chrome and snapping use.
    static func boundingRect(of layers: [LayerNode], canvas: CGSize) -> CGRect {
        layers.reduce(CGRect.null) { bounds, layer in
            let rect = rect(for: layer.transform, canvas: canvas)
            return styledCorners(of: rect, degrees: layer.transform.rotationDegrees,
                                 perspective: layer.style.perspective)
                .reduce(bounds) { $0.union(CGRect(origin: $1, size: .zero)) }
        }
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}

// MARK: - Snapping

/// Snap guides to draw while dragging, in canvas points. Vertical guides are
/// X positions, horizontal guides are Y positions; each spans the full canvas.
struct CanvasSnapGuides: Equatable {
    var vertical: [CGFloat] = []
    var horizontal: [CGFloat] = []

    static let none = CanvasSnapGuides()
}

enum CanvasSnapping {
    /// Snaps a translating selection bounds to the canvas center/edges and to
    /// every other layer's edges/centers. Returns the extra offset to apply on
    /// top of the raw drag delta, plus the guide lines that fired. The single
    /// best line wins per axis (all moving edges shift together).
    static func snap(bounds: CGRect,
                     canvas: CGSize,
                     others: [CGRect],
                     threshold: CGFloat) -> (offset: CGSize, guides: CanvasSnapGuides) {
        let xLines: [CGFloat] = [0, canvas.width / 2, canvas.width]
            + others.flatMap { [$0.minX, $0.midX, $0.maxX] }
        let yLines: [CGFloat] = [0, canvas.height / 2, canvas.height]
            + others.flatMap { [$0.minY, $0.midY, $0.maxY] }
        var offset = CGSize.zero
        var guides = CanvasSnapGuides()
        if let best = bestSnap(moving: [bounds.minX, bounds.midX, bounds.maxX],
                               lines: xLines, threshold: threshold) {
            offset.width = best.delta
            guides.vertical = best.lines
        }
        if let best = bestSnap(moving: [bounds.minY, bounds.midY, bounds.maxY],
                               lines: yLines, threshold: threshold) {
            offset.height = best.delta
            guides.horizontal = best.lines
        }
        return (offset, guides)
    }

    /// The smallest |delta| that lands any moving edge on any line within the
    /// threshold, plus every line an edge lands on once that delta applies.
    private static func bestSnap(moving: [CGFloat],
                                 lines: [CGFloat],
                                 threshold: CGFloat) -> (delta: CGFloat, lines: [CGFloat])? {
        var best: (delta: CGFloat, line: CGFloat)?
        for edge in moving {
            for line in lines {
                let delta = line - edge
                if abs(delta) <= threshold, abs(delta) < abs(best?.delta ?? .greatestFiniteMagnitude) {
                    best = (delta, line)
                }
            }
        }
        guard let best else { return nil }
        var fired: Set<CGFloat> = []
        for edge in moving {
            for line in lines where abs(line - edge - best.delta) < 0.5 {
                fired.insert(line)
            }
        }
        return (best.delta, fired.sorted())
    }
}

// MARK: - Canvas interaction view

/// The S04 direct-manipulation surface (issue #72), overlaid on the PREVIEW
/// monitor's fitted image rect. Everything here is preview-only chrome drawn
/// in SwiftUI — selection outlines, handles, marquee, and snap guides NEVER
/// touch the engine's composed frames, so they can't leak into program, the
/// recording, or the encoded output.
///
/// - Click selects the topmost visible layer; ⇧-click toggles membership;
///   dragging empty canvas rubber-bands a marquee multi-select. Selection is
///   the shared `SceneStore.selectedLayerIDs`, so the layer panel and the
///   canvas always highlight the same layers.
/// - Dragging a selected layer moves the whole EDITABLE selection (locked
///   layers/groups stay put); corner/edge handles resize a single selection
///   (⇧ locks aspect); the knob above rotates it (⇧ snaps to 15°).
/// - Moves snap to the canvas center/edges and other layers' edges/centers
///   with visible guides; holding ⌘ disables snapping for that drag, and the
///   threshold is configurable (context menu).
/// - Arrow keys nudge the editable selection by 1 canvas pixel (⇧ = 10).
///
/// Every edit goes through the dispatcher as `.setLayerTransform`, so locks,
/// staging, Take/Revert, and direct-live behave exactly like panel edits.
///
/// G11 (issue #117): while an annotation tool is active (pen / highlighter /
/// laser pointer), the drag gesture draws instead — strokes commit through
/// `.addAnnotationStroke` on mouse-up and the pointer tracks hover. Committed
/// strokes, the in-progress stroke, and the pointer dot draw as the same
/// preview-only chrome (see `annotationChrome`); whether they also reach
/// program is the explicit per-scene choice rendered by `AnnotationRenderer`.
struct CanvasInteractionView: View {
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher
    @EnvironmentObject private var previewProgram: PreviewProgramModel
    @EnvironmentObject private var sceneStore: SceneStore

    /// The monitor's fitted image rect in local coordinates (from PreviewView).
    let imageRect: CGRect
    /// The pixel canvas the PREVIEW engine renders at (the active profile).
    let canvasSize: CGSize
    var canvas: OutputCanvas = .program

    private var editingScene: Scene? { previewProgram.stagedScene.map { $0.composition(for: canvas) } }

    @AppStorage("studio.canvasSnappingEnabled") private var snappingEnabled = true
    /// Snap distance in VIEW points (resolution-independent for the user).
    @AppStorage("studio.canvasSnapThreshold") private var snapThreshold = 8.0
    @AppStorage("studio.canvasShowSafeMargins") private var showSafeMargins = false

    @FocusState private var isFocused: Bool

    @State private var session: DragSession?
    @State private var marqueeRect: CGRect?
    @State private var snapGuides = CanvasSnapGuides.none
    /// G11 (issue #117): the in-flight pen/highlighter drag, in normalized
    /// canvas points (committed as one stroke on mouse-up).
    @State private var inProgressStroke: [AnnotationPoint] = []

    private enum Handle: Equatable {
        /// Click/drag on a layer body (or a selection-only click: locked or ⇧).
        case move
        /// 0=tl 1=tr 2=br 3=bl, indices into the unrotated corner order.
        case resize(corner: Int)
        /// 0=top 1=right 2=bottom 3=left of the unrotated rect.
        case resizeEdge(Int)
        case rotate
        case marquee
        /// Selection was already handled on mouse-down; the session exists
        /// only to detect click-vs-drag.
        case selectionOnly
    }

    private struct DragSession {
        var handle: Handle
        let startPoint: CGPoint                 // canvas points
        let startTransforms: [LayerID: LayerTransform]
        let startBounds: CGRect                 // rotated AABB of the editable selection
        let startRect: CGRect                   // single layer's unrotated rect (resize/rotate)
        let rotationCenter: CGPoint
        let marqueeBase: Set<LayerID>           // ⇧ marquee adds to this
        let clickTarget: LayerID?
        let clickWasSelected: Bool
        var moved = false
    }

    private let handleViewSize: CGFloat = 8

    var body: some View {
        ZStack {
            if isLive {
                if canvas == .program { annotationChrome }
                safeMarginsChrome
                selectionChrome
                marqueeChrome
                snapGuideChrome
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged(dragChanged)
                .onEnded(dragEnded)
        )
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down, action: keyPressed)
        .contextMenu {
            if canvas == .program { canvasContextMenu }
            else {
                Button("Follow Program Geometry") { linkSelectedGeometry() }
            }
        }
        .onContinuousHover(coordinateSpace: .local, perform: hoverChanged)
    }

    /// Interactive only while a scene is staged and the monitor has an image.
    private var isLive: Bool {
        editingScene != nil && imageRect.width > 1 && imageRect.height > 1
            && canvasSize.width > 1 && canvasSize.height > 1
    }

    // MARK: G11 annotation input state

    /// The active annotation tool, mirrored from the dispatcher's published
    /// state (nil = normal selection mode). Reading `dispatcher.state` keeps
    /// the overlay reactive.
    private var annotationTool: AnnotationTool? {
        canvas == .program ? dispatcher.state.annotations.activeTool : nil
    }

    private var annotations: AnnotationStore { dispatcher.annotations }

    // MARK: Coordinate conversion (view points ↔ canvas points)

    private func canvasPoint(_ viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: (viewPoint.x - imageRect.minX) * canvasSize.width / imageRect.width,
                y: (viewPoint.y - imageRect.minY) * canvasSize.height / imageRect.height)
    }

    private func viewPoint(_ canvasPoint: CGPoint) -> CGPoint {
        CGPoint(x: imageRect.minX + canvasPoint.x * imageRect.width / canvasSize.width,
                y: imageRect.minY + canvasPoint.y * imageRect.height / canvasSize.height)
    }

    /// One VIEW point expressed in canvas points (hit tolerances, knob offset).
    private var canvasPointsPerViewPoint: CGFloat {
        canvasSize.width / imageRect.width
    }

    // MARK: Selection helpers

    private func editableSelection(_ scene: Scene) -> [LayerNode] {
        scene.layers.filter {
            sceneStore.selectedLayerIDs.contains($0.id) && !scene.isEffectivelyLocked($0)
        }
    }

    /// Visible layers whose unrotated frame intersects the marquee.
    private func layers(in rect: CGRect, scene: Scene) -> Set<LayerID> {
        Set(scene.layers.filter {
            $0.isVisible && CanvasGeometry.rect(for: $0.transform, canvas: canvasSize).intersects(rect)
        }.map(\.id))
    }

    private func sendTransform(_ id: LayerID, _ transform: LayerTransform) {
        if canvas == .program { dispatcher.execute(.setLayerTransform(id, transform, in: nil)); return }
        guard let original = previewProgram.stagedScene, var layout = original.secondaryCanvas,
              let layer = editingScene?.layers.first(where: { $0.id == id }) else { return }
        layout.placements[id] = .init(transform: transform, isVisible: layer.isVisible)
        dispatcher.execute(.setSecondaryCanvas(layout, in: original.id))
    }

    private func linkSelectedGeometry() {
        guard let original = previewProgram.stagedScene, var layout = original.secondaryCanvas else { return }
        for id in sceneStore.selectedLayerIDs { layout.placements[id] = nil }
        dispatcher.execute(.setSecondaryCanvas(layout, in: original.id))
    }

    // MARK: Gesture handling

    private func dragChanged(_ value: DragGesture.Value) {
        guard isLive else { return }
        // G11: an active annotation tool owns the drag — selection, marquee,
        // and handles stay out of the way while drawing/pointing.
        if let tool = annotationTool {
            annotationDragChanged(value, tool: tool)
            return
        }
        if session == nil {
            session = beginSession(at: canvasPoint(value.startLocation))
        }
        guard session != nil else { return }
        updateSession(to: canvasPoint(value.location))
    }

    private func dragEnded(_ value: DragGesture.Value) {
        if let tool = annotationTool {
            annotationDragEnded(tool)
            return
        }
        defer {
            session = nil
            marqueeRect = nil
            snapGuides = .none
        }
        guard let session, !session.moved,
              let target = session.clickTarget, session.clickWasSelected else { return }
        // A plain click on an already-selected layer collapses the selection
        // to it (standard canvas behavior); drags keep the multi-selection.
        sceneStore.selectedLayerIDs = [target]
    }

    // MARK: G11 annotation drawing (issue #117)

    /// A pen/highlighter drag accumulates the stroke; a pointer drag moves
    /// the laser dot. Points are normalized canvas coordinates, clamped into
    /// the canvas on commit.
    private func annotationDragChanged(_ value: DragGesture.Value, tool: AnnotationTool) {
        guard let scene = editingScene else { return }
        if tool.leavesStroke {
            if inProgressStroke.isEmpty {
                inProgressStroke = [normalizedPoint(value.startLocation)]
            }
            if inProgressStroke.count < AnnotationStroke.maxPointCount {
                inProgressStroke.append(normalizedPoint(value.location))
            }
        } else {
            annotations.updatePointer(sceneID: scene.id, point: normalizedPoint(value.location))
        }
    }

    /// Mouse-up commits the accumulated stroke through the dispatcher (one
    /// command = one undoable stroke edit). A click without a drag commits
    /// nothing — a stroke needs at least two points.
    private func annotationDragEnded(_ tool: AnnotationTool) {
        defer { inProgressStroke = [] }
        guard tool.leavesStroke, inProgressStroke.count >= 2 else { return }
        let stroke = AnnotationStroke(tool: tool,
                                      colorHex: annotations.colorHex,
                                      width: annotations.strokeWidth(for: tool),
                                      points: inProgressStroke.map { $0.clampedToCanvas })
        dispatcher.execute(.addAnnotationStroke(stroke, in: nil))
    }

    /// Laser-pointer hover tracking: the dot follows the mouse over the
    /// canvas while the pointer tool is active and clears when it leaves.
    private func hoverChanged(_ phase: HoverPhase) {
        guard annotationTool == .pointer, isLive,
              let scene = editingScene else { return }
        switch phase {
        case .active(let location):
            annotations.updatePointer(sceneID: scene.id, point: normalizedPoint(location))
        case .ended:
            annotations.clearPointer()
        }
    }

    private func normalizedPoint(_ viewPoint: CGPoint) -> AnnotationPoint {
        let canvas = canvasPoint(viewPoint)
        return AnnotationPoint(x: Double(canvas.x / canvasSize.width),
                               y: Double(canvas.y / canvasSize.height))
    }

    /// Mouse-down: resolve what the press grabbed — a selection handle, a
    /// layer, or empty canvas (marquee) — and capture the drag's start state.
    private func beginSession(at start: CGPoint) -> DragSession? {
        guard let scene = editingScene else { return nil }
        let modifiers = NSEvent.modifierFlags
        let shift = modifiers.contains(.shift)
        let tolerance = 10 * canvasPointsPerViewPoint

        // 1. Selection chrome (rotate knob, resize handles) wins over bodies.
        if let handle = chromeHandle(at: start, tolerance: tolerance, scene: scene) {
            let editable = editableSelection(scene)
            guard !editable.isEmpty else { return nil }
            return DragSession(
                handle: handle,
                startPoint: start,
                startTransforms: Dictionary(uniqueKeysWithValues: editable.map { ($0.id, $0.transform) }),
                startBounds: CanvasGeometry.boundingRect(of: editable, canvas: canvasSize),
                startRect: editable.count == 1
                    ? CanvasGeometry.rect(for: editable[0].transform, canvas: canvasSize) : .zero,
                rotationCenter: rotationCenter(for: editable),
                marqueeBase: [],
                clickTarget: nil,
                clickWasSelected: false)
        }

        // 2. A layer body: select it (⇧ toggles) and start a move when editable.
        if let layer = CanvasGeometry.hitTest(start, in: scene, canvas: canvasSize) {
            let wasSelected = sceneStore.selectedLayerIDs.contains(layer.id)
            if shift {
                if wasSelected {
                    sceneStore.selectedLayerIDs.remove(layer.id)
                } else {
                    sceneStore.selectedLayerIDs.insert(layer.id)
                }
                return DragSession(handle: .selectionOnly, startPoint: start,
                                   startTransforms: [:], startBounds: .zero, startRect: .zero,
                                   rotationCenter: .zero, marqueeBase: [],
                                   clickTarget: nil, clickWasSelected: false)
            }
            if !wasSelected {
                sceneStore.selectedLayerIDs = [layer.id]
            }
            let editable = editableSelection(scene)
            guard !editable.isEmpty else {
                // Locked (directly or via its group): selectable, not movable.
                return DragSession(handle: .selectionOnly, startPoint: start,
                                   startTransforms: [:], startBounds: .zero, startRect: .zero,
                                   rotationCenter: .zero, marqueeBase: [],
                                   clickTarget: layer.id, clickWasSelected: wasSelected)
            }
            return DragSession(
                handle: .move,
                startPoint: start,
                startTransforms: Dictionary(uniqueKeysWithValues: editable.map { ($0.id, $0.transform) }),
                startBounds: CanvasGeometry.boundingRect(of: editable, canvas: canvasSize),
                startRect: .zero,
                rotationCenter: rotationCenter(for: editable),
                marqueeBase: [],
                clickTarget: layer.id,
                clickWasSelected: wasSelected)
        }

        // 3. Empty canvas: rubber-band multi-select (⇧ adds to the selection).
        if !shift {
            sceneStore.selectedLayerIDs = []
        }
        return DragSession(handle: .marquee, startPoint: start,
                           startTransforms: [:], startBounds: .zero, startRect: .zero,
                           rotationCenter: .zero,
                           marqueeBase: shift ? sceneStore.selectedLayerIDs : [],
                           clickTarget: nil, clickWasSelected: false)
    }

    private func updateSession(to point: CGPoint) {
        guard var current = session, let scene = editingScene else { return }
        if !current.moved,
           CanvasGeometry.distance(point, current.startPoint) > 2 * canvasPointsPerViewPoint {
            current.moved = true
        }
        session = current

        switch current.handle {
        case .move:
            moveSelection(in: current, to: point, scene: scene)
        case .resize(let corner):
            resizeSingleLayer(in: current, corner: corner, edge: nil, to: point)
        case .resizeEdge(let edge):
            resizeSingleLayer(in: current, corner: nil, edge: edge, to: point)
        case .rotate:
            rotateSelection(in: current, to: point)
        case .marquee:
            let rect = CGRect(origin: current.startPoint, size: .zero)
                .union(CGRect(origin: point, size: .zero))
            marqueeRect = rect
            sceneStore.selectedLayerIDs = current.marqueeBase.union(layers(in: rect, scene: scene))
        case .selectionOnly:
            break
        }
    }

    // MARK: Move (with snapping)

    private func moveSelection(in session: DragSession, to point: CGPoint, scene: Scene) {
        var delta = CGSize(width: point.x - session.startPoint.x,
                           height: point.y - session.startPoint.y)
        let movingIDs = Set(session.startTransforms.keys)
        if snappingEnabled && !NSEvent.modifierFlags.contains(.command) {
            let moved = session.startBounds.offsetBy(dx: delta.width, dy: delta.height)
            let others = scene.layers
                .filter { $0.isVisible && !movingIDs.contains($0.id) }
                .map { CanvasGeometry.rect(for: $0.transform, canvas: canvasSize) }
            let snap = CanvasSnapping.snap(bounds: moved, canvas: canvasSize, others: others,
                                           threshold: snapThreshold * canvasPointsPerViewPoint)
            delta.width += snap.offset.width
            delta.height += snap.offset.height
            snapGuides = snap.guides
        } else {
            snapGuides = .none
        }
        for (layerID, start) in session.startTransforms {
            var transform = start
            transform.position = GraphPoint(
                x: start.position.x + Double(delta.width / canvasSize.width),
                y: start.position.y + Double(delta.height / canvasSize.height))
            sendTransform(layerID, transform)
        }
    }

    // MARK: Resize (single selection)

    /// Resizes one layer by a corner or edge of its UNROTATED rect, keeping
    /// the opposite corner/edge visually fixed under the layer's rotation.
    /// ⇧ locks the aspect ratio (corner handles).
    private func resizeSingleLayer(in session: DragSession,
                                   corner: Int?,
                                   edge: Int?,
                                   to point: CGPoint) {
        guard let (layerID, start) = session.startTransforms.first else { return }
        let rotation = start.rotationDegrees
        let localDelta = CanvasGeometry.rotatedVector(
            CGSize(width: point.x - session.startPoint.x, height: point.y - session.startPoint.y),
            degrees: -rotation)
        let original = session.startRect
        var resized = original

        if let corner {
            // Move the dragged corner; the opposite corner is fixed.
            switch corner {
            case 0:
                resized.origin.x += localDelta.width
                resized.origin.y += localDelta.height
                resized.size.width -= localDelta.width
                resized.size.height -= localDelta.height
            case 1:
                resized.origin.y += localDelta.height
                resized.size.width += localDelta.width
                resized.size.height -= localDelta.height
            case 2:
                resized.size.width += localDelta.width
                resized.size.height += localDelta.height
            default:
                resized.origin.x += localDelta.width
                resized.size.width -= localDelta.width
                resized.size.height += localDelta.height
            }
        } else if let edge {
            switch edge {
            case 0:
                resized.origin.y += localDelta.height
                resized.size.height -= localDelta.height
            case 1:
                resized.size.width += localDelta.width
            case 2:
                resized.size.height += localDelta.height
            default:
                resized.origin.x += localDelta.width
                resized.size.width -= localDelta.width
            }
        }

        let minimum = 4.0   // canvas points — never invert a layer
        resized.size.width = max(minimum, resized.size.width)
        resized.size.height = max(minimum, resized.size.height)

        if corner != nil, NSEvent.modifierFlags.contains(.shift),
           original.width > 0, original.height > 0 {
            let scale = max(resized.width / original.width, resized.height / original.height)
            resized.size = CGSize(width: original.width * scale, height: original.height * scale)
        }

        // Re-anchor the resized rect so the FIXED point (opposite corner or
        // opposite edge midpoint) stays where it was on the rotated canvas.
        let fixedLocal = fixedPoint(of: original, corner: corner, edge: edge)
        let fixedCanvas = CanvasGeometry.rotated(
            fixedLocal, around: CGPoint(x: original.midX, y: original.midY), degrees: rotation)
        let newFixedLocal = fixedPoint(of: resized, corner: corner, edge: edge)
        let newFixedCanvas = CanvasGeometry.rotated(
            newFixedLocal, around: CGPoint(x: resized.midX, y: resized.midY), degrees: rotation)
        resized.origin.x += fixedCanvas.x - newFixedCanvas.x
        resized.origin.y += fixedCanvas.y - newFixedCanvas.y

        let anchor = CanvasGeometry.anchorFraction(start.anchor)
        let anchorLocal = CGPoint(x: resized.minX + anchor.x * resized.width,
                                  y: resized.minY + anchor.y * resized.height)
        let anchorCanvas = CanvasGeometry.rotated(
            anchorLocal, around: CGPoint(x: resized.midX, y: resized.midY), degrees: rotation)

        var transform = start
        transform.size = GraphSize(width: Double(resized.width / canvasSize.width),
                                   height: Double(resized.height / canvasSize.height))
        transform.position = GraphPoint(x: Double(anchorCanvas.x / canvasSize.width),
                                        y: Double(anchorCanvas.y / canvasSize.height))
        sendTransform(layerID, transform)
    }

    /// The unrotated-rect point that stays fixed during a resize.
    private func fixedPoint(of rect: CGRect, corner: Int?, edge: Int?) -> CGPoint {
        if let corner {
            switch corner {
            case 0: return CGPoint(x: rect.maxX, y: rect.maxY)
            case 1: return CGPoint(x: rect.minX, y: rect.maxY)
            case 2: return CGPoint(x: rect.minX, y: rect.minY)
            default: return CGPoint(x: rect.maxX, y: rect.minY)
            }
        }
        switch edge ?? 0 {
        case 0: return CGPoint(x: rect.midX, y: rect.maxY)
        case 1: return CGPoint(x: rect.minX, y: rect.midY)
        case 2: return CGPoint(x: rect.midX, y: rect.minY)
        default: return CGPoint(x: rect.maxX, y: rect.midY)
        }
    }

    // MARK: Rotate

    private func rotateSelection(in session: DragSession, to point: CGPoint) {
        let center = session.rotationCenter
        let startAngle = atan2(session.startPoint.y - center.y, session.startPoint.x - center.x)
        let angle = atan2(point.y - center.y, point.x - center.x)
        let deltaDegrees = Double(angle - startAngle) * 180 / .pi
        let snapTo15 = NSEvent.modifierFlags.contains(.shift)
        for (layerID, start) in session.startTransforms {
            var transform = start
            var degrees = start.rotationDegrees + deltaDegrees
            if snapTo15 {
                degrees = (degrees / 15).rounded() * 15
            }
            transform.rotationDegrees = degrees
            sendTransform(layerID, transform)
        }
    }

    private func rotationCenter(for layers: [LayerNode]) -> CGPoint {
        if layers.count == 1, let layer = layers.first {
            let rect = CanvasGeometry.rect(for: layer.transform, canvas: canvasSize)
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        let bounds = CanvasGeometry.boundingRect(of: layers, canvas: canvasSize)
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    // MARK: Keyboard nudging

    /// Arrow keys: 1 canvas pixel, ⇧ = 10 — in the active profile's canvas
    /// pixels, so a nudge means the same thing at any window size.
    private func keyPressed(_ press: KeyPress) -> KeyPress.Result {
        // G11: Escape leaves the drawing tool and returns to selection mode.
        if press.key == .escape, annotationTool != nil {
            dispatcher.execute(.setAnnotationTool(nil))
            return .handled
        }
        guard let scene = editingScene else { return .ignored }
        let step = press.modifiers.contains(.shift) ? 10.0 : 1.0
        let delta: CGSize
        switch press.key {
        case .upArrow: delta = CGSize(width: 0, height: -step)
        case .downArrow: delta = CGSize(width: 0, height: step)
        case .leftArrow: delta = CGSize(width: -step, height: 0)
        case .rightArrow: delta = CGSize(width: step, height: 0)
        default: return .ignored
        }
        let editable = editableSelection(scene)
        guard !editable.isEmpty else { return .ignored }
        for layer in editable {
            var transform = layer.transform
            transform.position = GraphPoint(
                x: transform.position.x + Double(delta.width / canvasSize.width),
                y: transform.position.y + Double(delta.height / canvasSize.height))
            sendTransform(layer.id, transform)
        }
        return .handled
    }

    // MARK: Handle hit-testing

    /// The selection-chrome handle at a canvas point, if any. Priority:
    /// rotate knob → corners → edges. Resize handles exist only for a single
    /// editable selection; multi-selections get move + rotate.
    private func chromeHandle(at point: CGPoint, tolerance: CGFloat, scene: Scene) -> Handle? {
        let editable = editableSelection(scene)
        guard !editable.isEmpty else { return nil }

        if editable.count == 1, let layer = editable.first {
            let rect = CanvasGeometry.rect(for: layer.transform, canvas: canvasSize)
            let corners = CanvasGeometry.styledCorners(of: rect,
                                                       degrees: layer.transform.rotationDegrees,
                                                       perspective: layer.style.perspective)
            let topMid = CanvasGeometry.midpoint(corners[0], corners[1])
            let bottomMid = CanvasGeometry.midpoint(corners[3], corners[2])
            let up = unitVector(from: bottomMid, to: topMid)
            let knob = CGPoint(x: topMid.x + up.x * 24 * canvasPointsPerViewPoint,
                               y: topMid.y + up.y * 24 * canvasPointsPerViewPoint)
            if CanvasGeometry.distance(point, knob) <= tolerance * 1.5 { return .rotate }
            for (index, corner) in corners.enumerated()
            where CanvasGeometry.distance(point, corner) <= tolerance {
                return .resize(corner: index)
            }
            let edgeMidpoints = [
                CanvasGeometry.midpoint(corners[0], corners[1]),
                CanvasGeometry.midpoint(corners[1], corners[2]),
                CanvasGeometry.midpoint(corners[2], corners[3]),
                CanvasGeometry.midpoint(corners[3], corners[0])
            ]
            for (index, midpoint) in edgeMidpoints.enumerated()
            where CanvasGeometry.distance(point, midpoint) <= tolerance {
                return .resizeEdge(index)
            }
        } else {
            let bounds = CanvasGeometry.boundingRect(of: editable, canvas: canvasSize)
            let knob = CGPoint(x: bounds.midX, y: bounds.minY - 24 * canvasPointsPerViewPoint)
            if CanvasGeometry.distance(point, knob) <= tolerance * 1.5 { return .rotate }
        }
        return nil
    }

    private func unitVector(from: CGPoint, to: CGPoint) -> CGPoint {
        let length = CanvasGeometry.distance(from, to)
        guard length > 0 else { return CGPoint(x: 0, y: -1) }
        return CGPoint(x: (to.x - from.x) / length, y: (to.y - from.y) / length)
    }

    // MARK: Chrome (preview-only — never in the composed output)

    @ViewBuilder
    private var selectionChrome: some View {
        if let scene = editingScene {
            let selected = scene.layers.filter { sceneStore.selectedLayerIDs.contains($0.id) && $0.isVisible }
            let editable = editableSelection(scene)
            ForEach(selected) { layer in
                let rect = CanvasGeometry.rect(for: layer.transform, canvas: canvasSize)
                let corners = CanvasGeometry.styledCorners(of: rect,
                                                           degrees: layer.transform.rotationDegrees,
                                                           perspective: layer.style.perspective)
                    .map(viewPoint)
                Path { path in
                    path.addLines(corners)
                    path.closeSubpath()
                }
                .stroke(editable.contains(where: { $0.id == layer.id })
                        ? Color.accentColor : Color.gray, lineWidth: 1.5)
            }
            if editable.count == 1, let layer = editable.first {
                singleSelectionHandles(layer)
            } else if editable.count > 1 {
                multiSelectionRotateKnob(editable)
            }
        }
    }

    /// Corner + edge handles and the rotate knob for one selected layer.
    /// Handles sit on the STYLED (perspective-projected) corners so they
    /// track what the user sees; the resize math itself edits the underlying
    /// unprojected rect (G03 styling never rewrites the transform).
    @ViewBuilder
    private func singleSelectionHandles(_ layer: LayerNode) -> some View {
        let rect = CanvasGeometry.rect(for: layer.transform, canvas: canvasSize)
        let corners = CanvasGeometry.styledCorners(of: rect,
                                                   degrees: layer.transform.rotationDegrees,
                                                   perspective: layer.style.perspective)
        let points = corners + [
            CanvasGeometry.midpoint(corners[0], corners[1]),
            CanvasGeometry.midpoint(corners[1], corners[2]),
            CanvasGeometry.midpoint(corners[2], corners[3]),
            CanvasGeometry.midpoint(corners[3], corners[0])
        ]
        ForEach(Array(points.enumerated()), id: \.offset) { _, point in
            handleSquare(at: viewPoint(point))
        }
        let topMid = CanvasGeometry.midpoint(corners[0], corners[1])
        let bottomMid = CanvasGeometry.midpoint(corners[3], corners[2])
        let up = unitVector(from: bottomMid, to: topMid)
        rotateKnob(at: viewPoint(CGPoint(x: topMid.x + up.x * 24 * canvasPointsPerViewPoint,
                                         y: topMid.y + up.y * 24 * canvasPointsPerViewPoint)),
                   tetheredTo: viewPoint(topMid))
    }

    @ViewBuilder
    private func multiSelectionRotateKnob(_ editable: [LayerNode]) -> some View {
        let bounds = CanvasGeometry.boundingRect(of: editable, canvas: canvasSize)
        let topMid = CGPoint(x: bounds.midX, y: bounds.minY)
        rotateKnob(at: viewPoint(CGPoint(x: topMid.x, y: topMid.y - 24 * canvasPointsPerViewPoint)),
                   tetheredTo: viewPoint(topMid))
    }

    private func handleSquare(at center: CGPoint) -> some View {
        Rectangle()
            .fill(Color.white)
            .frame(width: handleViewSize, height: handleViewSize)
            .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
            .position(center)
    }

    private func rotateKnob(at center: CGPoint, tetheredTo anchor: CGPoint) -> some View {
        ZStack {
            Path { path in
                path.move(to: anchor)
                path.addLine(to: center)
            }
            .stroke(Color.accentColor, lineWidth: 1)
            Circle()
                .fill(Color.white)
                .frame(width: handleViewSize, height: handleViewSize)
                .overlay(Circle().stroke(Color.accentColor, lineWidth: 1))
                .position(center)
        }
    }

    @ViewBuilder
    private var marqueeChrome: some View {
        if let marqueeRect {
            let rect = CGRect(origin: viewPoint(CGPoint(x: marqueeRect.minX, y: marqueeRect.minY)),
                              size: CGSize(width: marqueeRect.width * imageRect.width / canvasSize.width,
                                           height: marqueeRect.height * imageRect.height / canvasSize.height))
            Rectangle()
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: rect.width, height: rect.height)
                .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                .position(x: rect.midX, y: rect.midY)
        }
    }

    @ViewBuilder
    private var snapGuideChrome: some View {
        ForEach(snapGuides.vertical, id: \.self) { x in
            Path { path in
                path.move(to: viewPoint(CGPoint(x: x, y: 0)))
                path.addLine(to: viewPoint(CGPoint(x: x, y: canvasSize.height)))
            }
            .stroke(Color.yellow, lineWidth: 1)
        }
        ForEach(snapGuides.horizontal, id: \.self) { y in
            Path { path in
                path.move(to: viewPoint(CGPoint(x: 0, y: y)))
                path.addLine(to: viewPoint(CGPoint(x: canvasSize.width, y: y)))
            }
            .stroke(Color.yellow, lineWidth: 1)
        }
    }

    /// Optional action-safe (90%) and title-safe (80%) margins — chrome only.
    @ViewBuilder
    private var safeMarginsChrome: some View {
        if showSafeMargins {
            ForEach([0.05, 0.10], id: \.self) { inset in
                Rectangle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .frame(width: imageRect.width * (1 - 2 * inset),
                           height: imageRect.height * (1 - 2 * inset))
                    .position(x: imageRect.midX, y: imageRect.midY)
            }
        }
    }

    // MARK: G11 annotation chrome (preview-only — the program path is AnnotationRenderer)
    //
    // Committed strokes, the in-progress stroke, and the laser pointer draw
    // here in SwiftUI over the PREVIEW monitor image — alongside the S04
    // selection chrome and under the same guarantee: none of it touches the
    // engine's composed frames. When a scene's annotations are explicitly
    // program-included, the PROGRAM engine composites them through
    // `AnnotationRenderer.composite` (fed by `ProgramAnnotationStore`); the
    // preview engine is wired with an empty annotation provider so the
    // strokes draw here exactly once, never doubled.

    @ViewBuilder
    private var annotationChrome: some View {
        if let scene = editingScene {
            let uiState = dispatcher.state.annotations
            let sceneAnnotations = annotations.annotations(for: scene.id)
            if sceneAnnotations.isVisible {
                ForEach(sceneAnnotations.strokes) { stroke in
                    strokeChrome(points: stroke.points, colorHex: stroke.colorHex,
                                 width: stroke.width, tool: stroke.tool)
                }
            }
            if inProgressStroke.count > 1, let tool = uiState.activeTool, tool.leavesStroke {
                strokeChrome(points: inProgressStroke, colorHex: uiState.colorHex,
                             width: tool == .highlighter
                                 ? uiState.highlighterWidth : uiState.penWidth,
                             tool: tool)
            }
            if uiState.activeTool == .pointer, sceneAnnotations.isVisible,
               let pointer = uiState.pointer, pointer.sceneID == scene.id {
                pointerChrome(at: pointer.point)
            }
        }
    }

    /// One stroke as a SwiftUI path in view coordinates: normalized canvas
    /// points mapped through the same view transform the selection chrome
    /// uses; the width (1080p-reference pixels) scales with the VIEW height,
    /// exactly the renderer's scale mapped into view space — what you draw
    /// is what `AnnotationRenderer` composites.
    @ViewBuilder
    private func strokeChrome(points: [AnnotationPoint], colorHex: String,
                              width: Double, tool: AnnotationTool) -> some View {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: viewPoint(for: first))
            for point in points.dropFirst() {
                path.addLine(to: viewPoint(for: point))
            }
        }
        .stroke(annotationColor(colorHex, tool: tool),
                style: StrokeStyle(lineWidth: viewStrokeWidth(width),
                                   lineCap: .round, lineJoin: .round))
    }

    private func pointerChrome(at point: AnnotationPoint) -> some View {
        let center = viewPoint(for: point)
        let scale = imageRect.height / 1080
        return ZStack {
            Circle()
                .fill(Color.red.opacity(0.30))
                .frame(width: 32 * scale, height: 32 * scale)
            Circle()
                .fill(Color.red.opacity(0.95))
                .frame(width: 10 * scale, height: 10 * scale)
                .overlay(Circle().stroke(Color.white.opacity(0.9),
                                         lineWidth: max(1, 1.5 * scale)))
        }
        .position(center)
        .allowsHitTesting(false)
    }

    private func viewPoint(for point: AnnotationPoint) -> CGPoint {
        viewPoint(CGPoint(x: CGFloat(point.x) * canvasSize.width,
                          y: CGFloat(point.y) * canvasSize.height))
    }

    private func viewStrokeWidth(_ referenceWidth: Double) -> CGFloat {
        CGFloat(referenceWidth) * imageRect.height / 1080
    }

    private func annotationColor(_ hex: String, tool: AnnotationTool) -> Color {
        let components = HexColor.components(hex)
        return Color(.sRGB, red: components.red, green: components.green,
                     blue: components.blue,
                     opacity: components.alpha * (tool == .highlighter ? 0.45 : 1))
    }

    // MARK: Context menu (alignment, distribute, snapping options)

    @ViewBuilder
    private var canvasContextMenu: some View {
        let selectionCount = sceneStore.selectedLayerIDs.count
        if selectionCount >= 2 {
            Menu("Align") {
                alignButton("Left", .left)
                alignButton("Horizontal Center", .horizontalCenter)
                alignButton("Right", .right)
                Divider()
                alignButton("Top", .top)
                alignButton("Vertical Center", .verticalCenter)
                alignButton("Bottom", .bottom)
            }
            if selectionCount >= 3 {
                Menu("Distribute") {
                    distributeButton("Horizontally", .horizontal)
                    distributeButton("Vertically", .vertical)
                }
            }
            Divider()
        }
        Toggle("Snap to Guides", isOn: $snappingEnabled)
        Menu("Snap Threshold") {
            ForEach([4.0, 8.0, 12.0, 16.0, 24.0], id: \.self) { value in
                Button {
                    snapThreshold = value
                } label: {
                    if snapThreshold == value {
                        Label("\(Int(value)) pt", systemImage: "checkmark")
                    } else {
                        Text("\(Int(value)) pt")
                    }
                }
            }
        }
        Toggle("Show Safe Margins", isOn: $showSafeMargins)
    }

    private func alignButton(_ title: String, _ alignment: LayerAlignment) -> some View {
        Button(title) { dispatcher.execute(.alignLayers(alignment, in: nil)) }
            .disabled(!dispatcher.canExecute(.alignLayers(alignment, in: nil)))
    }

    private func distributeButton(_ title: String, _ distribution: LayerDistribution) -> some View {
        Button(title) { dispatcher.execute(.distributeLayers(distribution, in: nil)) }
            .disabled(!dispatcher.canExecute(.distributeLayers(distribution, in: nil)))
    }
}
