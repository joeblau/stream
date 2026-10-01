import Foundation

// MARK: - Undo/redo stack (S12, issue #75)
//
// A generic, snapshot-based undo stack. The W05 dispatcher records one entry
// per executed undoable `StudioCommand`, capturing the undoable state (scene
// document + browser metadata + staged scene) BEFORE and AFTER the command —
// snapshots, not hand-written inverses, so every current and future command
// is undoable with zero per-command inverse code and no inverse bugs.
//
// COALESCING: rapid-fire commands that represent ONE user gesture (a canvas
// transform drag, a slider scrub, keystroke-by-keystroke renames) carry a
// coalescing key; a repeat of the top entry's key within `coalesceWindow`
// folds into that entry — the gesture stays one undo action, with the
// ORIGINAL pre-state and the LATEST post-state.
//
// PROGRAM SAFETY: the stack holds values only; the dispatcher applies them to
// the STAGED model and the store, never to the program snapshot — so undo of
// an edit that was already Taken re-stages the prior state as pending edits
// instead of retroactively changing live output.
@MainActor
final class UndoStack<Snapshot: Equatable> {
    struct Entry {
        /// Human label of the command that produced this entry ("Move Layer")
        /// — the menu shows "Undo <label>".
        let label: String
        /// Commands with the same key coalesce while inside the window
        /// (nil never coalesces).
        let coalescingKey: String?
        /// Last time this entry was touched; drives the coalescing window.
        var timestamp: Date
        /// State before the command (what undo restores).
        let pre: Snapshot
        /// State after the command (what redo restores); coalescing rewrites.
        var post: Snapshot
    }

    private(set) var undoEntries: [Entry] = []
    private(set) var redoEntries: [Entry] = []

    /// Bound on memory: snapshots are value copies of the whole document.
    let limit: Int
    /// How long a repeated coalescing key still folds into the top entry.
    let coalesceWindow: TimeInterval

    init(limit: Int = 100, coalesceWindow: TimeInterval = 1.0) {
        self.limit = limit
        self.coalesceWindow = coalesceWindow
    }

    var canUndo: Bool { !undoEntries.isEmpty }
    var canRedo: Bool { !redoEntries.isEmpty }
    var undoLabel: String? { undoEntries.last?.label }
    var redoLabel: String? { redoEntries.last?.label }

    /// Records one executed edit. No-ops (pre == post) never reach the stack.
    /// Any new record clears the redo stack (a new edit branch invalidates
    /// the undone future), including a coalesced fold-in.
    func record(label: String,
                coalescingKey: String? = nil,
                pre: Snapshot,
                post: Snapshot,
                at now: Date = Date()) {
        guard pre != post else { return }
        if let coalescingKey,
           let last = undoEntries.last,
           last.coalescingKey == coalescingKey,
           now.timeIntervalSince(last.timestamp) <= coalesceWindow {
            undoEntries[undoEntries.count - 1].post = post
            undoEntries[undoEntries.count - 1].timestamp = now
        } else {
            undoEntries.append(Entry(label: label,
                                     coalescingKey: coalescingKey,
                                     timestamp: now,
                                     pre: pre,
                                     post: post))
            if undoEntries.count > limit {
                undoEntries.removeFirst()
            }
        }
        redoEntries.removeAll()
    }

    /// Pops the most recent edit and returns the state undo restores (its
    /// pre-command snapshot); the entry moves to the redo stack.
    func undo() -> Snapshot? {
        guard let entry = undoEntries.popLast() else { return nil }
        redoEntries.append(entry)
        return entry.pre
    }

    /// Re-applies the most recently undone edit, returning the state redo
    /// restores (its post-command snapshot).
    func redo() -> Snapshot? {
        guard let entry = redoEntries.popLast() else { return nil }
        undoEntries.append(entry)
        return entry.post
    }
}
