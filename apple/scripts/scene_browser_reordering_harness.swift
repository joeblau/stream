import Foundation

/// Shipping runtime, resolver, dispatcher, store and undo stack. The workspace
/// runner isolates storage/secrets and suppresses capture; this mode opens no UI.
@MainActor
enum SceneBrowserReorderingHarness {
    static func run(runtime: StudioRuntime, directory: URL) throws {
        func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
            if !value() { throw NSError(domain: "SceneReordering", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let store = runtime.sceneStore, dispatcher = runtime.dispatcher
        let preview = runtime.previewProgram
        let a = Scene(name: "Search match A", layers: [])
        let b = Scene(name: "Hidden by search", layers: [])
        let c = Scene(name: "Search match C", layers: [])
        let x = Scene(name: "Folder X", layers: [])
        let y = Scene(name: "Folder Y", layers: [])
        let z = Scene(name: "Folder Z", layers: [])
        let g = Scene(name: "Other folder", layers: [])
        store.scenes = [a, x, y, z, b, g, c]
        let folder = store.addFolder(named: "Current folder")
        let other = store.addFolder(named: "Other folder")
        for scene in [x, y, z] {
            dispatcher.execute(.moveScene(scene.id, toFolder: folder.id, before: nil))
        }
        dispatcher.execute(.moveScene(g.id, toFolder: other.id, before: nil))
        store.selectedID = a.id
        preview.stage(b); _ = preview.take()
        var pending = c; pending.name = "Pending preview edit"
        preview.stage(pending)
        let selected = store.selectedID, staged = preview.stagedScene, program = preview.programScene
        let originalContents = Dictionary(uniqueKeysWithValues: store.scenes.map { ($0.id, $0) })
        let originalMembership = store.sceneMembership
        func move(_ id: SceneID, _ direction: SceneBrowserReordering.Direction) {
            SceneBrowserReordering.move(id, direction: direction, in: store, dispatcher: dispatcher)
        }
        func canMove(_ id: SceneID, _ direction: SceneBrowserReordering.Direction) -> Bool {
            SceneBrowserReordering.canMove(id, direction: direction, in: store, dispatcher: dispatcher)
        }
        func unfiled() -> [SceneID] { store.unfiledScenes.map(\.id) }
        func members() -> [SceneID] { store.members(of: folder.id).map(\.id) }
        let beforeBoundary = store.scenes
        try require(!canMove(a.id, .earlier) && !canMove(c.id, .later), "Unfiled boundary advertised a move")
        move(a.id, .earlier); move(c.id, .later)
        try require(store.scenes == beforeBoundary, "Unfiled boundary changed ordering")
        // Only A/C match a search. Cross the actual adjacent B, not the next
        // visible result C. The shipping resolver has no filtered-array input.
        move(a.id, .later)
        try require(unfiled() == [b.id, a.id, c.id], "Search-hidden sibling was skipped")
        move(a.id, .later)
        try require(unfiled() == [b.id, c.id, a.id], "Later-to-end anchor was incorrect")
        move(a.id, .earlier); move(a.id, .earlier)
        try require(unfiled() == [a.id, b.id, c.id], "Earlier failed to restore unfiled order")
        try require(!canMove(x.id, .earlier) && !canMove(z.id, .later), "Folder boundary advertised a move")
        move(x.id, .earlier); move(z.id, .later)
        try require(members() == [x.id, y.id, z.id], "Folder boundary changed ordering")
        move(x.id, .later); move(x.id, .later)
        try require(members() == [y.id, z.id, x.id], "Folder move-to-end failed")
        let beforeUndo = store.scenes
        dispatcher.execute(.undo)
        try require(members() == [y.id, x.id, z.id], "Reorder bypassed shipping undo stack")
        dispatcher.execute(.redo)
        try require(store.scenes == beforeUndo, "Redo did not restore exact order")
        move(x.id, .earlier); move(x.id, .earlier)
        try require(members() == [x.id, y.id, z.id], "Folder earlier failed")
        dispatcher.execute(.setSceneLocked(y.id, locked: true))
        let lockedOrder = store.scenes
        try require(!canMove(y.id, .earlier) && !canMove(y.id, .later), "Locked scene advertised moves")
        move(y.id, .earlier); move(y.id, .later)
        try require(store.scenes == lockedOrder && dispatcher.lastRejection != nil, "Dispatcher did not reject locked movement")
        move(x.id, .later)
        try require(members() == [y.id, x.id, z.id] && store.isLocked(y.id), "Locked neighbor was modified or blocked valid movement")
        move(x.id, .earlier)
        try require(store.sceneMembership == originalMembership, "Within-container move changed ownership")
        try require(Dictionary(uniqueKeysWithValues: store.scenes.map { ($0.id, $0) }) == originalContents, "Reorder changed scene identity or content")
        try require(store.selectedID == selected && preview.stagedScene == staged && preview.programScene == program,
                    "Reorder changed selection, staged edits or Program")
        store.flushPendingWrites()
        let reloaded = SceneStore(directory: directory)
        try require(reloaded.scenes == store.scenes && reloaded.sceneMembership == store.sceneMembership
                    && reloaded.lockedSceneIDs == store.lockedSceneIDs && reloaded.selectedID == selected,
                    "Shipping persistence lost reorder metadata")
        // Reuse an old action's ID after another command re-files its target.
        try require(canMove(x.id, .later), "Expected original action availability")
        dispatcher.execute(.moveScene(x.id, toFolder: other.id, before: nil))
        move(x.id, .earlier)
        try require(store.members(of: other.id).map(\.id) == [x.id, g.id]
                    && store.sceneMembership[x.id] == other.id, "Old action restored stale folder")
        try require(!canMove(z.id, .later), "Boundary after refile was stale")
        dispatcher.execute(.deleteScene(x.id))
        let afterDeletion = store.scenes, afterDeletionMembership = store.sceneMembership
        try require(!canMove(x.id, .earlier) && !canMove(x.id, .later), "Deleted scene advertised actions")
        move(x.id, .earlier); move(x.id, .later); move(SceneID(), .later)
        try require(store.scenes == afterDeletion && store.sceneMembership == afterDeletionMembership,
                    "Stale ID moved another scene or recreated membership")
        try require(!runtime.controller.isPreviewing && !runtime.controller.outputSessionActive,
                    "Model fixture activated capture or publishing")
        print("PASS: actual scene resolver/dispatcher/store; full siblings, boundaries, ownership, locks, undo/redo, persistence, stale actions and independent Preview/Program identity")
    }

    static func menuOwnership(workspace: StudioWorkspace) async throws {
        func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
            if !value() { throw NSError(domain: "SceneReorderingMenu", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let old = workspace.runtime, store = old.sceneStore
        let menu = SceneBrowserReorderingCommands(store: store, dispatcher: old.dispatcher,
                                                  isCurrentRuntime: { workspace.runtime === old })
        let first = Scene(name: "Menu first", layers: []), second = Scene(name: "Menu second", layers: [])
        store.scenes = [first, second]
        store.selectedID = first.id
        try require(!menu.canMoveSelection(.earlier) && menu.canMoveSelection(.later), "Menu did not resolve first-scene boundary")
        store.selectedID = second.id
        try require(menu.canMoveSelection(.earlier) && !menu.canMoveSelection(.later), "Menu did not observe changed selection")
        menu.moveSelection(.earlier)
        try require(store.scenes.map(\.id) == [second.id, first.id] && store.selectedID == second.id,
                    "Shipping menu action captured an old selected ID")
        let oldOrder = store.scenes
        workspace.create(named: "New menu ownership project")
        await workspace.applyPending()
        try require(workspace.runtime !== old && workspace.error == nil, "Actual workspace runtime switch failed")
        let current = workspace.runtime, currentOrder = current.sceneStore.scenes
        try require(!menu.canMoveSelection(.earlier) && !menu.canMoveSelection(.later), "Retired menu advertised authority")
        menu.moveSelection(.earlier); menu.moveSelection(.later)
        try require(store.scenes == oldOrder && current.sceneStore.scenes == currentOrder,
                    "Retired menu edited a project after switching")
        let rebound = SceneBrowserReorderingCommands(store: current.sceneStore, dispatcher: current.dispatcher,
                                                     isCurrentRuntime: { workspace.runtime === current })
        current.sceneStore.scenes = [first, second]; current.sceneStore.selectedID = first.id
        rebound.moveSelection(.later)
        try require(current.sceneStore.scenes.map(\.id) == [second.id, first.id]
                    && current.sceneStore.selectedID == first.id && store.scenes == oldOrder,
                    "Current menu did not rebind independently of retired runtime")
        print("PASS: shipping native-menu callbacks resolve current selection and refuse retired runtime across actual workspace switch; rebound menu operates independently")
    }
}
