import AppKit
import Foundation
import Combine
import StreamCore

/// The classic three-layout view of a scene, now derived from (and applied
/// back onto) the layer graph — see the `Scene` extension below. Kept as the
/// compatibility surface for the fixed-layout UI and render path while the
/// graph model underneath is the source of truth.
enum SceneLayout: String, Codable, CaseIterable, Sendable {
    case cameraSolo, screenSolo, screenPlusCam

    var displayName: String {
        switch self {
        case .cameraSolo: return "Camera"
        case .screenSolo: return "Screen"
        case .screenPlusCam: return "Screen + Cam"
        }
    }

    var usesScreen: Bool {
        switch self {
        case .screenSolo, .screenPlusCam: return true
        case .cameraSolo: return false
        }
    }

    var usesCamera: Bool {
        switch self {
        case .cameraSolo, .screenPlusCam: return true
        case .screenSolo: return false
        }
    }
}

extension Scene {
    /// The topmost camera layer that is a PIP box (anything not fullscreen).
    /// Visibility is ignored so PIP geometry survives layout switches.
    private var cameraPIPIndex: Int? {
        layers.lastIndex(where: { $0.payload.isCamera && $0.transform.size.width < 1 })
    }

    /// The fixed-layout equivalent of the graph: which visible sources the
    /// scene composites. Setting it rebuilds the visible layers for that
    /// layout, reusing existing layers (and their source bindings) and
    /// keeping a hidden PIP layer so corner/size survive layout switches —
    /// the v1 model stored those fields unconditionally.
    var layout: SceneLayout {
        get {
            let hasScreen = layers.contains { $0.isVisible && $0.payload.isScreen }
            let hasCamera = layers.contains { $0.isVisible && $0.payload.isCamera }
            switch (hasScreen, hasCamera) {
            case (true, true): return .screenPlusCam
            case (true, false): return .screenSolo
            default: return .cameraSolo
            }
        }
        set {
            let cameraSourceID = layers.first(where: { $0.payload.isCamera })?.sourceID
            let screen = layers.first(where: { $0.payload.isScreen })
                ?? .fullscreenScreen(sourceID: nil)
            var pip = cameraPIPIndex.map { layers[$0] }
                ?? .cameraPIP(corner: .bottomRight, scale: 0.28, sourceID: cameraSourceID)

            switch newValue {
            case .cameraSolo:
                pip.isVisible = false
                layers = [layers.first(where: { $0.payload.isCamera && $0.transform.size.width >= 1 })
                            ?? .fullscreenCamera(sourceID: cameraSourceID), pip]
            case .screenSolo:
                pip.isVisible = false
                layers = [screen, pip]
            case .screenPlusCam:
                pip.isVisible = true
                layers = [screen, pip]
            }
        }
    }

    /// The PIP corner of the camera overlay (`.bottomRight` when the scene
    /// has no camera PIP layer). Only meaningful for `.screenPlusCam`.
    var pipCorner: PIPCorner {
        get {
            cameraPIPIndex.map { PIPCorner(anchor: layers[$0].transform.anchor) } ?? .bottomRight
        }
        set {
            guard let index = cameraPIPIndex else { return }
            layers[index].transform = LayerTransform(pipCorner: newValue,
                                                     scale: layers[index].transform.size.width)
        }
    }

    /// The PIP size as a fraction of frame width (0.10...0.40), or the
    /// classic default when the scene has no camera PIP layer.
    var pipScale: Double {
        get {
            cameraPIPIndex.map { layers[$0].transform.size.width } ?? 0.28
        }
        set {
            guard let index = cameraPIPIndex else { return }
            layers[index].transform = LayerTransform(pipCorner: pipCorner, scale: newValue)
        }
    }
}

// MARK: - Scene browser model (S02, issue #70)
//
// Folders, membership, and locks are BROWSER-side organization metadata: they
// live in `SceneStore` (not in the layer graph), apply immediately rather
// than staging through preview/program, and persist in their own additive
// document beside the v2 scene document, so the LayerGraph wire format is
// untouched.

enum SceneFolderTag {}
typealias SceneFolderID = GraphID<SceneFolderTag>

/// A named folder grouping scenes in the browser. Membership is a
/// `SceneID → SceneFolderID` map on `SceneStore`, keeping the scene list
/// itself flat and ordered.
struct SceneFolder: Identifiable, Hashable, Codable, Sendable {
    var id: SceneFolderID
    var name: String
    var isCollapsed: Bool

    init(id: SceneFolderID = SceneFolderID(), name: String, isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
    }

    /// `isCollapsed` may be absent in older browser files; decode it with a
    /// default so they keep loading (additive wire change).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SceneFolderID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isCollapsed = try container.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
    }
}

/// One top-level row of the scene browser: an unfiled scene, or a folder
/// (whose members render beneath it when expanded).
enum SceneBrowserRow: Identifiable, Hashable, Sendable {
    case folder(SceneFolder)
    case scene(Scene)

    var id: String {
        switch self {
        case .folder(let folder): return "folder:\(folder.id.rawValue.uuidString)"
        case .scene(let scene): return "scene:\(scene.id.rawValue.uuidString)"
        }
    }
}

/// The persisted browser state (folders, membership, locks). Every field
/// decodes with a default so older/partial files keep loading.
struct SceneBrowserDocument: Hashable, Codable, Sendable {
    static let currentVersion = 1

    var version: Int
    var folders: [SceneFolder]
    var membership: [SceneID: SceneFolderID]
    var lockedSceneIDs: [SceneID]

    init(version: Int = SceneBrowserDocument.currentVersion,
         folders: [SceneFolder],
         membership: [SceneID: SceneFolderID],
         lockedSceneIDs: [SceneID]) {
        self.version = version
        self.folders = folders
        self.membership = membership
        self.lockedSceneIDs = lockedSceneIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version)
            ?? SceneBrowserDocument.currentVersion
        folders = try container.decodeIfPresent([SceneFolder].self, forKey: .folders) ?? []
        membership = try container.decodeIfPresent([SceneID: SceneFolderID].self, forKey: .membership) ?? [:]
        lockedSceneIDs = try container.decodeIfPresent([SceneID].self, forKey: .lockedSceneIDs) ?? []
    }
}

/// The scene list + selection, persisted as the versioned `SceneDocument`
/// (v2) in the shared App Group container (same storage pattern as
/// `SettingsStore`: a plain file, never the UserDefaults suite, so
/// `cfprefsd` stays quiet). On first launch after the upgrade, an existing
/// v1 file is migrated once and left on disk untouched.
@MainActor
final class SceneStore: ObservableObject {
    @Published var scenes: [Scene] {
        didSet { scheduleSceneAutosave() }
    }
    @Published var selectedID: Scene.ID {
        didSet { scheduleSceneAutosave() }
    }
    /// S03: the layer panel's selection within the staged scene, keyed by
    /// stable LayerID. Ephemeral view state (never persisted); S04's canvas
    /// multi-select reads and writes the same set so the panel and canvas
    /// stay synchronized.
    @Published var selectedLayerIDs: Set<LayerID> = []
    /// Project-level reusable sources that layers bind to via `sourceID`.
    @Published private(set) var sources: [SourceDefinition] {
        didSet { scheduleSceneAutosave() }
    }
    /// S07: project-wide overlays (back-to-front), stored once at document
    /// level and composited above every scene's layers. Mutated only through
    /// the dispatcher's project-level overlay commands.
    @Published private(set) var overlays: [LayerNode] {
        didSet { scheduleSceneAutosave() }
    }
    /// S07: the project default background for scenes without their own.
    @Published private(set) var defaultBackground: SceneBackground? {
        didSet { scheduleSceneAutosave() }
    }
    /// S09 (issue #100): the project default transition for Takes into
    /// scenes without their own `transition` override. Project-level:
    /// applies immediately, like the default background.
    @Published private(set) var defaultTransition: SceneTransition {
        didSet { scheduleSceneAutosave() }
    }
    /// S02 browser metadata: folders, scene → folder membership, and scene
    /// locks. Immediate (never staged), persisted in the browser document.
    @Published private(set) var folders: [SceneFolder] = [] {
        didSet { scheduleBrowserAutosave() }
    }
    @Published private(set) var sceneMembership: [SceneID: SceneFolderID] = [:] {
        didSet { scheduleBrowserAutosave() }
    }
    /// Locked scenes reject edits, deletion, and reordering via the
    /// dispatcher (the lock toggle itself stays available).
    @Published private(set) var lockedSceneIDs: Set<SceneID> = [] {
        didSet { scheduleBrowserAutosave() }
    }
    private var projectID: ProjectID
    private var projectName: String

    // S12 autosave: pending debounced writes (see "Autosave" below).
    private var sceneAutosaveTask: Task<Void, Never>?
    private var browserAutosaveTask: Task<Void, Never>?
    /// `nonisolated(unsafe)` so `deinit` can unregister it (the store lives
    /// for the app's lifetime; this is belt-and-braces).
    nonisolated(unsafe) private var terminationObserver: NSObjectProtocol?

    private static let fileNameV2 = "stream.scenes.v2.json"
    private static let fileNameV1 = "stream.scenes.v1.json"
    private static let browserFileName = "stream.sceneBrowser.v1.json"

    init() {
        // S12: every candidate file goes through the migration pipeline —
        // unreadable or newer-than-supported files are quarantined aside
        // (never crash-loop, never overwritten) before falling back.
        let document = Self.loadDocument().flatMap { $0.scenes.isEmpty ? nil : $0 }
            ?? SceneDocument.makeDefault()
        projectID = document.projectID
        projectName = document.projectName
        sources = document.sources
        overlays = document.overlays
        defaultBackground = document.defaultBackground
        defaultTransition = document.defaultTransition
        scenes = document.scenes
        selectedID = document.scenes.contains(where: { $0.id == document.selectedID })
            ? document.selectedID
            : document.scenes[0].id
        let browser = Self.loadBrowser()
        folders = browser.folders
        sceneMembership = browser.membership
        lockedSceneIDs = Set(browser.lockedSceneIDs)
        pruneBrowserMetadata()
        normalizeOrder()
        ProjectOverlayStore.shared.publish(document.overlayContext)
        SceneRegistryStore.shared.publish(document.scenes)
        writeSceneDocument()
        writeBrowserDocument()
        // Flush any pending debounced autosave on quit. willTerminate is
        // posted on the main thread, so the flush runs synchronously.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushPendingWrites() }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    /// The whole persisted model, for consumers that work at document level.
    var document: SceneDocument {
        SceneDocument(projectID: projectID,
                      projectName: projectName,
                      sources: sources,
                      scenes: scenes,
                      selectedID: selectedID,
                      overlays: overlays,
                      defaultBackground: defaultBackground,
                      defaultTransition: defaultTransition)
    }

    var selected: Scene? {
        scenes.first(where: { $0.id == selectedID })
    }

    private var cameraSourceID: SourceDefinitionID? {
        sources.first(where: { $0.payload.isCamera })?.id
    }

    private var screenSourceID: SourceDefinitionID? {
        sources.first(where: { $0.payload.isScreen })?.id
    }

    // MARK: - Source registry (S05, issue #73)
    //
    // `sources` is the project-level registry: layers across every scene bind
    // to a `SourceDefinition` by ID, so a rename or reconfiguration here
    // reaches every layer that uses the source. Capture lifetime follows from
    // demand — StreamController's pool resolves visible layers through this
    // registry and keys physical captures by the definition's payload.

    /// Looks up a reusable source by ID.
    func source(withID id: SourceDefinitionID) -> SourceDefinition? {
        sources.first(where: { $0.id == id })
    }

    /// Every scene containing at least one layer bound to `id` — the
    /// "referenced by these scenes" list the source UI displays.
    func scenesReferencing(_ id: SourceDefinitionID) -> [Scene] {
        scenes.filter { $0.layers.contains(where: { $0.sourceID == id }) }
    }

    /// Registers a new reusable source (the future source-adding UI's write
    /// path) and returns it.
    @discardableResult
    func addSource(_ source: SourceDefinition) -> SourceDefinition {
        sources.append(source)
        return source
    }

    /// Renames a source. Layers reference sources by ID, so every layer in
    /// every scene picks the new name up through the registry.
    func renameSource(_ id: SourceDefinitionID, to name: String) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].name = name
    }

    /// Reconfigures a source (a different camera device, display, window, …).
    /// The registry is the identity authority; the new payload is also pushed
    /// into every bound layer's inline payload (the render authority) so
    /// self-contained scene documents stay consistent with the registry.
    func updateSource(_ source: SourceDefinition) {
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[index] = source
        for sceneIndex in scenes.indices {
            for layerIndex in scenes[sceneIndex].layers.indices
            where scenes[sceneIndex].layers[layerIndex].sourceID == source.id {
                scenes[sceneIndex].layers[layerIndex].payload = source.payload
            }
        }
    }

    /// C10 (issue #79): the relink write path — re-points a source at a
    /// replacement device/display when its original identity can't be
    /// restored (the device is gone for good). Routes through `updateSource`,
    /// so every bound layer in every scene follows, and the controller's
    /// `$sources` observation re-keys the physical capture. Kind-mismatched
    /// payloads are rejected: a camera source only takes a camera payload.
    func relinkSource(_ id: SourceDefinitionID, to payload: LayerPayload) {
        guard var definition = source(withID: id) else { return }
        switch (definition.payload, payload) {
        case (.camera, .camera), (.screen, .screen), (.syphon, .syphon), (.media, .media),
             (.appAudio, .appAudio):
            break
        default:
            return
        }
        definition.payload = payload
        updateSource(definition)
    }

    /// Removes a source from the registry. Bound layers keep their inline
    /// payload (the render authority) and simply become unbound, so their
    /// rendered content is unchanged until re-pointed.
    func removeSource(_ id: SourceDefinitionID) {
        sources.removeAll { $0.id == id }
        for sceneIndex in scenes.indices {
            for layerIndex in scenes[sceneIndex].layers.indices
            where scenes[sceneIndex].layers[layerIndex].sourceID == id {
                scenes[sceneIndex].layers[layerIndex].sourceID = nil
            }
        }
    }

    // MARK: - Project overlays and default background (S07, issue #74)
    //
    // Overlays are PROJECT-level content: one list, composited above every
    // scene's layers, edited in one place. Edits apply immediately (they are
    // not part of any scene's staged snapshot) and reach the engines through
    // `ProjectOverlayStore`, which `persist()` republishes. Per-scene overlay
    // visibility overrides live on the scenes themselves
    // (`Scene.hiddenOverlayIDs`) and follow the normal staged→program path —
    // removing an overlay also prunes those overrides so no scene keeps a
    // dangling reference.

    /// Appends an overlay at the FRONT of the project overlay stack.
    @discardableResult
    func addOverlay(_ overlay: LayerNode) -> LayerNode {
        overlays.append(overlay)
        return overlay
    }

    /// Replaces an overlay in place (rename, visibility, lock, transform,
    /// effects edits write back the mutated copy through here).
    func updateOverlay(_ overlay: LayerNode) {
        guard let index = overlays.firstIndex(where: { $0.id == overlay.id }) else { return }
        overlays[index] = overlay
    }

    /// Moves an overlay to `toIndex` in the back-to-front array (index as
    /// counted AFTER removing the overlay — same semantics as layer moves).
    func moveOverlay(_ id: LayerID, toIndex: Int) {
        guard let index = overlays.firstIndex(where: { $0.id == id }) else { return }
        let overlay = overlays.remove(at: index)
        overlays.insert(overlay, at: min(toIndex, overlays.count))
    }

    /// Removes an overlay and prunes every scene's per-scene override of it.
    func removeOverlay(_ id: LayerID) {
        overlays.removeAll { $0.id == id }
        for sceneIndex in scenes.indices {
            scenes[sceneIndex].hiddenOverlayIDs.remove(id)
        }
    }

    /// Sets the project default background (nil = the documented black
    /// fallback for scenes without their own background).
    func setDefaultBackground(_ background: SceneBackground?) {
        defaultBackground = background
    }

    /// S09 (issue #100): sets the project default transition (Takes into
    /// scenes without their own `transition` override render it).
    func setDefaultTransition(_ transition: SceneTransition) {
        defaultTransition = transition
    }

    /// Adds a default scene (same template as the scenes panel's + button)
    /// and selects it.
    @discardableResult
    func addScene() -> Scene {
        addScene(Scene.screenPlusCam(name: "Scene \(scenes.count + 1)",
                                     screenSourceID: screenSourceID,
                                     cameraSourceID: cameraSourceID))
    }

    /// Appends a fully-formed scene (built from the `Scene` factories — e.g.
    /// the W06 first-run sample scene) and selects it.
    @discardableResult
    func addScene(_ scene: Scene) -> Scene {
        scenes.append(scene)
        selectedID = scene.id
        return scene
    }

    func rename(_ id: Scene.ID, to name: String) {
        guard let index = scenes.firstIndex(where: { $0.id == id }) else { return }
        scenes[index].name = name
    }

    func delete(_ id: Scene.ID) {
        guard scenes.count > 1 else { return }   // never leave zero scenes
        scenes.removeAll { $0.id == id }
        sceneMembership.removeValue(forKey: id)
        lockedSceneIDs.remove(id)
        if !scenes.contains(where: { $0.id == selectedID }) {
            selectedID = scenes[0].id
        }
    }

    func update(_ scene: Scene) {
        guard let index = scenes.firstIndex(where: { $0.id == scene.id }) else { return }
        scenes[index] = scene
    }

    /// Aligns every scene's canvas reference size with the output profile's
    /// canvas (W07): transforms are normalized to the canvas, so this records
    /// the new aspect/resolution intent only — no layer is repositioned.
    func setCanvasSize(_ size: CGSize) {
        let reference = GraphSize(width: Double(size.width), height: Double(size.height))
        guard scenes.contains(where: { $0.canvas.referenceSize != reference }) else { return }
        scenes = scenes.map { scene in
            var scene = scene
            scene.canvas.referenceSize = reference
            return scene
        }
    }

    /// Selects the scene at 1-based position `number` (⌘1…⌘9), if it exists.
    func select(number: Int) {
        let index = number - 1
        guard scenes.indices.contains(index) else { return }
        selectedID = scenes[index].id
    }

    // MARK: - Scene browser (S02, issue #70)
    //
    // The browser's manual order IS the `scenes` array order:
    // `normalizeOrder()` keeps every folder's members contiguous (each block
    // anchored at its first member), so expanding every browser row
    // reproduces the flat array exactly — which is what `select(number:)`
    // reads, keeping ⌘1…⌘9 position-valid no matter how the browser is
    // rearranged.

    func scene(withID id: SceneID) -> Scene? {
        scenes.first(where: { $0.id == id })
    }

    func isLocked(_ id: SceneID) -> Bool {
        lockedSceneIDs.contains(id)
    }

    func setSceneLocked(_ id: SceneID, locked: Bool) {
        guard scenes.contains(where: { $0.id == id }) else { return }
        if locked {
            lockedSceneIDs.insert(id)
        } else {
            lockedSceneIDs.remove(id)
        }
    }

    /// The folder a scene is filed in, if the membership resolves.
    func folder(containing id: SceneID) -> SceneFolder? {
        guard let folderID = sceneMembership[id] else { return nil }
        return folders.first(where: { $0.id == folderID })
    }

    /// Members of a folder in display order.
    func members(of folderID: SceneFolderID) -> [Scene] {
        scenes.filter { sceneMembership[$0.id] == folderID }
    }

    /// Scenes with no folder, in display order (the top-level siblings a
    /// drag targets when moving a scene out of a folder).
    var unfiledScenes: [Scene] {
        scenes.filter { sceneMembership[$0.id] == nil }
    }

    /// The browser's top-level rows in display order: unfiled scenes in
    /// `scenes` order, each folder at its first member's position, and empty
    /// folders last (they have no member to anchor to).
    var browserRows: [SceneBrowserRow] {
        var rows: [SceneBrowserRow] = []
        var emitted: Set<SceneFolderID> = []
        for scene in scenes {
            guard let folderID = sceneMembership[scene.id],
                  let folder = folders.first(where: { $0.id == folderID }) else {
                rows.append(.scene(scene))
                continue
            }
            if emitted.insert(folderID).inserted {
                rows.append(.folder(folder))
            }
        }
        for folder in folders where !emitted.contains(folder.id) {
            rows.append(.folder(folder))
        }
        return rows
    }

    @discardableResult
    func addFolder(named name: String? = nil) -> SceneFolder {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let folder = SceneFolder(name: trimmed.isEmpty ? "Folder \(folders.count + 1)" : trimmed)
        folders.append(folder)
        return folder
    }

    func renameFolder(_ id: SceneFolderID, to name: String) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = name
    }

    /// Removes the folder only; its scenes become unfiled and keep their
    /// relative order.
    func deleteFolder(_ id: SceneFolderID) {
        folders.removeAll { $0.id == id }
        sceneMembership = sceneMembership.filter { $0.value != id }
    }

    func setFolderCollapsed(_ id: SceneFolderID, collapsed: Bool) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].isCollapsed = collapsed
    }

    /// Copies a scene (new stable scene/layer/group/canvas IDs, so nothing
    /// aliases the original) and inserts it right after the original in the
    /// same folder. Mirrors the layer-panel rule: a locked original still
    /// duplicates, and the copy starts unlocked.
    @discardableResult
    func duplicateScene(_ id: SceneID) -> Scene? {
        guard let index = scenes.firstIndex(where: { $0.id == id }) else { return nil }
        let original = scenes[index]
        var groupIDs: [GroupID: GroupID] = [:]
        let groups = original.groups.map { group -> LayerGroup in
            var copy = group
            let newID = GroupID()
            groupIDs[group.id] = newID
            copy.id = newID
            return copy
        }
        let layers = original.layers.map { layer -> LayerNode in
            var copy = layer
            copy.id = LayerID()
            copy.groupID = layer.groupID.flatMap { groupIDs[$0] }
            return copy
        }
        var canvas = original.canvas
        canvas.id = CanvasID()
        // A03 (issue #98): sound bindings copy with FRESH IDs (new mix
        // channels), exactly like layers — nothing aliases the original.
        let soundBindings = original.soundBindings.map { binding -> SceneSoundBinding in
            var copy = binding
            copy.id = SourceDefinitionID()
            return copy
        }
        let copy = Scene(name: "\(original.name) copy", canvas: canvas, groups: groups,
                         layers: layers, soundBindings: soundBindings,
                         // S08 (issue #99): the audio snapshot and media
                         // behavior are plain values (no channel-identity
                         // aliasing), so they copy verbatim.
                         audioSnapshot: original.audioSnapshot,
                         mediaBehavior: original.mediaBehavior,
                         // S09 (issue #100): the transition override is a
                         // plain value too — it copies verbatim.
                         transition: original.transition)
        scenes.insert(copy, at: index + 1)
        if let folderID = sceneMembership[id] {
            sceneMembership[copy.id] = folderID
        }
        normalizeOrder()
        return copy
    }

    /// Moves a scene in the browser: `folderID` re-files it (nil = top
    /// level); `anchorID` places it directly ahead of that sibling, nil lands
    /// it at the end of the destination folder (or the end of the list when
    /// unfiled). Validation (existence, locks) is the dispatcher's job.
    func moveScene(_ id: SceneID, toFolder folderID: SceneFolderID?, before anchorID: SceneID?) {
        guard let scene = scenes.first(where: { $0.id == id }) else { return }
        if let folderID {
            guard folders.contains(where: { $0.id == folderID }) else { return }
            sceneMembership[id] = folderID
        } else {
            sceneMembership.removeValue(forKey: id)
        }
        scenes.removeAll { $0.id == id }
        if let anchorID, let anchorIndex = scenes.firstIndex(where: { $0.id == anchorID }) {
            scenes.insert(scene, at: anchorIndex)
        } else if let folderID,
                  let lastMember = scenes.lastIndex(where: { sceneMembership[$0.id] == folderID }) {
            scenes.insert(scene, at: lastMember + 1)
        } else {
            scenes.append(scene)
        }
        normalizeOrder()
    }

    /// Keeps every folder's members contiguous in `scenes` (each block
    /// anchored at its first member's current position), preserving relative
    /// order — the invariant that makes the flat array order equal the
    /// browser's visual order.
    private func normalizeOrder() {
        var ordered: [Scene] = []
        var placedFolders: Set<SceneFolderID> = []
        for scene in scenes {
            guard let folderID = sceneMembership[scene.id] else {
                ordered.append(scene)
                continue
            }
            if placedFolders.insert(folderID).inserted {
                ordered.append(contentsOf: scenes.filter { sceneMembership[$0.id] == folderID })
            }
        }
        if ordered != scenes {
            scenes = ordered
        }
    }

    /// Drops browser metadata whose scene or folder no longer exists (e.g. an
    /// older browser file loaded against a migrated scene document).
    private func pruneBrowserMetadata() {
        let sceneIDs = Set(scenes.map(\.id))
        let folderIDs = Set(folders.map(\.id))
        sceneMembership = sceneMembership.filter {
            sceneIDs.contains($0.key) && folderIDs.contains($0.value)
        }
        lockedSceneIDs = lockedSceneIDs.intersection(sceneIDs)
    }

    // MARK: - Undo snapshots (S12, issue #75)
    //
    // The dispatcher snapshots this state around every undoable command (see
    // SceneUndoStack.swift). Snapshots are plain values; restoring one writes
    // the document and browser state back through the normal properties, so
    // autosave and the overlay-store republication happen as usual. The
    // PROGRAM snapshot is not part of this state and is never touched by a
    // restore — undo lands on the staged model only.

    /// Everything undo captures about the store.
    func captureUndoSnapshot(stagedScene: Scene?) -> SceneUndoSnapshot {
        SceneUndoSnapshot(scenes: scenes,
                          selectedID: selectedID,
                          overlays: overlays,
                          defaultBackground: defaultBackground,
                          defaultTransition: defaultTransition,
                          folders: folders,
                          sceneMembership: sceneMembership,
                          lockedSceneIDs: lockedSceneIDs,
                          stagedScene: stagedScene)
    }

    /// Writes a captured snapshot back. Browser metadata is re-pruned and the
    /// order re-normalized so a snapshot can never resurrect dangling
    /// references (same invariants as a fresh load).
    func restoreUndoSnapshot(_ snapshot: SceneUndoSnapshot) {
        guard !snapshot.scenes.isEmpty else { return }
        scenes = snapshot.scenes
        selectedID = scenes.contains(where: { $0.id == snapshot.selectedID })
            ? snapshot.selectedID
            : scenes[0].id
        overlays = snapshot.overlays
        defaultBackground = snapshot.defaultBackground
        defaultTransition = snapshot.defaultTransition
        folders = snapshot.folders
        sceneMembership = snapshot.sceneMembership
        lockedSceneIDs = snapshot.lockedSceneIDs
        pruneBrowserMetadata()
        normalizeOrder()
    }

    // MARK: - Persistence
    //
    // S12 (issue #75): loading runs every candidate file through the
    // `SceneDocumentMigration` pipeline. A file that decodes at the current
    // version loads; an older file migrates hop-by-hop; a CORRUPT file or one
    // written by a NEWER app version is quarantined aside (moved to a
    // timestamped .bak next to the original, so the bytes are never
    // destroyed) and the store falls back to the next candidate, then to the
    // default document — recovery never crash-loops and never overwrites data
    // it couldn't read.

    private static func fileURL(_ fileName: String) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
            .appendingPathComponent(fileName)
    }

    /// Loads the scene document from the newest readable candidate: the
    /// current-version file first (migrating it if it somehow holds older
    /// bytes), then the v1 file (migrated v1 → v2 and left untouched on disk,
    //  which keeps it as the readable pre-migration snapshot).
    private static func loadDocument() -> SceneDocument? {
        let candidates: [(url: URL?, isCurrentFile: Bool)] = [
            (fileURL(fileNameV2), true),
            (fileURL(fileNameV1), false)
        ]
        for (candidate, isCurrentFile) in candidates {
            guard let url = candidate, let data = try? Data(contentsOf: url) else { continue }
            switch SceneDocumentMigration.migrateToCurrent(data) {
            case .success(let migrated):
                guard let document = try? JSONDecoder().decode(SceneDocument.self, from: migrated) else {
                    quarantine(url, reason: "corrupt")
                    continue
                }
                // Migrating older bytes held in the SAME file autosave
                // overwrites: keep a readable copy of the pre-migration
                // document beside it first. (The v1 file is never overwritten
                // — it IS its own prior snapshot.)
                if isCurrentFile,
                   let version = SceneDocumentMigration.detectedVersion(of: data),
                   version < SceneDocumentMigration.currentVersion {
                    copyAside(url, suffix: "v\(version)-pre-migration")
                }
                return document
            case .failure(.newerThanSupported(let found, _)):
                // Written by a newer app: preserve every byte and fall back
                // rather than decode-guess and autosave over the user's data.
                quarantine(url, reason: "unsupported-v\(found)")
            case .failure(.unreadable):
                quarantine(url, reason: "corrupt")
            }
        }
        return nil
    }

    /// Moves an unreadable/unsupported file aside so recovery falls back
    /// cleanly and the original bytes stay recoverable next to it.
    private static func quarantine(_ url: URL, reason: String) {
        try? FileManager.default.moveItem(
            at: url, to: url.appendingPathExtension("\(reason).\(backupStamp()).bak"))
    }

    /// Copies a pre-migration document aside before autosave replaces it.
    private static func copyAside(_ url: URL, suffix: String) {
        try? FileManager.default.copyItem(
            at: url, to: url.appendingPathExtension("\(suffix).\(backupStamp()).bak"))
    }

    private static func backupStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func loadBrowser() -> SceneBrowserDocument {
        let empty = SceneBrowserDocument(folders: [], membership: [:], lockedSceneIDs: [])
        guard let url = fileURL(browserFileName),
              let data = try? Data(contentsOf: url) else { return empty }
        guard let document = try? JSONDecoder().decode(SceneBrowserDocument.self, from: data) else {
            quarantine(url, reason: "corrupt")
            return empty
        }
        return document
    }

    // MARK: - Autosave (S12, issue #75)
    //
    // Persistence is a DEBOUNCED AUTOSAVE: every mutation schedules a write
    // `autosaveDelay` out, and further mutations within the window replace
    // (not queue) it, so a burst of edits costs one encode+write. Writes are
    // atomic — Foundation stages the data in a temp file and renames it over
    // the original, so a crash mid-write can never leave a torn document;
    // an interrupted write leaves either the old or the new file, both
    // decodable. `flushPendingWrites()` (app termination) forces any pending
    // write out synchronously.

    private static let autosaveDelay: TimeInterval = 0.75

    private func scheduleSceneAutosave() {
        // The live path never waits for the debounce: republish the
        // project-level composition context synchronously, so the engines
        // composite overlay/background edits on their next tick (they apply
        // immediately to staged AND program). Published first so a failed
        // file write never stalls the live path.
        ProjectOverlayStore.shared.publish(document.overlayContext)
        // S06: the scene registry the engines resolve nested-scene references
        // against — same synchronous-publish rationale. Since only TAKEN
        // edits persist through the store, this is exactly the Take-policy
        // propagation of shared child-scene edits to every nesting site.
        SceneRegistryStore.shared.publish(scenes)
        // C01 (issue #76): the source payload index the engines resolve a
        // bound layer's capture identity against (per-source frame routing).
        SourcePayloadStore.shared.publish(sources)
        sceneAutosaveTask?.cancel()
        sceneAutosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autosaveDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.writeSceneDocument()
        }
    }

    private func scheduleBrowserAutosave() {
        browserAutosaveTask?.cancel()
        browserAutosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autosaveDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.writeBrowserDocument()
        }
    }

    /// Writes any pending debounced autosaves NOW (app termination).
    func flushPendingWrites() {
        sceneAutosaveTask?.cancel()
        browserAutosaveTask?.cancel()
        writeSceneDocument()
        writeBrowserDocument()
    }

    private func writeSceneDocument() {
        guard let url = Self.fileURL(Self.fileNameV2),
              let data = try? JSONEncoder().encode(document) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func writeBrowserDocument() {
        let document = SceneBrowserDocument(folders: folders,
                                            membership: sceneMembership,
                                            lockedSceneIDs: Array(lockedSceneIDs))
        guard let url = Self.fileURL(Self.browserFileName),
              let data = try? JSONEncoder().encode(document) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// S12 (issue #75): the undoable state the dispatcher snapshots around every
/// scene-edit command — the persisted document state, the browser
/// organization, and the STAGED scene. Deliberately excludes the program
/// snapshot (undo must never rewrite live output) and ephemeral view state
/// (layer selection).
struct SceneUndoSnapshot: Equatable, Sendable {
    var scenes: [Scene]
    var selectedID: SceneID
    var overlays: [LayerNode]
    var defaultBackground: SceneBackground?
    /// S09 (issue #100): the project default transition — undoable like the
    /// default background.
    var defaultTransition: SceneTransition
    var folders: [SceneFolder]
    var sceneMembership: [SceneID: SceneFolderID]
    var lockedSceneIDs: Set<SceneID>
    var stagedScene: Scene?
}
