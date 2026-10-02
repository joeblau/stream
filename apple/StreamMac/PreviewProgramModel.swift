import Combine
import Foundation

/// The W03 preview/program model (issue #66): two INDEPENDENT scene snapshots.
///
/// `stagedScene` is what the PREVIEW monitor shows and what every scene edit
/// (visibility, transform, effects, layout/PIP compat setters) mutates.
/// `programScene` is the independent snapshot the program `CompositionEngine`
/// composites and the outputs — publisher, recording, PROGRAM monitor — emit.
/// `Scene` is a value type and neither snapshot is ever edited in place
/// through a shared reference, so staged work cannot leak into the outgoing
/// program: no shared mutable state exists between the two.
///
/// Take copies staged → program with one value assignment; the engine then
/// swaps its scene between ticks, so every program frame is entirely the old
/// composition or entirely the new one, and the swap never restarts the
/// tick loop, the clock, or any capture source. Revert copies program →
/// staged, discarding unpublished edits.
///
/// Persistence: `SceneStore` remains the source of truth and only ever stores
/// the PUBLISHED composition — staged edits reach disk on Take, or per-edit
/// in direct-live mode (each edit is an implicit take there), never before.
/// A program snapshot whose scene is later deleted keeps compositing from
/// memory until the next Take; the next launch starts program from the
/// persisted selection again.
///
/// Direct-live editing (off by default, persisted in UserDefaults): an
/// explicit user mode where every edit and selection takes immediately, so
/// preview and program move together — the classic single-composition
/// switcher behavior. The W05 dispatcher performs those implicit takes.
@MainActor
final class PreviewProgramModel: ObservableObject {
    /// What the PREVIEW monitor shows and edit commands mutate.
    @Published private(set) var stagedScene: Scene?
    /// The independent snapshot the program engine composites.
    @Published private(set) var programScene: Scene?
    /// Explicit user mode: edits apply straight to program. Off by default.
    @Published private(set) var directLiveEditing: Bool {
        didSet { UserDefaults.standard.set(directLiveEditing, forKey: Self.directLiveKey) }
    }

    private static let directLiveKey = "studio.directLiveEditing"

    /// Staged content the program doesn't have yet — a different staged scene
    /// or edits to the same one. Plain value equality: no bookkeeping to drift.
    var hasPendingEdits: Bool { stagedScene != programScene }

    /// Both snapshots start from the persisted selection, so a launch opens
    /// with preview == program and nothing pending.
    init(selected: Scene?) {
        stagedScene = selected
        programScene = selected
        directLiveEditing = UserDefaults.standard.bool(forKey: Self.directLiveKey)
    }

    /// Stages a scene for preview (a selection change). Pending edits to the
    /// previously staged scene are discarded — preview always shows the scene
    /// exactly as `SceneStore` persists it.
    func stage(_ scene: Scene?) {
        stagedScene = scene
    }

    /// Applies one edit to the staged copy. Never touches program.
    func applyStagedEdit(_ scene: Scene) {
        stagedScene = scene
    }

    /// Publishes the staged composition: program becomes an independent value
    /// copy of staged. Returns the new program scene so the caller (the W05
    /// dispatcher) can persist it as the source of truth; the controller's
    /// observation of `programScene` lands it on the program engine.
    @discardableResult
    func take() -> Scene? {
        guard let stagedScene else { return nil }
        programScene = stagedScene
        return stagedScene
    }

    /// Runtime fallback changes only program. It never overwrites saved scenes
    /// or unpublished preview edits and keeps all output sessions intact.
    func setResilienceProgram(_ scene: Scene) { programScene = scene }

    /// Discards unpublished edits: staged becomes a copy of the program
    /// snapshot.
    func revert() {
        stagedScene = programScene
    }

    func setDirectLiveEditing(_ on: Bool) {
        directLiveEditing = on
    }

    /// A rename is metadata, not a staged visual edit: it persists via
    /// `SceneStore` immediately, so sync it into both snapshots to keep a
    /// name-only difference from reading as a pending edit.
    func noteSceneRenamed(_ id: SceneID, to name: String) {
        if stagedScene?.id == id { stagedScene?.name = name }
        if programScene?.id == id { programScene?.name = name }
    }
}
