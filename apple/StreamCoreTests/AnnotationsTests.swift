import Foundation
import Testing
@testable import StreamCore

/// G11 (issue #117): the stroke model, per-scene program gating, document
/// persistence shape, and the stroke-level undo/redo history behind the
/// studio's presentation annotations.
@Suite("G11 annotation model")
struct AnnotationsTests {
    private func stroke(_ id: String = UUID().uuidString,
                        points: Int = 3) -> AnnotationStroke {
        AnnotationStroke(tool: .pen, colorHex: "#FF3B30", width: 6,
                         points: (0..<points).map {
                             AnnotationPoint(x: Double($0) / 10, y: Double($0) / 10)
                         })
    }

    @Test("Pointer never leaves a stroke; pen and highlighter do")
    func toolStrokeSemantics() {
        #expect(!AnnotationTool.pointer.leavesStroke)
        #expect(AnnotationTool.pen.leavesStroke)
        #expect(AnnotationTool.highlighter.leavesStroke)
    }

    @Test("Stroke validation guards automation input")
    func strokeValidation() {
        #expect(stroke().validationError == nil)
        #expect(AnnotationStroke(tool: .pointer, colorHex: "#FFF", width: 6,
                                 points: [AnnotationPoint(x: 0, y: 0),
                                          AnnotationPoint(x: 1, y: 1)]).validationError != nil)
        // Fewer than two points can't draw a line.
        #expect(stroke(points: 1).validationError != nil)
        // Non-finite geometry and out-of-range widths are rejected.
        #expect(AnnotationStroke(tool: .pen, colorHex: "#FFF", width: 6,
                                 points: [AnnotationPoint(x: .nan, y: 0),
                                          AnnotationPoint(x: 1, y: 1)]).validationError != nil)
        #expect(AnnotationStroke(tool: .pen, colorHex: "#FFF", width: 0,
                                 points: [AnnotationPoint(x: 0, y: 0),
                                          AnnotationPoint(x: 1, y: 1)]).validationError != nil)
        #expect(AnnotationStroke(tool: .pen, colorHex: "#FFF", width: 100,
                                 points: [AnnotationPoint(x: 0, y: 0),
                                          AnnotationPoint(x: 1, y: 1)]).validationError != nil)
    }

    @Test("Program strokes require BOTH visible and explicitly program-included")
    func programGating() {
        let marks = [stroke()]
        // The explicit choice defaults off: a fresh scene's annotations are
        // preview-only until the presenter broadcasts them.
        #expect(SceneAnnotations(strokes: marks).programStrokes.isEmpty)
        // Hidden beats included.
        #expect(SceneAnnotations(strokes: marks, isVisible: false,
                                 includeInProgram: true).programStrokes.isEmpty)
        // Visible but not included stays preview-only.
        #expect(SceneAnnotations(strokes: marks, isVisible: true,
                                 includeInProgram: false).programStrokes.isEmpty)
        // Both on: the strokes are part of program.
        #expect(SceneAnnotations(strokes: marks, isVisible: true,
                                 includeInProgram: true).programStrokes == marks)
    }

    @Test("Document round-trips keyed by scene UUID string")
    func documentCodable() throws {
        let key = UUID().uuidString
        let document = AnnotationDocument(scenes: [
            key: SceneAnnotations(strokes: [stroke()], isVisible: false, includeInProgram: true)
        ])
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: data)
        #expect(decoded == document)
        #expect(decoded.scenes[key]?.strokes.count == 1)
    }

    @Test("Scene annotations decode with defaults for older documents")
    func additiveDecoding() throws {
        // A document written before visibility/program flags existed.
        let legacy = """
        {"strokes": []}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SceneAnnotations.self, from: legacy)
        #expect(decoded.isVisible)
        #expect(!decoded.includeInProgram)
    }

    @Test("History undoes one discrete edit at a time and redoes it")
    func historyUndoRedo() {
        var history = AnnotationHistory()
        let one = [stroke()]
        let two = one + [stroke()]
        #expect(!history.canUndo)
        history.record(before: [], after: one)
        history.record(before: one, after: two)
        #expect(history.canUndo)
        #expect(!history.canRedo)
        #expect(history.undo(current: two) == one)
        #expect(history.canRedo)
        #expect(history.redo(current: one) == two)
        #expect(!history.canRedo)
        #expect(history.undo(current: two) == one)
        #expect(history.undo(current: one) == [])
        #expect(!history.canUndo)
    }

    @Test("A new edit clears the redo future; no-ops never record")
    func historyBranching() {
        var history = AnnotationHistory()
        let one = [stroke()]
        history.record(before: [], after: [])
        #expect(!history.canUndo)   // no-op dropped
        history.record(before: [], after: one)
        _ = history.undo(current: one)
        #expect(history.canRedo)
        history.record(before: [], after: [stroke(), stroke()])
        #expect(!history.canRedo)
    }

    @Test("History is bounded")
    func historyLimit() {
        var history = AnnotationHistory(limit: 2)
        for count in 0..<4 {
            history.record(before: Array(repeating: stroke(), count: count),
                           after: Array(repeating: stroke(), count: count + 1))
        }
        // Only the last two edits can be undone.
        #expect(history.undo(current: []) != nil)
        #expect(history.undo(current: []) != nil)
        #expect(!history.canUndo)
    }

    @Test("Points clamp into the canvas on commit")
    func pointClamping() {
        #expect(AnnotationPoint(x: 1.4, y: -0.2).clampedToCanvas == AnnotationPoint(x: 1, y: 0))
        #expect(AnnotationPoint(x: 0.5, y: 0.5).clampedToCanvas == AnnotationPoint(x: 0.5, y: 0.5))
    }
}
