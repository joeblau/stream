import Foundation

/// G11 (issue #117): the platform-neutral model behind the macOS studio's
/// presentation annotations — pen/highlighter strokes and the laser pointer
/// presenters draw over the live canvas.
///
/// **Geometry.** Stroke points are normalized 0…1 canvas coordinates with a
/// top-left origin — the same space `LayerTransform` uses — so a stroke
/// renders identically at any output resolution. Stroke widths are authored
/// in 1080p-REFERENCE pixels and scale with the render height (the text
/// `fontSize` precedent), so a pen line looks the same at 720p and 4K.
///
/// **Scope.** Annotations are keyed by the scene's stable UUID string but are
/// deliberately NOT scene-document content: they live in their own additive
/// document (`stream.annotations.v1.json`, the soundboard-document
/// precedent), so they survive scene edits, Take/Revert, and the S12 undo
/// snapshot without entangling them. Per-scene `isVisible` /
/// `includeInProgram` ride the same document and apply immediately to both
/// monitors (the S07 project-overlay precedent), never staged.
///
/// **Program gating.** Whether annotations are part of the program output is
/// an EXPLICIT per-scene choice: `SceneAnnotations.includeInProgram`. Only
/// `programStrokes` — visible AND program-included — may reach the
/// compositor; everything else is preview-monitor chrome.
public enum AnnotationTool: String, Codable, CaseIterable, Sendable {
    case pen
    case highlighter
    case pointer

    public var displayName: String {
        switch self {
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .pointer: return "Pointer"
        }
    }

    /// Pen and highlighter leave persistent strokes; the pointer is a
    /// transient laser dot that never commits anything to the document.
    public var leavesStroke: Bool {
        self != .pointer
    }
}

/// One normalized canvas point (0…1, top-left origin).
public struct AnnotationPoint: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// Drags may overshoot the canvas edge slightly; clamp into the canvas
    /// so a committed stroke never carries off-canvas geometry.
    public var clampedToCanvas: AnnotationPoint {
        AnnotationPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
    }
}

/// One committed pen/highlighter stroke.
public struct AnnotationStroke: Identifiable, Hashable, Codable, Sendable {
    /// Bound on one drag's captured points — a stroke that never ends can't
    /// grow the document without limit.
    public static let maxPointCount = 4096
    /// Stroke widths in 1080p-reference pixels (scaled by render height).
    public static let widthRange = 1.0...64.0

    public var id: UUID
    /// Always `.pen` or `.highlighter` — the pointer never leaves a stroke.
    public var tool: AnnotationTool
    public var colorHex: String
    public var width: Double
    public var points: [AnnotationPoint]

    public init(id: UUID = UUID(),
                tool: AnnotationTool,
                colorHex: String,
                width: Double,
                points: [AnnotationPoint]) {
        self.id = id
        self.tool = tool
        self.colorHex = colorHex
        self.width = width
        self.points = points
    }

    /// The rejection reason for an unacceptable stroke (guards automation
    /// input; the canvas UI already produces valid strokes). Nil when valid.
    public var validationError: String? {
        guard tool.leavesStroke else {
            return "The pointer never leaves a stroke."
        }
        guard points.count >= 2 else {
            return "A stroke needs at least two points."
        }
        guard points.count <= Self.maxPointCount else {
            return "A stroke can hold at most \(Self.maxPointCount) points."
        }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            return "Stroke points must be finite numbers."
        }
        guard width.isFinite, Self.widthRange.contains(width) else {
            return "Stroke width must be between \(Int(Self.widthRange.lowerBound)) and \(Int(Self.widthRange.upperBound))."
        }
        return nil
    }
}

/// Everything annotated on one scene: the committed strokes (in drawing
/// order, back to front), whether they show in the studio at all, and the
/// explicit choice of whether they are part of the program output.
public struct SceneAnnotations: Hashable, Codable, Sendable {
    public var strokes: [AnnotationStroke]
    /// Per-scene visibility: hidden annotations stay in the document but
    /// paint nowhere — not the preview chrome, not the program output.
    public var isVisible: Bool
    /// The explicit "annotations are part of program" choice. Off by
    /// default: a fresh scene's annotations are preview-only telestrator
    /// marks until the presenter deliberately broadcasts them.
    public var includeInProgram: Bool

    public init(strokes: [AnnotationStroke] = [],
                isVisible: Bool = true,
                includeInProgram: Bool = false) {
        self.strokes = strokes
        self.isVisible = isVisible
        self.includeInProgram = includeInProgram
    }

    /// The strokes the PROGRAM compositor may paint: visible AND explicitly
    /// program-included. The one gate every render path must read.
    public var programStrokes: [AnnotationStroke] {
        isVisible && includeInProgram ? strokes : []
    }

    /// Decode with per-field defaults so documents written before later
    /// refinements keep loading (the established additive-wire pattern).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        strokes = try container.decodeIfPresent([AnnotationStroke].self, forKey: .strokes) ?? []
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        includeInProgram = try container.decodeIfPresent(Bool.self, forKey: .includeInProgram) ?? false
    }
}

/// The persisted annotation document: per-scene annotation sets keyed by the
/// scene's stable UUID string (plain strings keep the wire format stable and
/// diff-friendly, the `GraphID` encoding precedent).
public struct AnnotationDocument: Hashable, Codable, Sendable {
    public var scenes: [String: SceneAnnotations]

    public init(scenes: [String: SceneAnnotations] = [:]) {
        self.scenes = scenes
    }
}

/// The stroke-level undo/redo behind the acceptance criterion's "clear/undo"
/// (G11). Snapshot-based per scene — one entry per DISCRETE edit (a committed
/// stroke, a clear), not per captured mouse point, so undoing removes exactly
/// one gesture. This is deliberately separate from the S12 scene undo stack:
/// strokes are ephemeral presentation marks drawn during a live show, not
/// scene document content, so they keep their own history (and their own
/// hotkeys) instead of interleaving with scene-edit undo.
public struct AnnotationHistory: Equatable, Sendable {
    private var undoSnapshots: [[AnnotationStroke]] = []
    private var redoSnapshots: [[AnnotationStroke]] = []

    /// Bound on memory: entries are value copies of one scene's stroke list.
    public let limit: Int

    public init(limit: Int = 64) {
        self.limit = limit
    }

    public var canUndo: Bool { !undoSnapshots.isEmpty }
    public var canRedo: Bool { !redoSnapshots.isEmpty }

    /// Records one executed stroke edit. No-ops (before == after) never reach
    /// the stack; a new edit clears the redo stack (a new branch invalidates
    /// the undone future).
    public mutating func record(before: [AnnotationStroke], after: [AnnotationStroke]) {
        guard before != after else { return }
        undoSnapshots.append(before)
        if undoSnapshots.count > limit {
            undoSnapshots.removeFirst()
        }
        redoSnapshots.removeAll()
    }

    /// Pops the most recent edit, returning the stroke array undo restores
    /// (its pre-edit snapshot); the current array moves to the redo stack.
    public mutating func undo(current: [AnnotationStroke]) -> [AnnotationStroke]? {
        guard let snapshot = undoSnapshots.popLast() else { return nil }
        redoSnapshots.append(current)
        return snapshot
    }

    /// Re-applies the most recently undone edit, returning the stroke array
    /// redo restores; the current array moves back to the undo stack.
    public mutating func redo(current: [AnnotationStroke]) -> [AnnotationStroke]? {
        guard let snapshot = redoSnapshots.popLast() else { return nil }
        undoSnapshots.append(current)
        return snapshot
    }
}
