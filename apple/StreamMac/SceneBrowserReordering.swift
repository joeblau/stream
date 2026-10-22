import Foundation
import SwiftUI

/// Resolve against the full, current container, never a searched row subset
/// or a captured drag/menu sibling array. All mutation stays in the dispatcher.
@MainActor
enum SceneBrowserReordering {
    enum Direction { case earlier, later }

    static func command(for id: SceneID, direction: Direction,
                        in store: SceneStore) -> StudioCommand? {
        guard store.scene(withID: id) != nil else { return nil }
        let folderID = store.sceneMembership[id]
        if let folderID, !store.folders.contains(where: { $0.id == folderID }) { return nil }
        let siblings = folderID.map { store.members(of: $0) } ?? store.unfiledScenes
        guard let index = siblings.firstIndex(where: { $0.id == id }) else { return nil }
        switch direction {
        case .earlier:
            guard index > 0 else { return nil }
            return .moveScene(id, toFolder: folderID, before: siblings[index - 1].id)
        case .later:
            guard index + 1 < siblings.count else { return nil }
            // The command inserts BEFORE its anchor after removing the moved
            // scene. Skip the next sibling so we land immediately after it.
            let anchor = index + 2 < siblings.count ? siblings[index + 2].id : nil
            return .moveScene(id, toFolder: folderID, before: anchor)
        }
    }

    static func canMove(_ id: SceneID, direction: Direction, in store: SceneStore,
                        dispatcher: StudioCommandDispatcher) -> Bool {
        guard let command = command(for: id, direction: direction, in: store) else { return false }
        return dispatcher.canExecute(command)
    }

    static func move(_ id: SceneID, direction: Direction, in store: SceneStore,
                     dispatcher: StudioCommandDispatcher) {
        guard let command = command(for: id, direction: direction, in: store) else { return }
        // The action can outlive its menu's availability check. Recompute its
        // target and let execution validate current locks and ownership again.
        dispatcher.execute(command)
    }
}

/// Native menu-bar navigation provides a keyboard path without intercepting
/// text editing or introducing global shortcuts. Resolve selection on invoke.
struct SceneBrowserReorderingCommands: Commands {
    @ObservedObject var store: SceneStore
    @ObservedObject var dispatcher: StudioCommandDispatcher
    let isCurrentRuntime: () -> Bool

    var body: some Commands {
        CommandMenu("Scene") {
            Button("Move Selected Scene Earlier") {
                moveSelection(.earlier)
            }
            .disabled(!canMoveSelection(.earlier))
            Button("Move Selected Scene Later") {
                moveSelection(.later)
            }
            .disabled(!canMoveSelection(.later))
        }
    }

    func canMoveSelection(_ direction: SceneBrowserReordering.Direction) -> Bool {
        isCurrentRuntime() && SceneBrowserReordering.canMove(store.selectedID, direction: direction,
                                                             in: store, dispatcher: dispatcher)
    }

    func moveSelection(_ direction: SceneBrowserReordering.Direction) {
        // A menu item can survive its view while a project switch retires the
        // runtime. Never let that old item edit either project's scene order.
        guard isCurrentRuntime() else { return }
        SceneBrowserReordering.move(store.selectedID, direction: direction, in: store, dispatcher: dispatcher)
    }
}
