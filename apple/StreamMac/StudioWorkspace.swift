import AppKit
import Combine
import Foundation
import StreamCore

@MainActor
final class StudioRuntime {
    let sceneStore: SceneStore
    let previewProgram: PreviewProgramModel
    let permissions: PermissionsManager
    let controller: StreamController
    let settings: SettingsSession
    let recorder: RecordingController
    let dispatcher: StudioCommandDispatcher

    init() {
        sceneStore = SceneStore()
        previewProgram = PreviewProgramModel(selected: sceneStore.selected)
        permissions = PermissionsManager()
        controller = StreamController(sceneStore: sceneStore, previewProgram: previewProgram, permissions: permissions)
        settings = SettingsSession(controller: controller)
        recorder = RecordingController()
        dispatcher = StudioCommandDispatcher(controller: controller, sceneStore: sceneStore,
            session: settings, recorder: recorder, previewProgram: previewProgram)
    }

    func flush() {
        sceneStore.flushPendingWrites()
        settings.flushPendingWrites()
        dispatcher.assetLibrary.flushPendingWrites()
        dispatcher.soundboardStore.flushPendingWrites()
        dispatcher.annotations.flushPendingWrites()
        dispatcher.ptzStore.flushPendingWrites()
    }
}

@MainActor
final class StudioWorkspace: ObservableObject {
    @Published private(set) var catalog: StudioProjectCatalog
    @Published private(set) var runtime: StudioRuntime
    @Published var pending: Selection?
    @Published var error: String?
    @Published private(set) var isSwitching = false
    @Published var showProjects = false
    @Published var recoveryFile: URL?

    struct Selection: Equatable {
        var project: UUID
        var profile: UUID
    }
    private let catalogURL: URL
    private let root: URL
    private var stateObservation: AnyCancellable?
    var selection: Selection { Selection(project: catalog.selectedProjectID, profile: catalog.selectedProfileID) }
    var currentProject: StudioProject { catalog.projects.first { $0.id == catalog.selectedProjectID }! }
    var currentProfile: StudioProfile { currentProject.profiles.first { $0.id == catalog.selectedProfileID }! }
    var canSwitch: Bool { !runtime.controller.outputSessionActive && !runtime.recorder.state.isActive && !isSwitching }

    init(root: URL = DesktopStorage.machineDirectory) {
        self.root = root
        catalogURL = root.appendingPathComponent("projects.v1.json")
        var catalog = StudioProjectCatalog()
        var recovery: URL?
        if let data = try? Data(contentsOf: catalogURL) {
            if let loaded = try? JSONDecoder().decode(StudioProjectCatalog.self, from: data), loaded.validationError == nil {
                catalog = loaded
            } else {
                recovery = catalogURL
                if let backups = try? ProjectDocumentHistory.validBackups(for: catalogURL),
                   let valid = backups.compactMap({ try? JSONDecoder().decode(StudioProjectCatalog.self, from: Data(contentsOf: $0)) })
                    .first(where: { $0.validationError == nil }) { catalog = valid }
            }
        }
        self.catalog = catalog
        let directory = root.appendingPathComponent(StudioProjectCatalog.relativeDirectory(project: catalog.selectedProjectID, profile: catalog.selectedProfileID))
        let firstLaunch = !FileManager.default.fileExists(atPath: directory.path)
        try? DesktopStorage.prepare(directory)
        if firstLaunch { Self.copyLegacyFiles(to: directory) }
        DesktopSettingsStore().migrateLegacyIfNeeded()
        runtime = StudioRuntime()
        runtime.sceneStore.setProjectIdentity(catalog.selectedProjectID, name: catalog.projects.first { $0.id == catalog.selectedProjectID }!.name)
        recoveryFile = recovery
        if recovery == nil { saveCatalog() }
        observeRuntime()
    }

    func directory(for selection: Selection) -> URL {
        root.appendingPathComponent(StudioProjectCatalog.relativeDirectory(project: selection.project, profile: selection.profile))
    }

    func stage(project: UUID, profile: UUID) {
        guard catalog.projects.contains(where: { $0.id == project && $0.profiles.contains(where: { $0.id == profile }) }) else { return }
        pending = Selection(project: project, profile: profile)
    }

    func applyPending() async {
        guard let next = pending, next != selection, canSwitch else { return }
        isSwitching = true
        runtime.dispatcher.rundown.stop()
        runtime.dispatcher.soundboard.stopAllSoundEffects()
        for playlist in runtime.dispatcher.soundboardStore.playlists { runtime.dispatcher.soundboard.stopPlaylist(playlist) }
        runtime.flush()
        await runtime.controller.prepareForProjectChange()
        do {
            try DesktopStorage.prepare(directory(for: next))
            catalog.selectedProjectID = next.project
            catalog.selectedProfileID = next.profile
            runtime = StudioRuntime()
            observeRuntime()
            runtime.sceneStore.setProjectIdentity(currentProject.id, name: currentProject.name)
            pending = nil
            saveCatalog()
        } catch { self.error = error.localizedDescription }
        isSwitching = false
    }

    func create(named name: String, duplicate: Bool = false) {
        guard StudioProjectCatalog.validName(name), catalog.projects.count < 200 else { error = "Choose a name of 1–200 bytes."; return }
        let project = StudioProject(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        let target = Selection(project: project.id, profile: project.profiles[0].id)
        do {
            if duplicate {
                runtime.flush()
                try FileManager.default.createDirectory(at: directory(for: target).deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: directory(for: selection), to: directory(for: target))
                Self.copyCredentials(from: directory(for: selection), to: directory(for: target))
            } else { try FileManager.default.createDirectory(at: directory(for: target), withIntermediateDirectories: true) }
            catalog.projects.append(project)
            pending = target
            saveCatalog()
        } catch { self.error = error.localizedDescription }
    }

    func rename(_ id: UUID, to name: String) {
        guard StudioProjectCatalog.validName(name), let index = catalog.projects.firstIndex(where: { $0.id == id }) else { return }
        catalog.projects[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if id == catalog.selectedProjectID { runtime.sceneStore.setProjectIdentity(id, name: catalog.projects[index].name) }
        saveCatalog()
    }

    func archive(_ id: UUID, archived: Bool) {
        guard id != catalog.selectedProjectID, let index = catalog.projects.firstIndex(where: { $0.id == id }) else { return }
        catalog.projects[index].isArchived = archived
        saveCatalog()
    }

    func addProfile(named name: String, duplicate: Bool) {
        guard StudioProjectCatalog.validName(name), let index = catalog.projects.firstIndex(where: { $0.id == catalog.selectedProjectID }),
              catalog.projects[index].profiles.count < 50 else { return }
        let profile = StudioProfile(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        let target = Selection(project: currentProject.id, profile: profile.id)
        do {
            if duplicate {
                runtime.flush()
                try FileManager.default.copyItem(at: directory(for: selection), to: directory(for: target))
                Self.copyCredentials(from: directory(for: selection), to: directory(for: target))
            } else { try FileManager.default.createDirectory(at: directory(for: target), withIntermediateDirectories: true) }
            catalog.projects[index].profiles.append(profile)
            pending = target
            saveCatalog()
        } catch { self.error = error.localizedDescription }
    }

    private func saveCatalog() {
        guard recoveryFile == nil else { return }
        do {
            if let problem = catalog.validationError { throw NSError(domain: "StreamProjects", code: 1, userInfo: [NSLocalizedDescriptionKey: problem]) }
            try ProjectDocumentHistory.write(JSONEncoder().encode(catalog), to: catalogURL)
        } catch { self.error = error.localizedDescription }
    }

    func acceptRecoveredCatalog() {
        guard let original = recoveryFile else { return }
        do {
            try FileManager.default.moveItem(at: original, to: original.appendingPathExtension("corrupt-\(UUID().uuidString).bak"))
            recoveryFile = nil
            saveCatalog()
        } catch { self.error = error.localizedDescription }
    }

    struct Backup: Identifiable {
        let url: URL
        let document: SceneDocument
        var id: String { url.path }
        var label: String {
            let milliseconds = Double(url.lastPathComponent.split(separator: "-")[0]) ?? 0
            let date = Date(timeIntervalSince1970: milliseconds / 1000)
            return date.formatted(date: .abbreviated, time: .standard)
        }
    }

    var sceneBackups: [Backup] {
        let url = directory(for: selection).appendingPathComponent("stream.scenes.v2.json")
        return ((try? ProjectDocumentHistory.validBackups(for: url)) ?? []).compactMap { candidate in
            guard let data = try? Data(contentsOf: candidate), case .success(let migrated) = SceneDocumentMigration.migrateToCurrent(data),
                  let document = try? JSONDecoder().decode(SceneDocument.self, from: migrated), !document.scenes.isEmpty else { return nil }
            return Backup(url: candidate, document: document)
        }
    }

    func restore(_ backup: Backup) async {
        guard canSwitch else { return }
        isSwitching = true
        runtime.flush()
        await runtime.controller.prepareForProjectChange()
        do {
            let url = directory(for: selection).appendingPathComponent("stream.scenes.v2.json")
            try ProjectDocumentHistory.write(JSONEncoder().encode(backup.document), to: url)
            runtime = StudioRuntime()
            observeRuntime()
            runtime.sceneStore.setProjectIdentity(currentProject.id, name: currentProject.name)
        } catch { self.error = error.localizedDescription }
        isSwitching = false
    }

    private func observeRuntime() {
        stateObservation = runtime.controller.$streamState.combineLatest(runtime.recorder.$state)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    private static func copyCredentials(from source: URL, to target: URL) {
        let sourceStore = DesktopSettingsStore(directory: source)
        let targetStore = DesktopSettingsStore(directory: target)
        for proto in StreamProtocol.allCases {
            let values = sourceStore.connectionSecrets(for: proto)
            targetStore.saveConnectionSecrets(url: values.url, key: values.key, for: proto)
        }
    }

    private static func copyLegacyFiles(to directory: URL) {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier),
              let contents = try? FileManager.default.contentsOfDirectory(at: group, includingPropertiesForKeys: nil) else { return }
        for url in contents where (url.lastPathComponent.hasPrefix("stream.") && url.pathExtension == "json" && url.lastPathComponent != "\(AppGroup.settingsKey).json") || url.lastPathComponent == "Assets" {
            let target = directory.appendingPathComponent(url.lastPathComponent)
            if !FileManager.default.fileExists(atPath: target.path) { try? FileManager.default.copyItem(at: url, to: target) }
        }
    }
}
