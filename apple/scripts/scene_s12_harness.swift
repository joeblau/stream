import Foundation

// S12 (issue #75) standalone assertion harness.
//
// The scene model and migration types live in the StreamMac APP target, which
// has no test bundle — so, like S01, this harness compiles the real sources
// (LayerGraph, SceneMigration, SceneDocumentMigration, SceneUndoStack, plus
// the two StreamCore files that define PIPCorner) as one module via
// run_scene_s12_harness.zsh and asserts the S12 behaviors directly:
//   - the migration pipeline (v1→v2, current passthrough, newer-version
//     refusal, corrupt-data handling), and
//   - the undo stack (ordering, redo invalidation, gesture coalescing).
//
// Prints PASS/FAIL per assertion and exits non-zero on any failure.

var failures = 0
@MainActor
func check(_ condition: Bool, _ name: String) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}

let encoder = JSONEncoder()
let decoder = JSONDecoder()

// MARK: - Migration pipeline

// A v1 document (no `version` key — v1 pre-dates versioning).
let pipSceneID = UUID()
let v1 = LegacySceneDocumentV1(
    scenes: [
        LegacySceneV1(id: UUID(), name: "Camera", layout: .cameraSolo,
                      pipCorner: .bottomRight, pipScale: 0.28),
        LegacySceneV1(id: UUID(), name: "Screen", layout: .screenSolo,
                      pipCorner: .bottomRight, pipScale: 0.28),
        LegacySceneV1(id: pipSceneID, name: "Screen + Cam", layout: .screenPlusCam,
                      pipCorner: .topLeft, pipScale: 0.33)
    ],
    selectedID: pipSceneID)
let v1Data = try! encoder.encode(v1)

check(SceneDocumentMigration.detectedVersion(of: v1Data) == 1,
      "version detection: keyless document reads as v1")

let migratedV1 = SceneDocumentMigration.migrateToCurrent(v1Data)
if case .success(let migratedData) = migratedV1,
   let document = try? decoder.decode(SceneDocument.self, from: migratedData) {
    check(document.version == SceneDocument.currentVersion,
          "v1→v2: migrated document is stamped at the current version")
    check(document.scenes.map(\.name) == ["Camera", "Screen", "Screen + Cam"],
          "v1→v2: scene names and order preserved")
    check(document.scenes.count == 3, "v1→v2: all scenes migrated")
    let pipScene = document.scenes.first(where: { $0.id.rawValue == pipSceneID })
    let pip = pipScene?.layers.first(where: { $0.payload.isCamera && $0.transform.size.width < 1 })
    check(pip != nil, "v1→v2: screen+cam gains a camera PIP layer")
    check(pip?.transform.anchor == .topLeft, "v1→v2: PIP corner preserved")
    check(abs((pip?.transform.size.width ?? 0) - 0.33) < 0.0001,
          "v1→v2: PIP scale preserved")
    check(document.selectedID.rawValue == pipSceneID, "v1→v2: selection preserved")
    check(document.sources.count == 2, "v1→v2: shared camera/screen sources created")
    check(SceneDocumentMigration.detectedVersion(of: migratedData) == SceneDocument.currentVersion,
          "v1→v2: re-migrating migrated data is a no-op passthrough")
} else {
    check(false, "v1→v2: migration succeeds and decodes")
}

// Current-version data passes through unmolested.
let currentDocument = SceneDocument.makeDefault()
let currentData = try! encoder.encode(currentDocument)
check(SceneDocumentMigration.detectedVersion(of: currentData) == SceneDocument.currentVersion,
      "version detection: v2 document reads as v2")
if case .success(let passthrough) = SceneDocumentMigration.migrateToCurrent(currentData) {
    check(passthrough == currentData, "current version: bytes pass through untouched")
    check((try? decoder.decode(SceneDocument.self, from: passthrough)) == currentDocument,
          "current version: round-trip is lossless")
} else {
    check(false, "current version: migration succeeds")
}

// A NEWER version is refused, never destroyed.
let newerData = Data("{\"version\": \(SceneDocument.currentVersion + 1), \"scenes\": []}".utf8)
if case .failure(.newerThanSupported(let found, let supported)) =
    SceneDocumentMigration.migrateToCurrent(newerData) {
    check(found == SceneDocument.currentVersion + 1 && supported == SceneDocument.currentVersion,
          "newer version: refused with found/supported reported")
} else {
    check(false, "newer version: refused as newerThanSupported")
}

// Corrupt data fails cleanly (SceneStore quarantines it; never crash-loops).
if case .failure(.unreadable(let version)) =
    SceneDocumentMigration.migrateToCurrent(Data("this is not json".utf8)) {
    check(version == nil, "corrupt: non-JSON reports unreadable(nil)")
} else {
    check(false, "corrupt: non-JSON data is refused")
}
if case .failure(.unreadable(let version)) =
    SceneDocumentMigration.migrateToCurrent(Data("{\"version\": 1, \"scenes\": 42}".utf8)) {
    check(version == 1, "corrupt: data failing its claimed version reports that version")
} else {
    check(false, "corrupt: v1-claiming garbage is refused")
}
if case .failure(.unreadable(let version)) =
    SceneDocumentMigration.migrateToCurrent(Data("{\"version\": 0}".utf8)) {
    check(version == 0, "version 0: refused as unreadable")
} else {
    check(false, "version 0: refused")
}

// MARK: - Undo stack

let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

// Ordering + redo invalidation.
do {
    let stack = UndoStack<Int>()
    check(!stack.canUndo && !stack.canRedo, "undo stack: starts empty")
    stack.record(label: "A", pre: 1, post: 2, at: t0)
    stack.record(label: "B", pre: 2, post: 3, at: t0)
    check(stack.canUndo && stack.undoLabel == "B", "undo stack: top label is the latest edit")
    check(stack.undo() == 2, "undo stack: undo restores the pre-state")
    check(stack.undo() == 1, "undo stack: undos apply most-recent-first")
    check(!stack.canUndo && stack.canRedo, "undo stack: drains to empty")
    check(stack.redo() == 2 && stack.redo() == 3, "undo stack: redo replays oldest-first")
    check(stack.undoLabel == "B", "undo stack: redo restores the undo side")
    _ = stack.undo()
    stack.record(label: "C", pre: 2, post: 9, at: t0)
    check(!stack.canRedo, "undo stack: a new edit clears the redo stack")
}

// No-op edits never reach the stack.
do {
    let stack = UndoStack<Int>()
    stack.record(label: "noop", pre: 4, post: 4, at: t0)
    check(!stack.canUndo, "undo stack: pre == post records nothing")
}

// Gesture coalescing: same key inside the window folds into ONE entry that
// keeps the ORIGINAL pre-state and the LATEST post-state (a drag becomes one
// undo action).
do {
    let stack = UndoStack<Int>()
    stack.record(label: "Move Layer", coalescingKey: "layer-transform.x", pre: 0, post: 1, at: t0)
    stack.record(label: "Move Layer", coalescingKey: "layer-transform.x", pre: 1, post: 2,
                 at: t0.addingTimeInterval(0.3))
    stack.record(label: "Move Layer", coalescingKey: "layer-transform.x", pre: 2, post: 7,
                 at: t0.addingTimeInterval(0.6))
    check(stack.undoEntries.count == 1, "coalescing: a rapid drag folds into one entry")
    check(stack.undo() == 0, "coalescing: undo restores the gesture's ORIGINAL pre-state")
    check(stack.redo() == 7, "coalescing: redo restores the gesture's LATEST post-state")
}

// Distinct keys — and keys outside the window — do not coalesce.
do {
    let stack = UndoStack<Int>()
    stack.record(label: "Move A", coalescingKey: "layer-transform.a", pre: 0, post: 1, at: t0)
    stack.record(label: "Move B", coalescingKey: "layer-transform.b", pre: 1, post: 2,
                 at: t0.addingTimeInterval(0.1))
    check(stack.undoEntries.count == 2, "coalescing: different targets stay separate")

    let slow = UndoStack<Int>()
    slow.record(label: "Move", coalescingKey: "layer-transform.a", pre: 0, post: 1, at: t0)
    slow.record(label: "Move", coalescingKey: "layer-transform.a", pre: 1, post: 2,
                at: t0.addingTimeInterval(5))
    check(slow.undoEntries.count == 2, "coalescing: outside the window starts a new entry")

    let keyed = UndoStack<Int>()
    keyed.record(label: "Edit", pre: 0, post: 1, at: t0)
    keyed.record(label: "Edit", pre: 1, post: 2, at: t0.addingTimeInterval(0.1))
    check(keyed.undoEntries.count == 2, "coalescing: keyless commands never coalesce")
}

// The bound drops the oldest entries.
do {
    let stack = UndoStack<Int>(limit: 3)
    for value in 0..<5 {
        stack.record(label: "E\(value)", pre: value, post: value + 1, at: t0)
    }
    check(stack.undoEntries.count == 3 && stack.undoLabel == "E4",
          "undo stack: the limit keeps the NEWEST entries")
}

// MARK: - Result

if failures > 0 {
    print("\nS12 harness: \(failures) assertion(s) FAILED")
    exit(1)
}
print("\nS12 harness: all assertions passed")
