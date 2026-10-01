import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The S02 scene browser (issue #70): the studio window's scenes column,
/// upgraded from a flat list into an organizer —
///
///     ┌──────────────────────────────┐
///     │ Scenes            [list|grid]│
///     │ ⌕ Search scenes              │
///     │ ▾ Intros                2    │  ← folder (collapse, rename, drop)
///     │   ▓▓ Cold Open      PVW      │
///     │   ▓▓ Host Cam  🔒       PGM  │
///     │ ▓▓ Screen + Cam        ●     │  ← staged-edit dot
///     │ ▾ Breaks                1    │
///     ├──────────────────────────────┤
///     │ + Add Scene   ⌘ Folder       │
///     └──────────────────────────────┘
///
/// Features: cached thumbnails (live monitor frames for the staged/program
/// scenes, stylized layer placeholders otherwise — `SceneThumbnailStore`),
/// folders (create, rename, collapse, drag scenes in/out), drag-to-reorder,
/// locks (locked scenes reject rename/delete/reorder/edits with a dispatcher
/// rejection), and search. List and thumbnail-grid modes persist via
/// `@AppStorage`; folder collapse/order/locks persist in `SceneStore`'s
/// browser document. Every action routes through the W05 dispatcher; the
/// W03 PVW/PGM markers and the staged-edit indication read `StudioState`.
struct SceneBrowserView: View {
    @EnvironmentObject private var sceneStore: SceneStore
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher
    @EnvironmentObject private var controller: StreamController

    @StateObject private var thumbnails = SceneThumbnailStore()
    @AppStorage("studio.sceneBrowser.gridMode") private var gridMode = false
    @State private var searchText = ""
    @State private var renameTarget: RenameTarget?
    @State private var draftName = ""
    /// Folder header currently under a drag (drop highlight).
    @State private var targetedFolderID: SceneFolderID?

    /// Slow refresh so monitor-backed thumbnails track the live picture;
    /// graph changes refresh immediately via `onChange` below.
    private let liveTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private enum RenameTarget: Identifiable {
        case scene(Scene)
        case folder(SceneFolder)

        var id: String {
            switch self {
            case .scene(let scene): return "scene:\(scene.id.rawValue.uuidString)"
            case .folder(let folder): return "folder:\(folder.id.rawValue.uuidString)"
            }
        }
        var title: String {
            switch self {
            case .scene: return "Rename Scene"
            case .folder: return "Rename Folder"
            }
        }
        var name: String {
            switch self {
            case .scene(let scene): return scene.name
            case .folder(let folder): return folder.name
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            if gridMode {
                gridContent
            } else {
                listContent
            }
            Divider()
            footer
        }
        .alert(renameTarget?.title ?? "Rename", isPresented: renameBinding) {
            TextField("Name", text: $draftName)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear { refreshThumbnails() }
        .onChange(of: sceneStore.scenes) { _, _ in refreshThumbnails() }
        .onReceive(liveTimer) { _ in
            guard controller.isPreviewing else { return }
            refreshThumbnails(forceLive: true)
        }
    }

    // MARK: - Header / search / footer

    private var header: some View {
        HStack {
            Text("Scenes")
                .font(.callout.weight(.semibold))
            Spacer()
            Picker("Browser mode", selection: $gridMode) {
                Image(systemName: "list.bullet").tag(false)
                Image(systemName: "square.grid.2x2").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 76)
            .help("Switch between the list and thumbnail-grid scene browser")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search scenes", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button {
                dispatcher.execute(.addScene)
            } label: {
                Label("Add Scene", systemImage: "plus")
            }
            Button {
                dispatcher.execute(.addSceneFolder(named: nil))
            } label: {
                Label("Folder", systemImage: "folder.badge.plus")
            }
            .help("Create a scene folder — drag scenes onto it to file them")
            Spacer()
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - List mode

    /// `List` wants an optional selection; the store never leaves zero
    /// scenes, so a deselect is ignored and a select writes straight through.
    private var sceneSelection: Binding<Scene.ID?> {
        Binding(
            get: { sceneStore.selectedID },
            set: { if let id = $0 { dispatcher.execute(.selectScene(id)) } })
    }

    private var listContent: some View {
        List(selection: sceneSelection) {
            if searchText.isEmpty {
                ForEach(sceneStore.browserRows) { row in
                    switch row {
                    case .folder(let folder):
                        folderSection(folder)
                    case .scene(let scene):
                        sceneRow(scene)
                    }
                }
            } else {
                ForEach(filteredScenes) { scene in
                    sceneRow(scene)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func folderSection(_ folder: SceneFolder) -> some View {
        let members = sceneStore.members(of: folder.id)
        return VStack(alignment: .leading, spacing: 0) {
            folderHeader(folder, memberCount: members.count)
            if !folder.isCollapsed {
                ForEach(members) { scene in
                    sceneRow(scene)
                        .padding(.leading, 14)
                }
            }
        }
    }

    private func folderHeader(_ folder: SceneFolder, memberCount: Int) -> some View {
        HStack(spacing: 6) {
            Button {
                dispatcher.execute(.setSceneFolderCollapsed(folder.id,
                                                            collapsed: !folder.isCollapsed))
            } label: {
                Image(systemName: folder.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .help(folder.isCollapsed ? "Expand folder" : "Collapse folder")
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
            Text(folder.name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Text("\(memberCount)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(targetedFolderID == folder.id
                    ? Color.accentColor.opacity(0.18)
                    : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onDrop(of: [UTType.plainText],
                delegate: FolderDropDelegate(
                    folderID: folder.id,
                    dispatcher: dispatcher,
                    isTargeted: Binding(
                        get: { targetedFolderID == folder.id },
                        set: { targetedFolderID = $0 ? folder.id : nil })))
        .contextMenu { folderContextMenu(folder) }
    }

    private func sceneRow(_ scene: Scene) -> some View {
        let folderID = sceneStore.sceneMembership[scene.id]
        return HStack(spacing: 8) {
            thumbnailView(for: scene, size: CGSize(width: 56, height: 32))
            Text(scene.name)
                .lineLimit(1)
            if sceneStore.isLocked(scene.id) {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Locked — unlock to rename, reorder, edit, or delete")
            }
            Spacer()
            markers(for: scene)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .tag(scene.id)
        .onDrag {
            NSItemProvider(object: scene.id.rawValue.uuidString as NSString)
        }
        .onDrop(of: [UTType.plainText],
                delegate: SceneRowDropDelegate(
                    targetSceneID: scene.id,
                    folderID: folderID,
                    siblings: siblings(inFolder: folderID),
                    rowHeight: 40,
                    dispatcher: dispatcher))
        .contextMenu { sceneContextMenu(scene) }
    }

    // MARK: - Grid mode

    private let gridColumns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    /// Grid layout groups consecutive top-level scenes into one grid, with
    /// each folder as its own headed section.
    private enum GridSection: Identifiable {
        case scenes([Scene])
        case folder(SceneFolder, [Scene])

        var id: String {
            switch self {
            case .scenes(let scenes):
                return "unfiled:\(scenes.first?.id.rawValue.uuidString ?? "empty"):\(scenes.count)"
            case .folder(let folder, _):
                return "folder:\(folder.id.rawValue.uuidString)"
            }
        }
    }

    private var gridSections: [GridSection] {
        var sections: [GridSection] = []
        var unfiled: [Scene] = []
        for row in sceneStore.browserRows {
            switch row {
            case .scene(let scene):
                unfiled.append(scene)
            case .folder(let folder):
                if !unfiled.isEmpty {
                    sections.append(.scenes(unfiled))
                    unfiled = []
                }
                sections.append(.folder(folder, sceneStore.members(of: folder.id)))
            }
        }
        if !unfiled.isEmpty {
            sections.append(.scenes(unfiled))
        }
        return sections
    }

    private var gridContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if searchText.isEmpty {
                    ForEach(gridSections) { section in
                        switch section {
                        case .scenes(let scenes):
                            LazyVGrid(columns: gridColumns, spacing: 10) {
                                ForEach(scenes) { gridCard($0) }
                            }
                        case .folder(let folder, let members):
                            VStack(alignment: .leading, spacing: 6) {
                                folderHeader(folder, memberCount: members.count)
                                if !folder.isCollapsed {
                                    LazyVGrid(columns: gridColumns, spacing: 10) {
                                        ForEach(members) { gridCard($0) }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    LazyVGrid(columns: gridColumns, spacing: 10) {
                        ForEach(filteredScenes) { gridCard($0) }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func gridCard(_ scene: Scene) -> some View {
        let folderID = sceneStore.sceneMembership[scene.id]
        let isSelected = sceneStore.selectedID == scene.id
        return VStack(spacing: 4) {
            thumbnailView(for: scene, size: nil)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 3) {
                        markers(for: scene)
                    }
                    .padding(4)
                }
            HStack(spacing: 4) {
                if sceneStore.isLocked(scene.id) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .help("Locked — unlock to rename, reorder, edit, or delete")
                }
                Text(scene.name)
                    .lineLimit(1)
            }
            .font(.caption)
        }
        .padding(5)
        .background(isSelected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            dispatcher.execute(.selectScene(scene.id))
        }
        .onDrag {
            NSItemProvider(object: scene.id.rawValue.uuidString as NSString)
        }
        .onDrop(of: [UTType.plainText],
                delegate: SceneRowDropDelegate(
                    targetSceneID: scene.id,
                    folderID: folderID,
                    siblings: siblings(inFolder: folderID),
                    rowHeight: 86,
                    dispatcher: dispatcher))
        .contextMenu { sceneContextMenu(scene) }
    }

    // MARK: - Rows: shared pieces

    /// Cached thumbnail, or a dark placeholder carrying the layout icon
    /// while the off-main render is in flight.
    private func thumbnailView(for scene: Scene, size: CGSize?) -> some View {
        Group {
            if let image = thumbnails.images[scene.id] {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.black.opacity(0.55)
                    .overlay {
                        Image(systemName: layoutIcon(for: scene))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: size?.width, height: size?.height)
        .frame(minHeight: size == nil ? 52 : nil)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(.white.opacity(0.15))
        }
    }

    private func layoutIcon(for scene: Scene) -> String {
        switch scene.layout {
        case .cameraSolo: return "person.fill"
        case .screenSolo: return "display"
        case .screenPlusCam: return "rectangle.inset.bottomright.filled"
        }
    }

    /// W03 markers: PVW for the scene staged in preview, PGM for the scene on
    /// program, and a yellow dot when the staged scene holds unpublished
    /// edits — the two monitors are independent, so both can show.
    @ViewBuilder
    private func markers(for scene: Scene) -> some View {
        if dispatcher.state.stagedSceneID == scene.id {
            marker("PVW", color: .green)
        }
        if dispatcher.state.programSceneID == scene.id {
            marker("PGM", color: .red)
        }
        if dispatcher.state.stagedSceneID == scene.id, dispatcher.state.hasPendingStagedEdits {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(.yellow)
                .help("Unpublished changes staged in preview")
        }
    }

    private func marker(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.25), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: - Context menus

    @ViewBuilder
    private func sceneContextMenu(_ scene: Scene) -> some View {
        let locked = sceneStore.isLocked(scene.id)
        Button("Rename…") {
            beginRename(.scene(scene))
        }
        .disabled(locked)
        Button("Duplicate") {
            dispatcher.execute(.duplicateScene(scene.id))
        }
        Button(locked ? "Unlock" : "Lock") {
            dispatcher.execute(.setSceneLocked(scene.id, locked: !locked))
        }
        Divider()
        Menu("Move to Folder") {
            ForEach(sceneStore.folders) { folder in
                Button(folder.name) {
                    dispatcher.execute(.moveScene(scene.id, toFolder: folder.id, before: nil))
                }
                .disabled(sceneStore.sceneMembership[scene.id] == folder.id)
            }
            if !sceneStore.folders.isEmpty {
                Divider()
            }
            Button("New Folder") {
                dispatcher.execute(.addSceneFolder(named: nil))
                if let folder = sceneStore.folders.last {
                    dispatcher.execute(.moveScene(scene.id, toFolder: folder.id, before: nil))
                }
            }
        }
        .disabled(locked)
        if sceneStore.sceneMembership[scene.id] != nil {
            Button("Remove from Folder") {
                dispatcher.execute(.moveScene(scene.id, toFolder: nil, before: nil))
            }
            .disabled(locked)
        }
        Divider()
        Button("Delete", role: .destructive) {
            dispatcher.execute(.deleteScene(scene.id))
        }
        .disabled(sceneStore.scenes.count <= 1 || locked)
    }

    @ViewBuilder
    private func folderContextMenu(_ folder: SceneFolder) -> some View {
        Button("Rename Folder…") {
            beginRename(.folder(folder))
        }
        Button(folder.isCollapsed ? "Expand" : "Collapse") {
            dispatcher.execute(.setSceneFolderCollapsed(folder.id,
                                                        collapsed: !folder.isCollapsed))
        }
        Divider()
        Button("Delete Folder (Scenes Are Kept)", role: .destructive) {
            dispatcher.execute(.deleteSceneFolder(folder.id))
        }
    }

    // MARK: - Helpers

    private var filteredScenes: [Scene] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sceneStore.scenes }
        return sceneStore.scenes.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    /// The display-ordered scenes of one container (a folder, or the top
    /// level) — the sibling list a drag reorders within.
    private func siblings(inFolder folderID: SceneFolderID?) -> [Scene] {
        if let folderID {
            return sceneStore.members(of: folderID)
        }
        return sceneStore.unfiledScenes
    }

    /// The live monitor frame backing a scene's thumbnail, when cheaply
    /// available: the staged scene shows the PREVIEW picture, the program
    /// scene the PROGRAM picture, everything else renders placeholders.
    private func liveImage(for scene: Scene) -> CGImage? {
        if dispatcher.state.stagedSceneID == scene.id {
            return controller.previewImage
        }
        if dispatcher.state.programSceneID == scene.id {
            return controller.programImage
        }
        return nil
    }

    private func refreshThumbnails(forceLive: Bool = false) {
        thumbnails.refresh(scenes: sceneStore.scenes,
                           liveImage: liveImage(for:),
                           forceLive: forceLive)
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })
    }

    private func beginRename(_ target: RenameTarget) {
        draftName = target.name
        renameTarget = target
    }

    private func commitRename() {
        switch renameTarget {
        case .scene(let scene):
            dispatcher.execute(.renameScene(scene.id, to: draftName))
        case .folder(let folder):
            dispatcher.execute(.renameSceneFolder(folder.id, to: draftName))
        case nil:
            break
        }
    }
}

// MARK: - Drag & drop

/// Drop target for one scene row/card: drops land in the target's container
/// (its folder, or the top level), positioned before the target (top half of
/// the row) or after it (bottom half). Locked scenes reject the move in the
/// dispatcher, surfacing the standard rejection notice.
private struct SceneRowDropDelegate: DropDelegate {
    let targetSceneID: SceneID
    /// The container the target row sits in (nil = top level).
    let folderID: SceneFolderID?
    /// Display-ordered scenes of that container.
    let siblings: [Scene]
    /// Row height used to split before/after at the midpoint.
    let rowHeight: CGFloat
    let dispatcher: StudioCommandDispatcher

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.plainText.identifier])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.plainText]).first else { return false }
        let after = info.location.y > rowHeight / 2
        let anchor: SceneID?
        if !after {
            anchor = targetSceneID
        } else if let index = siblings.firstIndex(where: { $0.id == targetSceneID }),
                  index + 1 < siblings.count {
            anchor = siblings[index + 1].id
        } else {
            anchor = nil   // dropped past the last sibling: end of the container
        }
        let folderID = self.folderID
        let dispatcher = self.dispatcher
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let raw = object as? String,
                  let uuid = UUID(uuidString: raw) else { return }
            let sceneID = SceneID(uuid)
            Task { @MainActor in
                guard sceneID != targetSceneID else { return }
                dispatcher.execute(.moveScene(sceneID, toFolder: folderID, before: anchor))
            }
        }
        return true
    }
}

/// Drop target for a folder header: files the dragged scene at the end of
/// the folder (or reorders it there when already a member). Tracks its own
/// highlight through `isTargeted` (the `onDrop(of:isTargeted:delegate:)`
/// overload isn't available on the macOS 14 SDK).
private struct FolderDropDelegate: DropDelegate {
    let folderID: SceneFolderID
    let dispatcher: StudioCommandDispatcher
    let isTargeted: Binding<Bool>

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.plainText.identifier])
    }

    func dropEntered(info: DropInfo) {
        isTargeted.wrappedValue = true
    }

    func dropExited(info: DropInfo) {
        isTargeted.wrappedValue = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted.wrappedValue = false
        guard let provider = info.itemProviders(for: [UTType.plainText]).first else { return false }
        let folderID = self.folderID
        let dispatcher = self.dispatcher
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let raw = object as? String,
                  let uuid = UUID(uuidString: raw) else { return }
            let sceneID = SceneID(uuid)
            Task { @MainActor in
                dispatcher.execute(.moveScene(sceneID, toFolder: folderID, before: nil))
            }
        }
        return true
    }
}
