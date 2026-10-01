import AppKit
import Foundation
import StreamCore

/// E06 (issue #165): the persisted PTZ surface — configured network targets,
/// per-target presets, and the explicit scene→preset recall links — backed
/// by `PTZDocumentStore` (`stream.ptz.v1.json` in the shared App Group
/// container, the `SoundboardStore` pattern: debounced atomic autosave,
/// corrupt-file quarantine, flush on termination).
///
/// Mutations are immediate, not draft/Apply: PTZ configuration is a live
/// performance surface (the soundboard/mixer precedent), NOT scene content —
/// it never stages, Takes, or joins the undo stack. The `PTZController`
/// observes `targets` to keep transports in sync; the dispatcher's Take seam
/// reads `recallLinks` to fire opt-in recalls when a scene becomes program.
@MainActor
final class PTZPresetStore: ObservableObject {
    @Published private(set) var targets: [PTZTarget] {
        didSet { scheduleAutosave() }
    }
    /// Presets keyed by target ID (VISCA memory slots are per-camera state).
    @Published private(set) var presets: [UUID: [PTZPreset]] {
        didSet { scheduleAutosave() }
    }
    @Published private(set) var recallLinks: [PTZSceneRecallLink] {
        didSet { scheduleAutosave() }
    }

    private static let autosaveDelay: TimeInterval = 0.75

    private let documentStore: PTZDocumentStore?
    private var autosaveTask: Task<Void, Never>?
    /// `nonisolated(unsafe)` so `deinit` can unregister it (the store lives
    /// for the app's lifetime; this is belt-and-braces).
    nonisolated(unsafe) private var terminationObserver: NSObjectProtocol?

    init(documentStore: PTZDocumentStore? = PTZDocumentStore.default()) {
        self.documentStore = documentStore
        let document = documentStore?.load() ?? PTZDocument()
        targets = document.targets
        presets = document.presets
        recallLinks = document.recallLinks
        writeDocument()
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

    // MARK: - Lookups

    func target(withID id: UUID) -> PTZTarget? {
        targets.first(where: { $0.id == id })
    }

    func presets(forTargetID id: UUID) -> [PTZPreset] {
        presets[id] ?? []
    }

    func preset(number: UInt8, forTargetID id: UUID) -> PTZPreset? {
        presets[id]?.first(where: { $0.number == number })
    }

    func recallLinks(forSceneID sceneID: UUID) -> [PTZSceneRecallLink] {
        recallLinks.filter { $0.sceneID == sceneID }
    }

    func recallLink(withID id: UUID) -> PTZSceneRecallLink? {
        recallLinks.first(where: { $0.id == id })
    }

    // MARK: - Mutations (immediate, autosaved)

    @discardableResult
    func addTarget(_ target: PTZTarget) -> PTZTarget {
        targets.append(target)
        return target
    }

    func updateTarget(_ target: PTZTarget) {
        guard let index = targets.firstIndex(where: { $0.id == target.id }) else { return }
        targets[index] = target
    }

    /// Removing a target also removes its presets and recall links — a
    /// dangling reference would recall into nothing.
    func removeTarget(_ id: UUID) {
        targets.removeAll { $0.id == id }
        presets.removeValue(forKey: id)
        recallLinks.removeAll { $0.targetID == id }
    }

    /// Stores (or overwrites) a preset slot for a target. Slots sort by
    /// number so the UI grid reads in VISCA order.
    func storePreset(_ preset: PTZPreset, forTargetID id: UUID) {
        var list = presets[id] ?? []
        list.removeAll { $0.number == preset.number }
        list.append(preset)
        presets[id] = list.sorted { $0.number < $1.number }
    }

    func removePreset(number: UInt8, forTargetID id: UUID) {
        presets[id]?.removeAll { $0.number == number }
        // Recalls pointing at a deleted slot are removed with it.
        recallLinks.removeAll { $0.targetID == id && $0.presetNumber == number }
    }

    /// Adds or replaces the scene→target recall link (one link per
    /// scene/target pair — the latest configuration wins).
    func setRecallLink(_ link: PTZSceneRecallLink) {
        recallLinks.removeAll {
            $0.sceneID == link.sceneID && $0.targetID == link.targetID && $0.id != link.id
        }
        if let index = recallLinks.firstIndex(where: { $0.id == link.id }) {
            recallLinks[index] = link
        } else {
            recallLinks.append(link)
        }
    }

    func removeRecallLink(_ id: UUID) {
        recallLinks.removeAll { $0.id == id }
    }

    // MARK: - Persistence

    /// Writes any pending debounced autosave NOW (app termination).
    func flushPendingWrites() {
        autosaveTask?.cancel()
        writeDocument()
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autosaveDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.writeDocument()
        }
    }

    private func writeDocument() {
        documentStore?.save(PTZDocument(targets: targets,
                                        presets: presets,
                                        recallLinks: recallLinks))
    }
}
