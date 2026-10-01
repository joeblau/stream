import AppKit
import SwiftUI
import StreamCore

/// The S03 ordered layer panel (issue #71): every layer of the STAGED scene
/// in compositing order, front (top of list) to back, with groups, per-row
/// visibility and lock toggles, drag reordering, and add/remove/rename/
/// duplicate actions.
///
/// Every mutation routes through the W05 dispatcher — the panel never edits
/// the scene itself — so locked layers/groups surface an explicit rejection
/// in the diagnostics strip instead of silently no-op'ing, and every edit
/// lands on the staged (PREVIEW) scene only.
///
/// Model semantics (LayerGraph / StudioCommandDispatcher):
/// - The graph stays a flat back-to-front `layers` array; group membership
///   is `LayerNode.groupID`. Grouping moves members adjacent at the
///   frontmost member's slot, so this outline is always contiguous.
/// - Group visibility CASCADES to members (writes each member's
///   `isVisible`), because the render path paints on `isVisible` alone.
/// - Locks COMPOSE non-destructively: effective lock = `layer.isLocked ||
///   group.isLocked`, enforced by dispatcher validation.
///
/// Selection: the panel's selection lives on `SceneStore.selectedLayerIDs`
/// (stable LayerIDs), shared with the S04 canvas so clicking a row and
/// clicking a layer on canvas highlight the same thing.
struct LayerPanelView: View {
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher
    @EnvironmentObject private var previewProgram: PreviewProgramModel
    @EnvironmentObject private var sceneStore: SceneStore
    @EnvironmentObject private var permissions: PermissionsManager
    /// C10 (issue #79): the capture pool's per-source health (missing state,
    /// errors) badges rows, and the device monitor feeds the relink pickers.
    @EnvironmentObject private var capturePool: CaptureSourcePool
    @EnvironmentObject private var deviceMonitor: DeviceMonitor

    /// Rename alert state: the row being renamed plus the text field draft.
    @State private var renameTarget: RenameTarget?
    @State private var draftName = ""
    /// C02: presents the screen-source picker for "New Screen Source…".
    @State private var screenSourcePickerPresented = false

    private enum RenameTarget {
        case layer(LayerNode)
        case group(LayerGroup)
    }

    /// Row identity for the outline. Stable IDs (the graph's own LayerID /
    /// GroupID) keep List selection and disclosure stable across rebuilds.
    private enum RowID: Hashable {
        case layer(LayerID)
        case group(GroupID)
    }

    private struct Row: Identifiable, Hashable {
        let id: RowID
        var children: [Row]?
    }

    var body: some View {
        VStack(spacing: 0) {
            if let scene = previewProgram.stagedScene {
                // S07: project-wide overlays and the background scopes, a
                // distinct section above the staged scene's own layers.
                OverlayPanelView()
                Divider()
                List(selection: selectionBinding) {
                    OutlineGroup(rows(for: scene), children: \.children) { row in
                        rowView(for: row.id, in: scene)
                            .tag(row.id)
                    }
                }
                .listStyle(.sidebar)
                Divider()
                bottomBar
            } else {
                ContentUnavailableView("No Scene Staged",
                                       systemImage: "rectangle.on.rectangle.slash",
                                       description: Text("Select a scene to edit its layers."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert("Rename", isPresented: renamePresented) {
            TextField("Name", text: $draftName)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) {}
        }
        // C02: register a new pinned screen source, then bind a layer to it.
        .sheet(isPresented: $screenSourcePickerPresented) {
            ScreenSourcePickerView { name, payload in
                let source = sceneStore.addSource(
                    SourceDefinition(name: name, payload: .screen(payload)))
                addScreenLayer(boundTo: source)
            }
        }
        // Keep the shared selection pointing at layers that still exist
        // (scene switch, deletion, revert).
        .onChange(of: stagedLayerIDs, initial: true) { _, ids in
            sceneStore.selectedLayerIDs.formIntersection(ids)
        }
    }

    // MARK: - Outline construction

    /// Front-to-back rows; a group's row appears at its frontmost member and
    /// carries every member as a child (grouping keeps members contiguous).
    private func rows(for scene: Scene) -> [Row] {
        let frontToBack = scene.frontToBackLayers
        var emittedGroups: Set<GroupID> = []
        var result: [Row] = []
        for layer in frontToBack {
            if let groupID = layer.groupID, scene.group(withID: groupID) != nil {
                guard emittedGroups.insert(groupID).inserted else { continue }
                let members = frontToBack.filter { $0.groupID == groupID }
                result.append(Row(id: .group(groupID),
                                  children: members.map { Row(id: .layer($0.id)) }))
            } else {
                result.append(Row(id: .layer(layer.id)))
            }
        }
        return result
    }

    private var stagedLayerIDs: Set<LayerID> {
        Set(previewProgram.stagedScene?.layers.map(\.id) ?? [])
    }

    // MARK: - Selection (shared with the S04 canvas via SceneStore)

    /// The outline's selection mapped to/from the shared LayerID set.
    /// Selecting a group row selects all its members.
    private var selectionBinding: Binding<Set<RowID>> {
        Binding(
            get: { Set(sceneStore.selectedLayerIDs.map(RowID.layer)) },
            set: { newValue in
                var layerIDs = Set<LayerID>()
                for rowID in newValue {
                    switch rowID {
                    case .layer(let layerID):
                        layerIDs.insert(layerID)
                    case .group(let groupID):
                        if let scene = previewProgram.stagedScene {
                            layerIDs.formUnion(scene.members(of: groupID).map(\.id))
                        }
                    }
                }
                sceneStore.selectedLayerIDs = layerIDs
            })
    }

    // MARK: - Rows

    @ViewBuilder
    private func rowView(for rowID: RowID, in scene: Scene) -> some View {
        switch rowID {
        case .layer(let layerID):
            if let layer = scene.layers.first(where: { $0.id == layerID }) {
                layerRow(layer, in: scene)
            }
        case .group(let groupID):
            if let group = scene.group(withID: groupID) {
                groupRow(group, in: scene)
            }
        }
    }

    private func layerRow(_ layer: LayerNode, in scene: Scene) -> some View {
        HStack(spacing: 6) {
            Image(systemName: layer.payload.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(layer.name)
                .lineLimit(1)
                .foregroundStyle(layer.isVisible ? .primary : .secondary)
            if !layer.payload.isRenderable {
                Text("not rendered")
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
                    .help("\(layer.payload.displayName) layers are model-only — the render path composites camera, screen, text, shape, and nested scene layers today.")
            }
            if let missing = missingReason(for: layer) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .imageScale(.small)
                    .help(missing)
            }
            Spacer()
            lockButton(isLocked: scene.isEffectivelyLocked(layer),
                       viaGroup: !layer.isLocked && scene.isEffectivelyLocked(layer),
                       help: layer.isLocked ? "Unlock \(layer.name)"
                           : scene.isEffectivelyLocked(layer) ? "Locked via group"
                           : "Lock \(layer.name)") {
                dispatcher.execute(.setLayerLocked(layer.id, locked: !layer.isLocked, in: nil))
            }
            eyeButton(isVisible: layer.isVisible, help: layer.isVisible ? "Hide" : "Show") {
                dispatcher.execute(.setLayerVisibility(layer.id, visible: !layer.isVisible, in: nil))
            }
        }
        .contextMenu { layerContextMenu(layer, in: scene) }
        .draggable(layer.id.rawValue.uuidString)
        .dropDestination(for: String.self) { payload, _ in
            handleDrop(payload, onto: .layer(layer.id), in: scene)
        }
    }

    private func groupRow(_ group: LayerGroup, in scene: Scene) -> some View {
        let members = scene.members(of: group.id)
        let anyVisible = members.contains(where: \.isVisible)
        return HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(group.name)
                .lineLimit(1)
                .foregroundStyle(anyVisible ? .primary : .secondary)
            Text("\(members.count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            lockButton(isLocked: group.isLocked, viaGroup: false,
                       help: group.isLocked ? "Unlock \(group.name)" : "Lock \(group.name)") {
                dispatcher.execute(.setGroupLocked(group.id, locked: !group.isLocked, in: nil))
            }
            eyeButton(isVisible: anyVisible, help: anyVisible ? "Hide group" : "Show group") {
                dispatcher.execute(.setGroupVisibility(group.id, visible: !anyVisible, in: nil))
            }
        }
        .contextMenu { groupContextMenu(group, in: scene) }
        .dropDestination(for: String.self) { payload, _ in
            handleDrop(payload, onto: .group(group.id), in: scene)
        }
    }

    private func eyeButton(isVisible: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isVisible ? "eye" : "eye.slash")
                .foregroundStyle(isVisible ? .secondary : .tertiary)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func lockButton(isLocked: Bool, viaGroup: Bool, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isLocked ? "lock.fill" : "lock.open")
                .foregroundStyle(isLocked ? (viaGroup ? Color.secondary : Color.orange) : Color.clear)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    /// Why a layer's source can't paint, if it can't — hidden/missing
    /// sources must be obvious (S03 acceptance). C10 (issue #79): after the
    /// permission checks, the pool's per-source health covers hot-unplug,
    /// capture errors, and mid-session permission revocation.
    private func missingReason(for layer: LayerNode) -> String? {
        switch layer.payload {
        case .camera where permissions.status(for: .camera) != .granted:
            return "Camera permission is not granted — this layer renders black."
        case .screen where permissions.status(for: .screenCapture) != .granted:
            return "Screen recording permission is not granted — this layer renders black."
        case .camera, .screen, .syphon:
            guard let key = captureSourceKey(for: layer) else { return nil }
            return capturePool.problem(for: key)
        case .scene(let reference):
            return sceneStore.scenes.contains(where: { $0.id == reference.sceneID })
                ? nil : "The referenced scene no longer exists."
        default:
            return nil
        }
    }

    /// The layer's effective capture identity: the registry source's payload
    /// when bound (the registry is the identity authority), else the inline
    /// payload — the same resolution the capture pool's demand uses.
    private func captureSourceKey(for layer: LayerNode) -> CaptureSourceKey? {
        let payload = layer.sourceID
            .flatMap { sceneStore.source(withID: $0) }?.payload
            ?? layer.payload
        switch payload {
        case .camera(let camera): return .camera(camera)
        case .screen(let screen): return .screen(screen)
        case .syphon(let syphon): return .syphon(syphon)
        default: return nil
        }
    }

    // MARK: - Context menus

    @ViewBuilder
    private func layerContextMenu(_ layer: LayerNode, in scene: Scene) -> some View {
        Button("Rename…") {
            draftName = layer.name
            renameTarget = .layer(layer)
        }
        Button("Duplicate") {
            dispatcher.execute(.duplicateLayer(layer.id, in: nil))
        }
        // C10 (issue #79): relink a registry-bound source whose identity
        // can't be restored (device gone for good) — the replacement updates
        // every bound layer via the S05 registry update path.
        relinkMenu(for: layer)
        Divider()
        Button("Move Forward") {
            move(layer, towardFront: true, in: scene)
        }
        .disabled(isAtFront(layer, in: scene))
        Button("Move Backward") {
            move(layer, towardFront: false, in: scene)
        }
        .disabled(isAtBack(layer, in: scene))
        Divider()
        if layer.groupID != nil {
            Button("Remove from Group") {
                guard let index = scene.layers.firstIndex(where: { $0.id == layer.id }) else { return }
                dispatcher.execute(.moveLayer(layer.id, toIndex: index, group: nil, in: nil))
            }
        }
        Button("Group Selected Layers") {
            dispatcher.execute(.groupLayers(Array(sceneStore.selectedLayerIDs), named: nil, in: nil))
        }
        .disabled(!dispatcher.canExecute(.groupLayers(Array(sceneStore.selectedLayerIDs), named: nil, in: nil)))
        Divider()
        Button(layer.isLocked ? "Unlock" : "Lock") {
            dispatcher.execute(.setLayerLocked(layer.id, locked: !layer.isLocked, in: nil))
        }
        Divider()
        Button("Delete Layer", role: .destructive) {
            dispatcher.execute(.removeLayer(layer.id, in: nil))
        }
    }

    @ViewBuilder
    private func groupContextMenu(_ group: LayerGroup, in scene: Scene) -> some View {
        let members = scene.members(of: group.id)
        let anyVisible = members.contains(where: \.isVisible)
        Button("Rename Group…") {
            draftName = group.name
            renameTarget = .group(group)
        }
        Button("Ungroup") {
            dispatcher.execute(.ungroupLayers(group.id, in: nil))
        }
        Divider()
        Button(anyVisible ? "Hide Group" : "Show Group") {
            dispatcher.execute(.setGroupVisibility(group.id, visible: !anyVisible, in: nil))
        }
        Button(group.isLocked ? "Unlock Group" : "Lock Group") {
            dispatcher.execute(.setGroupLocked(group.id, locked: !group.isLocked, in: nil))
        }
        Divider()
        Button("Delete Group and Layers", role: .destructive) {
            for member in members {
                dispatcher.execute(.removeLayer(member.id, in: nil))
            }
        }
    }

    // MARK: - Relink (C10, issue #79)

    /// The relink action for a layer bound to a registry source: pick a
    /// replacement device/display for the SOURCE DEFINITION — the S05
    /// registry update path (`SceneStore.relinkSource`) re-points every
    /// bound layer in every scene, and the controller's `$sources`
    /// observation re-keys the physical capture. Unbound layers (inline
    /// payload only) get no menu: there is no definition to re-point.
    @ViewBuilder
    private func relinkMenu(for layer: LayerNode) -> some View {
        if let sourceID = layer.sourceID,
           let definition = sceneStore.source(withID: sourceID) {
            switch definition.payload {
            case .camera:
                Menu("Relink Camera") {
                    Button("System Default Camera") {
                        sceneStore.relinkSource(sourceID, to: .camera(CameraSourcePayload()))
                    }
                    ForEach(deviceMonitor.videoDevices, id: \.uniqueID) { device in
                        Button(device.localizedName) {
                            sceneStore.relinkSource(
                                sourceID, to: .camera(CameraSourcePayload(deviceID: device.uniqueID)))
                        }
                    }
                }
                .help("Point \"\(definition.name)\" at a different camera — every layer using it follows.")
            case .screen:
                Menu("Relink Screen") {
                    ForEach(NSScreen.screens, id: \.streamDisplayID) { screen in
                        Button(screen.localizedName) {
                            if let displayID = screen.streamDisplayID {
                                sceneStore.relinkSource(
                                    sourceID,
                                    to: .screen(ScreenSourcePayload(
                                        target: .display,
                                        targetIdentifier: String(displayID))))
                            }
                        }
                    }
                }
                .help("Point \"\(definition.name)\" at a different display — every layer using it follows.")
            case .syphon:
                // C09 (issue #163): re-point at another DISCOVERED server
                // (the persisted identity is name+app, so the menu lists the
                // live directory, not stale registrations).
                Menu("Relink Syphon Server") {
                    if capturePool.syphonDiscovery.servers.isEmpty {
                        Button("No Syphon Servers Running") {}
                            .disabled(true)
                    }
                    ForEach(capturePool.syphonDiscovery.servers) { server in
                        Button(server.displayTitle) {
                            sceneStore.relinkSource(sourceID, to: .syphon(server.payload))
                        }
                    }
                }
                .help("Point \"\(definition.name)\" at a different Syphon server — every layer using it follows.")
            default:
                EmptyView()
            }
        }
    }

    // MARK: - Reordering

    private func isAtFront(_ layer: LayerNode, in scene: Scene) -> Bool {
        scene.layers.last?.id == layer.id
    }

    private func isAtBack(_ layer: LayerNode, in scene: Scene) -> Bool {
        scene.layers.first?.id == layer.id
    }

    /// Swaps the layer with its z-order neighbor. `toIndex` counts the
    /// post-removal array (the dispatcher's move semantics).
    private func move(_ layer: LayerNode, towardFront: Bool, in scene: Scene) {
        guard let index = scene.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        let target = towardFront ? index + 1 : index - 1
        guard scene.layers.indices.contains(target) else { return }
        dispatcher.execute(.moveLayer(layer.id, toIndex: target, group: layer.groupID, in: nil))
    }

    /// A drag's target index after its source row is removed (the dispatcher
    /// removes the layer, then inserts at `toIndex`).
    private func postRemovalIndex(of target: LayerID, removing dragged: LayerID,
                                  in scene: Scene) -> Int? {
        guard let targetIndex = scene.layers.firstIndex(where: { $0.id == target }),
              let sourceIndex = scene.layers.firstIndex(where: { $0.id == dragged })
        else { return nil }
        return sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
    }

    /// Dropping a layer onto a row moves it directly in FRONT of that row in
    /// z-order (display above) and adopts the row's group: dropping onto a
    /// group member joins that group, onto an ungrouped row ungroups, onto a
    /// group row enters the group at the front.
    private func handleDrop(_ payload: [String], onto row: RowID, in scene: Scene) -> Bool {
        guard let uuidString = payload.first,
              let uuid = UUID(uuidString: uuidString) else { return false }
        let dragged = LayerID(uuid)
        guard scene.layers.contains(where: { $0.id == dragged }) else { return false }

        let targetLayerID: LayerID
        let targetGroup: GroupID?
        switch row {
        case .layer(let layerID):
            guard layerID != dragged else { return false }
            targetLayerID = layerID
            targetGroup = scene.layers.first(where: { $0.id == layerID })?.groupID ?? nil
        case .group(let groupID):
            guard let frontmost = scene.members(of: groupID).last else { return false }
            guard frontmost.id != dragged else { return false }
            targetLayerID = frontmost.id
            targetGroup = groupID
        }
        guard let targetIndex = postRemovalIndex(of: targetLayerID, removing: dragged, in: scene)
        else { return false }

        // Skip the command when the drop is a true no-op (same slot, same
        // group) so it doesn't flag spurious unpublished edits.
        let sourceIndex = scene.layers.firstIndex(where: { $0.id == dragged }) ?? -1
        let finalIndex = min(targetIndex + 1, scene.layers.count - 1)
        let currentGroup = scene.layers.first(where: { $0.id == dragged })?.groupID ?? nil
        guard finalIndex != sourceIndex || currentGroup != targetGroup else { return false }

        dispatcher.execute(.moveLayer(dragged, toIndex: targetIndex + 1, group: targetGroup, in: nil))
        return true
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Menu {
                // C01 (issue #76): a camera layer binds an existing registry
                // source (each captures independently through the pool), or
                // the plain system-default camera — the pre-C01 behavior.
                Menu("Camera") {
                    ForEach(sceneStore.sources.filter { $0.payload.isCamera }) { source in
                        Button(source.name) {
                            addCameraLayer(boundTo: source)
                        }
                    }
                    if sceneStore.sources.contains(where: { $0.payload.isCamera }) {
                        Divider()
                    }
                    Button("Camera (System Default)") {
                        dispatcher.execute(.addLayer(.camera(CameraSourcePayload()), in: nil))
                    }
                }
                // C02 (issue #77): a screen layer binds an existing registry
                // source (each captures independently), or creates a new one
                // from the display/window/application picker. The plain
                // system-picker entry keeps the pre-C02 default behavior.
                Menu("Screen") {
                    ForEach(sceneStore.sources.filter { $0.payload.isScreen }) { source in
                        Button(source.name) {
                            addScreenLayer(boundTo: source)
                        }
                    }
                    if sceneStore.sources.contains(where: { $0.payload.isScreen }) {
                        Divider()
                    }
                    Button("New Screen Source…") {
                        screenSourcePickerPresented = true
                    }
                    Button("Screen (System Picker)") {
                        dispatcher.execute(.addLayer(.screen(ScreenSourcePayload()), in: nil))
                    }
                }
                Divider()
                // C09 (issue #163): a syphon layer binds a registered Syphon
                // source; servers are discovered and registered from the
                // Sources tab (they can't be picked from a static menu —
                // the directory is live).
                Menu("Syphon") {
                    ForEach(sceneStore.sources.filter { $0.payload.isSyphon }) { source in
                        Button(source.name) {
                            addSyphonLayer(boundTo: source)
                        }
                    }
                    if !sceneStore.sources.contains(where: { $0.payload.isSyphon }) {
                        Button("No Syphon Sources — add one from the Sources tab") {}
                            .disabled(true)
                    }
                }
                Divider()
                // S07: text and shape render now (generated by the compositor).
                Button("Text") {
                    dispatcher.execute(.addLayer(.text(TextSourcePayload(text: "Text")), in: nil))
                }
                Button("Shape") {
                    dispatcher.execute(.addLayer(.shape(ShapeSourcePayload()), in: nil))
                }
                Divider()
                // S06: nest another scene as a reusable layer. Cycle/depth
                // validation is the dispatcher's — a rejection surfaces its
                // plain-language reason in the diagnostics strip.
                Menu("Scene") {
                    ForEach(sceneStore.scenes) { scene in
                        Button(scene.name) {
                            dispatcher.execute(.addLayer(.scene(SceneReferencePayload(sceneID: scene.id)), in: nil))
                        }
                    }
                }
                Divider()
                // Model-only kinds persist in the graph but the render path
                // can't paint them yet — listed disabled and clearly marked.
                ForEach(modelOnlyKinds, id: \.displayName) { payload in
                    Button("\(payload.displayName) (not rendered yet)") {}
                        .disabled(true)
                }
            } label: {
                Label("Add Layer", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Add a layer at the front of the scene")

            Spacer()

            Button {
                dispatcher.execute(.groupLayers(Array(sceneStore.selectedLayerIDs), named: nil, in: nil))
            } label: {
                Label("Group", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .disabled(!dispatcher.canExecute(.groupLayers(Array(sceneStore.selectedLayerIDs), named: nil, in: nil)))
            .help("Group the selected layers")
        }
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Every payload kind the render path cannot composite yet.
    private var modelOnlyKinds: [LayerPayload] {
        [
            .image(ImageSourcePayload()),
            .media(MediaSourcePayload()),
            .pdf(PDFSourcePayload()),
            .web(WebSourcePayload()),
            .guest(GuestSourcePayload()),
        ]
    }

    // MARK: - Source-bound camera layers (C01, issue #76)

    /// Adds a camera layer bound to `source` at the front of the staged
    /// scene — fullscreen when the scene has no camera yet, a PIP when one
    /// is already placed (so the new camera never covers it). Routes through
    /// `.updateScene` (the dispatcher's lock and undo path) rather than
    /// `.addLayer`, which would auto-bind the FIRST registered camera source
    /// — wrong once several camera sources coexist.
    private func addCameraLayer(boundTo source: SourceDefinition) {
        guard var scene = previewProgram.stagedScene else { return }
        var layer = scene.layers.contains(where: { $0.payload.isCamera })
            ? LayerNode.cameraPIP(corner: .bottomRight, scale: 0.28, sourceID: source.id)
            : LayerNode.fullscreenCamera(sourceID: source.id)
        layer.name = source.name
        layer.payload = source.payload
        scene.layers.append(layer)
        dispatcher.execute(.updateScene(scene))
    }

    // MARK: - Source-bound screen layers (C02, issue #77)

    /// Adds a fullscreen screen layer bound to `source` at the front of the
    /// staged scene. Routes through `.updateScene` (the dispatcher's lock and
    /// undo path) rather than `.addLayer`, which would auto-bind the FIRST
    /// registered screen source — wrong once several screen sources coexist.
    private func addScreenLayer(boundTo source: SourceDefinition) {
        guard var scene = previewProgram.stagedScene else { return }
        var layer = LayerNode.fullscreenScreen(sourceID: source.id)
        layer.name = source.name
        layer.payload = source.payload
        scene.layers.append(layer)
        dispatcher.execute(.updateScene(scene))
    }

    // MARK: - Source-bound Syphon layers (C09, issue #163)

    /// Adds a fullscreen layer bound to a registered Syphon `source` at the
    /// front of the staged scene. Routes through `.updateScene` (the
    /// dispatcher's lock and undo path), exactly like the camera/screen
    /// variants.
    private func addSyphonLayer(boundTo source: SourceDefinition) {
        guard var scene = previewProgram.stagedScene else { return }
        let layer = LayerNode(name: source.name, sourceID: source.id,
                              payload: source.payload, transform: .fullscreen)
        scene.layers.append(layer)
        dispatcher.execute(.updateScene(scene))
    }

    // MARK: - Rename alert

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })
    }

    private func commitRename() {
        switch renameTarget {
        case .layer(let layer):
            dispatcher.execute(.renameLayer(layer.id, to: draftName, in: nil))
        case .group(let group):
            dispatcher.execute(.renameGroup(group.id, to: draftName, in: nil))
        case nil:
            break
        }
    }
}

/// C10 (issue #79): the CoreGraphics display ID backing an `NSScreen` — the
/// same stable identifier a `ScreenSourcePayload` pins, so the relink menu
/// can re-point a display source without ScreenCaptureKit (and without
/// needing Screen Recording permission to enumerate).
private extension NSScreen {
    var streamDisplayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
