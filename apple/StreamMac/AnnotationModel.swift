import AppKit
import Combine
import Foundation
import os.lock
import StreamCore

/// G11 (issue #117): the presentation-annotation document, its session state,
/// and the program bridge behind the studio's pen/highlighter/pointer tools.
///
/// **Where annotations live.** Strokes, per-scene visibility, and the
/// per-scene "part of program" choice persist in their own additive document
/// (`stream.annotations.v1.json` in the shared App Group container — the
/// A03 soundboard-document precedent), keyed by the scene's stable `SceneID`.
/// They are NOT scene-document content: the S01 `Scene` graph stays untouched
/// (G02's files), Take/Revert never gates them, and the S12 scene undo stack
/// never sees them (strokes carry their own `AnnotationHistory` per scene —
/// the acceptance criterion's "undo" is stroke-level, not scene-level).
///
/// **What reaches program.** Only `SceneAnnotations.programStrokes` — visible
/// AND explicitly program-included — publish to `ProgramAnnotationStore`, the
/// lock-protected per-tick snapshot every `CompositionEngine` can read (the
/// `ProjectOverlayStore` precedent). The preview overlay draws everything
/// else as SwiftUI chrome, so preview-only telestrator marks and the laser
/// pointer's editor-only states can never leak into the composed output.
///
/// **Editor handles never leak.** Selection outlines, resize handles, snap
/// guides, and the marquee are drawn only by `CanvasInteractionView` in the
/// PREVIEW monitor's SwiftUI overlay (`PreviewView.overlay`) — they are never
/// part of any scene graph the engine composites, by construction.

/// The laser pointer's live position (session state, never persisted):
/// which scene it's over and where, in normalized canvas points.
struct AnnotationPointerState: Equatable, Sendable {
    var sceneID: SceneID
    var point: AnnotationPoint
}

/// The per-tick value the program `CompositionEngine` composites: strokes for
/// scenes whose annotations are visible AND program-included, plus the laser
/// pointer when it rides the same gate. A plain value snapshot, so a mid-tick
/// publish can never tear a frame (the `OverlayContext` precedent).
struct AnnotationRenderSnapshot: Equatable, Sendable {
    /// Program-included strokes, keyed by scene.
    var strokes: [SceneID: [AnnotationStroke]] = [:]
    /// The pointer dot when the presenter broadcasts it (same per-scene gate).
    var pointer: AnnotationPointerState?

    static let empty = AnnotationRenderSnapshot()
}

/// The process-wide hand-off of program-included annotations from
/// `AnnotationStore` (main actor, publishes on every mutation) to the
/// program `CompositionEngine` (its own actor, snapshots each tick) — the
/// exact `ProjectOverlayStore` pattern. Lock-protected value snapshots.
final class ProgramAnnotationStore: @unchecked Sendable {
    static let shared = ProgramAnnotationStore()

    private var lock = os_unfair_lock_s()
    private var snapshotValue = AnnotationRenderSnapshot.empty

    func publish(_ snapshot: AnnotationRenderSnapshot) {
        os_unfair_lock_lock(&lock)
        self.snapshotValue = snapshot
        os_unfair_lock_unlock(&lock)
    }

    func snapshot() -> AnnotationRenderSnapshot {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return snapshotValue
    }
}

/// The annotation surface state the command menus and toolbar mirror (folded
/// into `StudioState` so the app-shell command menus and the toolbar rebuild
/// on change — nested `ObservableObject`s don't invalidate views through the
/// dispatcher's own `@Published`).
struct AnnotationUIState: Equatable, Sendable {
    /// The active drawing tool; nil = normal canvas selection mode.
    var activeTool: AnnotationTool?
    /// Session drawing settings (new-stroke color and per-tool widths).
    var colorHex = "#FF3B30"
    var penWidth = 6.0
    var highlighterWidth = 28.0
    /// Staged-scene summary, for labels and enablement.
    var stagedStrokeCount = 0
    var stagedVisible = true
    var stagedInProgram = false
    var stagedCanUndo = false
    var stagedCanRedo = false
    /// The laser pointer's live position (session state) — the preview
    /// chrome reads it here so pointer motion repaints through the
    /// dispatcher's published state.
    var pointer: AnnotationPointerState?

    static let empty = AnnotationUIState()
}

/// The annotation document + session state. Owned by the
/// `StudioCommandDispatcher` (the soundboard pair precedent) so the toolbar,
/// the canvas overlay, the command menu, and future automation share one
/// instance; every mutation routes through a `StudioCommand`.
@MainActor
final class AnnotationStore: ObservableObject {
    /// The persisted document (per-scene strokes + visibility + program gate).
    @Published private(set) var document: AnnotationDocument {
        didSet {
            scheduleAutosave()
            publishRenderSnapshot()
        }
    }

    // MARK: Session state (never persisted)

    /// The active drawing tool; nil = the canvas is in normal selection mode.
    @Published var activeTool: AnnotationTool? {
        didSet { publishRenderSnapshot() }
    }
    /// The color new pen/highlighter strokes commit with.
    @Published var colorHex = "#FF3B30"
    /// Per-tool widths in 1080p-reference pixels (remembered separately — a
    /// highlighter is meaningfully wider than a pen).
    @Published var penWidth = 6.0
    @Published var highlighterWidth = 28.0
    /// The laser pointer's live position, while the pointer tool tracks the
    /// mouse over the preview canvas.
    @Published private(set) var pointer: AnnotationPointerState? {
        didSet { publishRenderSnapshot() }
    }

    /// Stroke-level undo/redo per scene (session state — undo history of a
    /// live show's telestrator marks is not document content).
    private var histories: [SceneID: AnnotationHistory] = [:]

    /// The palette the toolbar offers (vivid on-camera colors).
    static let palette = ["#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#0A84FF", "#FFFFFF"]

    private static let fileName = "stream.annotations.v1.json"
    private static let autosaveDelay: TimeInterval = 0.75

    private var autosaveTask: Task<Void, Never>?
    /// `nonisolated(unsafe)` so `deinit` can unregister it (the store lives
    /// for the app's lifetime; this is belt-and-braces).
    nonisolated(unsafe) private var terminationObserver: NSObjectProtocol?

    init() {
        document = Self.loadDocument() ?? AnnotationDocument()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushPendingWrites() }
        }
        publishRenderSnapshot()
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    // MARK: - Reads

    /// One scene's annotations (empty default when never annotated).
    func annotations(for sceneID: SceneID) -> SceneAnnotations {
        document.scenes[sceneID.rawValue.uuidString] ?? SceneAnnotations()
    }

    func canUndoStroke(in sceneID: SceneID) -> Bool {
        histories[sceneID]?.canUndo ?? false
    }

    func canRedoStroke(in sceneID: SceneID) -> Bool {
        histories[sceneID]?.canRedo ?? false
    }

    /// The menu/toolbar mirror for the staged scene.
    func uiState(stagedSceneID: SceneID?) -> AnnotationUIState {
        var state = AnnotationUIState(activeTool: activeTool,
                                      colorHex: colorHex,
                                      penWidth: penWidth,
                                      highlighterWidth: highlighterWidth,
                                      pointer: pointer)
        if let stagedSceneID {
            let annotations = annotations(for: stagedSceneID)
            state.stagedStrokeCount = annotations.strokes.count
            state.stagedVisible = annotations.isVisible
            state.stagedInProgram = annotations.includeInProgram
            state.stagedCanUndo = canUndoStroke(in: stagedSceneID)
            state.stagedCanRedo = canRedoStroke(in: stagedSceneID)
        }
        return state
    }

    // MARK: - Mutations (reached through dispatcher commands)

    func addStroke(_ stroke: AnnotationStroke, in sceneID: SceneID) {
        var annotations = annotations(for: sceneID)
        let before = annotations.strokes
        annotations.strokes.append(stroke)
        setAnnotations(annotations, for: sceneID)
        withHistory(for: sceneID) { $0.record(before: before, after: annotations.strokes) }
    }

    /// Undoes the scene's most recent stroke edit (add or clear).
    func undoStroke(in sceneID: SceneID) {
        var annotations = annotations(for: sceneID)
        guard let restored = withHistory(for: sceneID, { $0.undo(current: annotations.strokes) })
        else { return }
        annotations.strokes = restored
        setAnnotations(annotations, for: sceneID)
    }

    func redoStroke(in sceneID: SceneID) {
        var annotations = annotations(for: sceneID)
        guard let restored = withHistory(for: sceneID, { $0.redo(current: annotations.strokes) })
        else { return }
        annotations.strokes = restored
        setAnnotations(annotations, for: sceneID)
    }

    func clearStrokes(in sceneID: SceneID) {
        var annotations = annotations(for: sceneID)
        let before = annotations.strokes
        annotations.strokes = []
        setAnnotations(annotations, for: sceneID)
        withHistory(for: sceneID) { $0.record(before: before, after: []) }
    }

    func setVisible(_ visible: Bool, in sceneID: SceneID) {
        var annotations = annotations(for: sceneID)
        annotations.isVisible = visible
        setAnnotations(annotations, for: sceneID)
    }

    func setIncludeInProgram(_ include: Bool, in sceneID: SceneID) {
        var annotations = annotations(for: sceneID)
        annotations.includeInProgram = include
        setAnnotations(annotations, for: sceneID)
    }

    /// The width a new stroke of `tool` commits with.
    func strokeWidth(for tool: AnnotationTool) -> Double {
        tool == .highlighter ? highlighterWidth : penWidth
    }

    // MARK: - Pointer (session-only, event-rate)

    /// Laser-pointer tracking: direct store updates, not commands — pointer
    /// motion is mouse-event-rate ephemeral state (like the selection
    /// marquee), not a studio action.
    func updatePointer(sceneID: SceneID, point: AnnotationPoint) {
        pointer = AnnotationPointerState(sceneID: sceneID, point: point)
    }

    func clearPointer() {
        pointer = nil
    }

    // MARK: - Internals

    /// Read-modify-write access to a scene's stroke history (value semantics:
    /// the mutated value lands back in the map).
    private func withHistory<T>(for sceneID: SceneID,
                                _ body: (inout AnnotationHistory) -> T) -> T {
        var history = histories[sceneID] ?? AnnotationHistory()
        let result = body(&history)
        histories[sceneID] = history
        return result
    }

    private func setAnnotations(_ annotations: SceneAnnotations, for sceneID: SceneID) {
        var scenes = document.scenes
        scenes[sceneID.rawValue.uuidString] = annotations
        document = AnnotationDocument(scenes: scenes)
    }

    /// Publishes the program-compositor snapshot: only strokes (and the
    /// pointer) whose scene made the explicit "part of program" choice AND
    /// are visible. Everything else stays preview chrome.
    private func publishRenderSnapshot() {
        var snapshot = AnnotationRenderSnapshot()
        for (key, annotations) in document.scenes {
            let strokes = annotations.programStrokes
            guard !strokes.isEmpty,
                  let sceneID = UUID(uuidString: key) else { continue }
            snapshot.strokes[SceneID(sceneID)] = strokes
        }
        if activeTool == .pointer, let pointer,
           annotations(for: pointer.sceneID).programStrokesGateOpen {
            snapshot.pointer = pointer
        }
        ProgramAnnotationStore.shared.publish(snapshot)
    }

    // MARK: - Persistence (the SoundboardStore pattern)

    private static func fileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
            .appendingPathComponent(fileName)
    }

    /// Loads the document, quarantining an unreadable/newer file aside (never
    /// crash-loop, never overwrite data that couldn't be read — the S12 rule).
    private static func loadDocument() -> AnnotationDocument? {
        guard let url = fileURL(), let data = try? Data(contentsOf: url) else { return nil }
        guard let document = try? JSONDecoder().decode(AnnotationDocument.self, from: data) else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            try? FileManager.default.moveItem(
                at: url,
                to: url.appendingPathExtension("corrupt.\(formatter.string(from: Date())).bak"))
            return nil
        }
        return document
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autosaveDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.writeDocument()
        }
    }

    /// Writes any pending debounced autosave NOW (app termination).
    func flushPendingWrites() {
        autosaveTask?.cancel()
        writeDocument()
    }

    private func writeDocument() {
        guard let url = Self.fileURL(),
              let data = try? JSONEncoder().encode(document) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

private extension SceneAnnotations {
    /// The pointer's program gate equals the strokes' gate: visible AND
    /// explicitly program-included.
    var programStrokesGateOpen: Bool {
        isVisible && includeInProgram
    }
}
