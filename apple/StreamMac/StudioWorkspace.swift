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
    let diagnostics: StudioDiagnosticsMonitor
    let localControl: StudioLocalControlServer
    let dispatcher: StudioCommandDispatcher
    let controllers: StudioControllerManager
    let chat: StudioChatCoordinator
    let providerAccounts: ProviderAccountSession
    var recoveryBinding: SessionRecoveryRuntimeBinding?
    let adapters: StudioAdapterManager

    init() {
        localControl = StudioLocalControlServer()
        sceneStore = SceneStore()
        previewProgram = PreviewProgramModel(selected: sceneStore.selected)
        permissions = PermissionsManager()
        controller = StreamController(sceneStore: sceneStore, previewProgram: previewProgram, permissions: permissions)
        settings = SettingsSession(controller: controller)
        recorder = RecordingController()
        recorder.loadPreferences(directory: DesktopStorage.projectDirectory)
        RecordingTerminationDelegate.recorder = recorder
        controller.stopRecordingForLifecycle = { [weak recorder] in recorder?.stop() }
        controller.maximumPublishingEncoders = { [weak recorder] in recorder?.maximumPublishingEncodersWhileRecording }
        diagnostics = StudioDiagnosticsMonitor(controller: controller, recorder: recorder)
        dispatcher = StudioCommandDispatcher(controller: controller, sceneStore: sceneStore,
            session: settings, recorder: recorder, previewProgram: previewProgram)
        controllers = StudioControllerManager()
        controllers.interactionBlocked = { true }
        controllers.bind(to: dispatcher)
        chat = StudioChatCoordinator(dispatcher: dispatcher, previewProgram: previewProgram)
        dispatcher.bindChatCoordinator(chat)
        recorder.bindChat(chat)
        controller.bindSecondaryRecordingChat(chat)
        providerAccounts = ProviderAccountSession(restream: chat.restream, pendingDirectory: DesktopStorage.projectDirectory)
        controller.bindManagedStart(accounts: providerAccounts)
        chat.bindAccounts(providerAccounts)
        controller.bindEnding(accounts: providerAccounts, dispatcher: dispatcher, previewProgram: previewProgram)
        adapters = StudioAdapterManager()
        adapters.bind(to: localControl)
        StudioAutomationEndpoint.shared.bind(dispatcher: dispatcher, permissions: permissions,
            stagedLayers: { [weak previewProgram] in previewProgram?.stagedScene?.layers ?? [] })
    }

    func flush() {
        sceneStore.flushPendingWrites()
        settings.flushPendingWrites()
        dispatcher.assetLibrary.flushPendingWrites()
        dispatcher.soundboardStore.flushPendingWrites()
        dispatcher.annotations.flushPendingWrites()
        dispatcher.pdfDecks.flushPendingWrites()
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
    @Published var sceneRecovery: Backup?
    @Published var importPreview: ShowPackagePreview? {
        didSet {
            // The sheet's existing Cancel binding closes preview authority.
            // A canceled IO worker retains its capacity until it returns.
            if importPreview == nil {
                latestPackageRead = nil
                refreshPackageBusy()
            }
        }
    }
    @Published private(set) var packageBusy = false
    @Published var showRecordingLibrary = false
    var permissionChoicePending = false
    let recovery: SessionRecoveryCoordinator

    struct Selection: Equatable {
        var project: UUID
        var profile: UUID
    }
    private let catalogURL: URL
    private let root: URL
    private var stateObservation: AnyCancellable?
    private var occupiedPackageReads: Set<UUID> = []
    private var latestPackageRead: UUID?
    private var packageWrite: UUID?
    private let maximumPackageReads = 4
    var selection: Selection { Selection(project: catalog.selectedProjectID, profile: catalog.selectedProfileID) }
    var currentProject: StudioProject { catalog.projects.first { $0.id == catalog.selectedProjectID }! }
    var currentProfile: StudioProfile { currentProject.profiles.first { $0.id == catalog.selectedProfileID }! }
    var canSwitch: Bool { !runtime.controller.outputSessionActive && !runtime.recorder.state.isActive && !isSwitching }

    init(root: URL = DesktopStorage.machineDirectory) {
        self.root = root
        self.recovery = SessionRecoveryCoordinator(directory: root.appendingPathComponent("SessionRecovery"))
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
        let directory = root.appendingPathComponent(StudioProjectCatalog.relativeDirectory(project: catalog.selectedProjectID, profile: catalog.selectedProfileID), isDirectory: true)
        let firstLaunch = !FileManager.default.fileExists(atPath: directory.path)
        try? DesktopStorage.prepare(directory)
        if firstLaunch { Self.copyLegacyFiles(to: directory) }
        DesktopSettingsStore().migrateLegacyIfNeeded()
        let sceneBackup = Self.recoveryCandidate(in: directory)
        runtime = StudioRuntime()
        sceneRecovery = sceneBackup
        runtime.sceneStore.setProjectIdentity(catalog.selectedProjectID, name: catalog.projects.first { $0.id == catalog.selectedProjectID }!.name)
        recoveryFile = recovery
        if recovery == nil { saveCatalog() }
        observeRuntime()
    }

    func directory(for selection: Selection) -> URL {
        root.appendingPathComponent(StudioProjectCatalog.relativeDirectory(project: selection.project, profile: selection.profile), isDirectory: true)
    }

    func stage(project: UUID, profile: UUID) {
        guard catalog.projects.contains(where: { $0.id == project && $0.profiles.contains(where: { $0.id == profile }) }) else { return }
        pending = Selection(project: project, profile: profile)
    }

    func applyPending() async {
        guard let next = pending, next != selection, canSwitch else { return }
        isSwitching = true
        StudioAutomationEndpoint.shared.unbind()
        recovery.remoteReview.invalidate()
        runtime.recoveryBinding?.shutdown()
        runtime.controllers.shutdown()
        runtime.controller.shutdownManagedStart()
        runtime.controller.retireGuestMedia()
        runtime.controller.ending.shutdown(); runtime.providerAccounts.shutdown(); runtime.chat.shutdown()
        runtime.localControl.shutdown()
        runtime.dispatcher.rundown.stop()
        runtime.dispatcher.macros.cancel()
        runtime.dispatcher.soundboard.stopAllSoundEffects()
        for playlist in runtime.dispatcher.soundboardStore.playlists { runtime.dispatcher.soundboard.stopPlaylist(playlist) }
        runtime.flush()
        await runtime.controller.prepareForProjectChange()
        do {
            try DesktopStorage.prepare(directory(for: next))
            catalog.selectedProjectID = next.project
            catalog.selectedProfileID = next.profile
            let sceneBackup = Self.recoveryCandidate(in: directory(for: next))
            runtime = StudioRuntime()
            sceneRecovery = sceneBackup
            observeRuntime()
            runtime.sceneStore.setProjectIdentity(currentProject.id, name: currentProject.name)
            pending = nil
            error = nil
            saveCatalog()
        } catch {
            // The previous runtime has already retired its account and controller sessions.
            // Reopen the selected context so a failed filesystem operation remains recoverable.
            runtime = StudioRuntime()
            observeRuntime()
            runtime.sceneStore.setProjectIdentity(currentProject.id, name: currentProject.name)
            self.error = error.localizedDescription
        }
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
                try Self.copyCredentials(from: directory(for: selection), to: directory(for: target))
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
                try Self.copyCredentials(from: directory(for: selection), to: directory(for: target))
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

    /// Inspect before SceneStore quarantines unreadable bytes. Loading never
    /// silently restores a backup; the producer previews and accepts it first.
    private static func recoveryCandidate(in directory: URL) -> Backup? {
        let current = directory.appendingPathComponent("stream.scenes.v2.json")
        guard let data = try? Data(contentsOf: current) else { return nil }
        if case .success(let migrated) = SceneDocumentMigration.migrateToCurrent(data),
           let document = try? JSONDecoder().decode(SceneDocument.self, from: migrated), !document.scenes.isEmpty { return nil }
        return ((try? ProjectDocumentHistory.validBackups(for: current)) ?? []).compactMap { candidate -> Backup? in
            guard let data = try? Data(contentsOf: candidate), case .success(let migrated) = SceneDocumentMigration.migrateToCurrent(data),
                  let document = try? JSONDecoder().decode(SceneDocument.self, from: migrated), !document.scenes.isEmpty else { return nil }
            return Backup(url: candidate, document: document)
        }.first
    }

    var sceneBackups: [Backup] {
        let url = directory(for: selection).appendingPathComponent("stream.scenes.v2.json")
        return ((try? ProjectDocumentHistory.validBackups(for: url)) ?? []).compactMap { candidate -> Backup? in
            guard let data = try? Data(contentsOf: candidate), case .success(let migrated) = SceneDocumentMigration.migrateToCurrent(data),
                  let document = try? JSONDecoder().decode(SceneDocument.self, from: migrated), !document.scenes.isEmpty else { return nil }
            return Backup(url: candidate, document: document)
        }
    }

    func restore(_ backup: Backup) async {
        guard canSwitch else { return }
        isSwitching = true
        StudioAutomationEndpoint.shared.unbind()
        recovery.remoteReview.invalidate()
        runtime.recoveryBinding?.shutdown()
        runtime.controllers.shutdown()
        runtime.controller.shutdownManagedStart()
        runtime.controller.retireGuestMedia()
        runtime.controller.ending.shutdown(); runtime.providerAccounts.shutdown(); runtime.chat.shutdown()
        runtime.localControl.shutdown()
        runtime.dispatcher.macros.cancel()
        runtime.dispatcher.rundown.stop()
        runtime.flush()
        await runtime.controller.prepareForProjectChange()
        do {
            let url = directory(for: selection).appendingPathComponent("stream.scenes.v2.json")
            try ProjectDocumentHistory.write(JSONEncoder().encode(backup.document), to: url)
            runtime = StudioRuntime()
            observeRuntime()
            runtime.sceneStore.setProjectIdentity(currentProject.id, name: currentProject.name)
            sceneRecovery = nil
            error = nil
        } catch {
            // The previous runtime has already retired its account and controller sessions.
            // Reopen the selected context so a failed filesystem operation remains recoverable.
            runtime = StudioRuntime()
            observeRuntime()
            runtime.sceneStore.setProjectIdentity(currentProject.id, name: currentProject.name)
            self.error = error.localizedDescription
        }
        isSwitching = false
    }

    private func observeRuntime() {
        runtime.controllers.interactionBlocked = { [weak self] in
            guard let self else { return true }
            return !UserDefaults.standard.bool(forKey: "onboarding.hasCompletedFirstRun") || self.permissionChoicePending || self.isSwitching || self.packageBusy
        }
        let projectID = currentProject.id, profileID = currentProfile.id
        runtime.recoveryBinding = SessionRecoveryRuntimeBinding(coordinator: recovery,
            projectID: projectID, profileID: profileID, sceneStore: runtime.sceneStore,
            previewProgram: runtime.previewProgram, controller: runtime.controller, pdfDecks: runtime.dispatcher.pdfDecks,
            recordingActivity: Publishers.CombineLatest(runtime.recorder.$state, runtime.controller.secondaryRecorder.$state)
                .map { $0.0.isActive || $0.1.isActive }.eraseToAnyPublisher(),
            remoteEvents: { [weak controller = runtime.controller] ids in
                guard let controller else { return ids.map { SessionRecoveryRemoteEvent(outputID: $0) } }
                return controller.destinationOutputs.recoveryRemoteEvents
            },
            recordings: { [weak recorder = runtime.recorder, weak controller = runtime.controller] in
                guard let recorder else { throw SessionRecoveryDiskStore.Failure.invalid }
                let access = try recorder.libraryAccess()
                return try await SessionRecordingJournalReader.read(
                    grant: SessionRecoveryDirectoryGrant(url: access.url, retaining: access),
                    projectID: projectID, profileID: profileID,
                    activeFiles: Set(recorder.activeOutputURLs.union(controller?.secondaryRecordingActiveOutputURLs ?? []).map(\.lastPathComponent)))
            })
        recovery.remoteReview.bindAccounts(runtime.providerAccounts)
        recovery.contextLabel = { [weak self] project, profile in
            guard let project = self?.catalog.projects.first(where: { $0.id == project }),
                  let profile = project.profiles.first(where: { $0.id == profile }) else { return nil }
            return "\(project.name) · \(profile.name)"
        }
        recovery.reviewRecordings = { [weak self] in self?.recovery.showReview = false; self?.showRecordingLibrary = true }
        recovery.restoreLocalContext = { [weak self] snapshot in
            guard let self, self.canSwitch, self.catalog.projects.contains(where: {
                $0.id == snapshot.projectID && $0.profiles.contains(where: { $0.id == snapshot.profileID })
            }) else { self?.recovery.reportError("The saved project/profile is unavailable or outputs are still active."); return }
            let target = Selection(project: snapshot.projectID, profile: snapshot.profileID)
            if self.selection != target { self.stage(project: target.project, profile: target.profile); await self.applyPending() }
            guard self.selection == target, let binding = self.runtime.recoveryBinding else {
                self.recovery.reportError("The saved project/profile could not be opened."); return
            }
            do { try binding.restoreLocal(snapshot) }
            catch { self.recovery.reportError("Local recovery could not be applied. Review project backups and relink missing media.") }
        }
        RecordingTerminationDelegate.finishSession = { [weak self] in
            guard let self else { return }
            self.recovery.remoteReview.shutdown()
            self.runtime.controller.shutdownManagedStart()
            self.runtime.controller.retireGuestMedia()
            self.runtime.controllers.shutdown(); self.runtime.controller.ending.shutdown(); self.runtime.providerAccounts.shutdown(); self.runtime.chat.shutdown(); self.runtime.localControl.shutdown()
            self.runtime.dispatcher.macros.cancel(); self.runtime.dispatcher.rundown.stop()
            self.runtime.controller.stopStream(); self.runtime.controller.stopSecondaryRecording(); self.runtime.controller.stopExternalDisplayOutput(); self.runtime.controller.stopVirtualCameraOutput()
            self.runtime.flush()
            for _ in 0..<150 {
                if !self.runtime.controller.outputSessionActive { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            await self.runtime.recoveryBinding?.refreshRecordings()
            self.runtime.recoveryBinding?.shutdown()
            await self.recovery.finishCurrentSession()
        }
        StudioAutomationEndpoint.shared.bind(dispatcher: runtime.dispatcher, permissions: runtime.permissions,
            profileName: currentProfile.name, stagedLayers: { [weak previewProgram = runtime.previewProgram] in previewProgram?.stagedScene?.layers ?? [] })
        runtime.recorder.context = RecordingContext(projectID: currentProject.id.uuidString, profileID: currentProfile.id.uuidString,
            projectName: currentProject.name, profileName: currentProfile.name)
        stateObservation = runtime.controller.$streamState.combineLatest(runtime.recorder.$state)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func choosePackage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.streamShow]
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        if panel.runModal() == .OK, let url = panel.url { previewPackage(url) }
    }

    func acceptPackageDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier("public.file-url") }) else { return false }
        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { [weak self] item, _ in
            let url: URL?
            if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else { url = item as? URL }
            guard let url, url.pathExtension.lowercased() == "streamshow" else { return }
            Task { @MainActor [weak self] in self?.previewPackage(url) }
        }
        return true
    }

    func previewPackage(_ url: URL) {
        guard url.isFileURL, url.pathExtension.lowercased() == "streamshow" else { return }
        showProjects = true
        guard packageWrite == nil else {
            error = "Wait for the current package import or export to finish before opening another package."
            return
        }
        guard occupiedPackageReads.count < maximumPackageReads else {
            error = "Wait for the existing package reads to finish before opening another package."
            return
        }
        let request = UUID()
        occupiedPackageReads.insert(request)
        latestPackageRead = request
        refreshPackageBusy()
        Task { [weak self] in
            let result = await Task.detached { Result { try ShowPackageIO.preview(url) } }.value
            guard let self else { return }
            self.occupiedPackageReads.remove(request)
            guard self.latestPackageRead == request else { return }
            self.latestPackageRead = nil
            switch result {
            case .success(let preview): self.importPreview = preview
            case .failure(let failure):
                self.importPreview = nil
                self.error = String(describing: failure)
                self.showProjects = true
            }
            self.refreshPackageBusy()
        }
    }

    func importPreviewedPackage() async {
        guard let preview = importPreview, !packageBusy, let operation = beginPackageWrite() else { return }
        defer { finishPackageWrite(operation) }
        let project = StudioProject(name: preview.name)
        let target = Selection(project: project.id, profile: project.profiles[0].id)
        let destination = directory(for: target)
        do {
            try await Task.detached { try ShowPackageIO.importFiles(from: preview.url, to: destination) }.value
            catalog.projects.append(project)
            pending = target
            importPreview = nil
            showProjects = true
            saveCatalog()
        } catch { self.error = String(describing: error) }
    }

    func exportPackage(includeMedia: Bool, selectedSceneOnly: Bool) {
        // The native save panel runs a nested run loop. Own the write before
        // entering it so a delivered package event cannot replace the preview.
        guard let operation = beginPackageWrite() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.streamShow]
        panel.nameFieldStringValue = currentProject.name + ".streamshow"
        guard panel.runModal() == .OK, let url = panel.url else { finishPackageWrite(operation); return }
        runtime.flush()
        var document = runtime.sceneStore.document
        if selectedSceneOnly {
            var required: Set<SceneID> = [document.selectedID]
            var changed = true
            while changed {
                let previous = required
                for scene in document.scenes where required.contains(scene.id) {
                    for layer in scene.layers { if case .scene(let reference) = layer.payload { required.insert(reference.sceneID) } }
                }
                changed = previous != required
            }
            document.scenes.removeAll { !required.contains($0.id) }
            let sourceIDs = Set((document.scenes.flatMap(\.layers) + document.overlays).compactMap(\.sourceID))
            document.sources.removeAll { !sourceIDs.contains($0.id) }
        }
        var documents: [String: Data] = [:]
        let directory = directory(for: selection)
        for name in PortableShow.documentNames {
            if let data = try? Data(contentsOf: directory.appendingPathComponent(name)) { documents[name] = data }
        }
        documents["stream.scenes.v2.json"] = try? JSONEncoder().encode(document)
        var assets = runtime.dispatcher.assetLibrary.assets
        var media: [ShowPackageIO.Media] = []
        for i in assets.indices {
            let path = "Assets/\(assets[i].id)/\(URL(fileURLWithPath: assets[i].fileName).lastPathComponent)"
            if includeMedia, let access = runtime.dispatcher.assetLibrary.access(for: assets[i].id), access.isAccessible {
                assets[i].storage = .projectCopy
                assets[i].relativePath = path
                media.append(.init(access: access, relativePath: path))
            } else { assets[i].storage = .linked; assets[i].relativePath = nil }
            assets[i].bookmarkData = nil; assets[i].lastKnownPath = ""
        }
        documents["stream.assets.v1.json"] = try? JSONEncoder().encode(AssetLibraryDocument(assets: assets, usage: [:]))
        let packageDocuments = documents, packageMedia = media, name = currentProject.name
        Task { [weak self] in
            defer { self?.finishPackageWrite(operation) }
            do {
                try await Task.detached { try ShowPackageIO.export(documents: packageDocuments, media: packageMedia,
                    name: name, includeMedia: includeMedia, to: url) }.value
            } catch { self?.error = String(describing: error) }
        }
    }

    private func beginPackageWrite() -> UUID? {
        guard !packageBusy else {
            error = "Wait for the current package operation to finish."
            return nil
        }
        let operation = UUID()
        packageWrite = operation
        refreshPackageBusy()
        return operation
    }

    private func finishPackageWrite(_ operation: UUID) {
        guard packageWrite == operation else { return }
        packageWrite = nil
        refreshPackageBusy()
    }

    private func refreshPackageBusy() {
        let busy = latestPackageRead != nil || packageWrite != nil
        if packageBusy != busy { packageBusy = busy }
    }

    private static func copyCredentials(from source: URL, to target: URL) throws {
        let sourceStore = DesktopSettingsStore(directory: source)
        let targetStore = DesktopSettingsStore(directory: target)
        for proto in StreamProtocol.allCases {
            let values = sourceStore.connectionSecrets(for: proto)
            targetStore.saveConnectionSecrets(url: values.url, key: values.key, for: proto)
        }
        // Independent copies get independent destination identities/secrets.
        let sourceDestinations = DestinationStore(fileURL: source.appendingPathComponent("destinations.json"))
        let targetDestinations = DestinationStore(fileURL: target.appendingPathComponent("destinations.json"))
        let originals = try sourceDestinations.load()
        if !originals.isEmpty {
            var replacements: [String: String] = [:]
            var copies: [StreamDestination] = []
            var credentials: [UUID: DestinationCredentials] = [:]
            for original in originals {
                var copy = original
                copy.id = UUID()
                replacements[original.id.uuidString] = copy.id.uuidString
                copies.append(copy)
                credentials[copy.id] = sourceDestinations.credentials(for: original.id)
            }
            // Remove copied metadata before save so its cleanup cannot revoke
            // a credential still owned by the original project.
            let metadataURL = target.appendingPathComponent("destinations.json")
            try? FileManager.default.removeItem(at: metadataURL)
            try targetDestinations.save(copies, credentials: credentials)
            for filename in ["stream.shortcuts.v1.json", "stream.macros.v1.json"] {
                let url = target.appendingPathComponent(filename)
                guard let data = try? Data(contentsOf: url), var text = String(data: data, encoding: .utf8) else { continue }
                for (old, new) in replacements { text = text.replacingOccurrences(of: old, with: new) }
                try? Data(text.utf8).write(to: url, options: .atomic)
            }
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
