// Composed after package_read_harness.swift's exact IO probes and helpers by
// generate_package_read_methods.py --transaction. No StudioRuntime exists.
@main @MainActor struct PackageImportTransactionHarness {
    static func main() async {
        setbuf(stdout, nil)
        defer { PackageReadProbe.releaseAll() }
        do { try await run(); print("PASS: durable package import transactions and exact owned rollback") }
        catch { print("FAIL: \(String(describing: error))"); exit(1) }
    }

    static func wait(_ message: String, until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while !predicate() {
            try require(ContinuousClock.now < deadline, message)
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static func sceneFiles(_ root: URL) -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent("Projects"),
            includingPropertiesForKeys: nil) else { return [] }
        return Set(enumerator.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "stream.scenes.v2.json" }.map(\.path))
    }

    static func preview(_ url: URL, in workspace: StudioWorkspace) async throws {
        workspace.error = nil
        workspace.previewPackage(url)
        try await wait("Actual package preview missing") { workspace.importPreview?.url == url && !workspace.packageBusy }
    }

    static func verifyCatalogReads(_ root: URL, seed: StudioProjectCatalog) throws {
        let manager = FileManager.default
        let folder = root.appendingPathComponent("OwnedCatalogReadCases", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let absent = folder.appendingPathComponent("absent.json")
        try require(StudioCatalogRead.load(at: absent).recoveryFile == nil && !manager.fileExists(atPath: absent.path),
            "Confirmed absent catalog did not retain first-launch behavior")
        let url = folder.appendingPathComponent("catalog.json")
        let bytes = try JSONEncoder().encode(seed)
        try bytes.write(to: url)
        try require(StudioCatalogRead.load(at: url).catalog == seed && StudioCatalogRead.load(at: url).recoveryFile == nil,
            "Valid catalog did not reload exactly")
        try Data("invalid original catalog bytes".utf8).write(to: url)
        try require(StudioCatalogRead.load(at: url).recoveryFile == url &&
            (try Data(contentsOf: url)) == Data("invalid original catalog bytes".utf8),
            "Invalid catalog was replaced or not marked for explicit recovery")
        let backup = folder.appendingPathComponent("History/catalog.json", isDirectory: true)
        try manager.createDirectory(at: backup, withIntermediateDirectories: true)
        try bytes.write(to: backup.appendingPathComponent("owned-valid.json"))
        try bytes.write(to: url)
        do {
            defer { try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
            try require((try? Data(contentsOf: url)) == nil, "Owned unreadable-file control did not deny read")
            let load = StudioCatalogRead.load(at: url)
            try require(load.recoveryFile == url && load.catalog == seed,
                "Unreadable existing catalog was treated as fresh or lost valid-backup fallback")
        }
        try require(try Data(contentsOf: url) == bytes, "Unreadable original catalog bytes changed")
        let link = folder.appendingPathComponent("dangling-catalog.json")
        try manager.createSymbolicLink(at: link, withDestinationURL: folder.appendingPathComponent("missing-target.json"))
        try require(StudioCatalogRead.load(at: link).recoveryFile == link &&
            (try manager.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType) == .typeSymbolicLink,
            "Dangling existing catalog path was treated as absence")
        print("PASS: actual absent/valid/invalid/unreadable/backed-up/dangling catalog reads preserve original bytes")
    }

    static func run() async throws {
        let manager = FileManager.default
        let root = GuestFixtureStorage.machineDirectory
        let catalogURL = root.appendingPathComponent("projects.v1.json")
        let history = root.appendingPathComponent("History/projects.v1.json", isDirectory: true)
        var seed = StudioProjectCatalog()
        let other = StudioProject(name: "Existing independent show")
        seed.projects.append(other)
        try verifyCatalogReads(root, seed: seed)
        try JSONEncoder().encode(seed).write(to: catalogURL, options: .atomic)
        let protected = root.appendingPathComponent(StudioProjectCatalog.relativeDirectory(project: other.id,
            profile: other.profiles[0].id), isDirectory: true).appendingPathComponent("existing-sentinel")
        try manager.createDirectory(at: protected.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("preserve existing show".utf8).write(to: protected)

        let scene = Scene(id: SceneID(), name: "Owned transaction scene", layers: [])
        let document = SceneDocument(sources: [], scenes: [scene], selectedID: scene.id)
        let package = root.appendingPathComponent("Transaction.streamshow", isDirectory: true)
        try ShowPackageIO.export(documents: ["stream.scenes.v2.json": JSONEncoder().encode(document)],
            media: [], name: "Owned transaction show", includeMedia: false, to: package)
        let workspace = StudioWorkspace()

        // The old importer silently publishes while saveCatalog refuses to save.
        try await preview(package, in: workspace)
        let recoveryPreview = workspace.importPreview?.id
        let recoveryBytes = try Data(contentsOf: catalogURL)
        let recoveryFiles = sceneFiles(root)
        let recoveryReads = PackageReadProbe.count("import", package)
        workspace.recoveryFile = catalogURL
        await workspace.importPreviewedPackage()
        try require(workspace.catalog == seed && workspace.pending == nil && workspace.importPreview?.id == recoveryPreview,
            "Unaccepted recovered catalog allowed import publication or dismissed retry preview")
        try require(try Data(contentsOf: catalogURL) == recoveryBytes && sceneFiles(root) == recoveryFiles,
            "Recovery refusal mutated durable catalog or copied new files")
        try require(PackageReadProbe.count("import", package) == recoveryReads && workspace.error != nil,
            "Recovery refusal copied a package or omitted actionable error")
        workspace.recoveryFile = nil
        print("PASS: unresolved catalog recovery refuses before copy and retains preview")

        // A regular file blocks the actual history-directory preparation before
        // its atomic catalog write. No IO-error substitute is used here.
        try manager.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: history.path) { try manager.removeItem(at: history) } // Owned fixture init history only.
        try Data("owned history blocker".utf8).write(to: history)
        do {
            defer { try? manager.removeItem(at: history) }
            let before = try Data(contentsOf: catalogURL)
            let files = sceneFiles(root)
            workspace.error = nil
            await workspace.importPreviewedPackage()
            try require(workspace.catalog == seed && workspace.pending == nil && workspace.importPreview?.id == recoveryPreview,
                "Failed precommit import published model/staging or dismissed its retry preview")
            try require(try Data(contentsOf: catalogURL) == before && sceneFiles(root) == files,
                "Verified precommit failure changed catalog or retained its owned copied profile")
            try require(try Data(contentsOf: protected) == Data("preserve existing show".utf8) && workspace.error != nil,
                "Import rollback touched existing show data or omitted the write failure")
        }
        await workspace.importPreviewedPackage()
        try require(workspace.catalog.projects.count == seed.projects.count + 1 && workspace.importPreview == nil,
            "Explicit retry after verified precommit rollback did not commit")
        let committed = try JSONDecoder().decode(StudioProjectCatalog.self, from: Data(contentsOf: catalogURL))
        try require(committed == workspace.catalog && workspace.pending != nil,
            "Import model/staging preceded durable candidate equality")
        print("PASS: actual precommit failure rolls back only new files; explicit retry persists before publication")

        // Actual archive/save methods may finish while the detached copy waits.
        try await preview(package, in: workspace)
        let entered = PackageReadProbe.count("import", package)
        PackageReadProbe.hold("import", package)
        let importing = Task { await workspace.importPreviewedPackage() }
        try await wait("Concurrent-edit package copy did not enter") { PackageReadProbe.count("import", package) == entered + 1 }
        workspace.archive(other.id, archived: true)
        try require(workspace.catalog.projects.first(where: { $0.id == other.id })?.isArchived == true,
            "Actual concurrent archive did not execute")
        PackageReadProbe.release("import", package)
        await importing.value
        let concurrent = try JSONDecoder().decode(StudioProjectCatalog.self, from: Data(contentsOf: catalogURL))
        try require(concurrent == workspace.catalog && concurrent.projects.first(where: { $0.id == other.id })?.isArchived == true,
            "Import overwrote the current durable catalog with its entry snapshot")
        print("PASS: candidate uses current durable catalog after legitimate intervening edit")

        // Give the actual history-pruning loop an immutable oldest owned file.
        // Backup creation and atomic catalog save succeed; only removal fails.
        try manager.createDirectory(at: history, withIntermediateDirectories: true)
        let immutable = history.appendingPathComponent("0000-owned-pruning.json")
        var ownedHistory: [URL] = []
        do {
            defer {
                try? manager.setAttributes([.immutable: false], ofItemAtPath: immutable.path)
                for url in ownedHistory { try? manager.removeItem(at: url) }
            }
            for index in 0..<21 {
                let url = index == 0 ? immutable : history.appendingPathComponent(String(format: "1000-owned-%02d.json", index))
                try Data("{}".utf8).write(to: url)
                ownedHistory.append(url)
            }
            try manager.setAttributes([.immutable: true], ofItemAtPath: immutable.path)
            try await preview(package, in: workspace)
            let before = workspace.catalog.projects.count
            await workspace.importPreviewedPackage()
            let saved = try JSONDecoder().decode(StudioProjectCatalog.self, from: Data(contentsOf: catalogURL))
            try require(saved == workspace.catalog && saved.projects.count == before + 1 && workspace.importPreview == nil,
                "Postcommit pruning error rolled back a durable show or omitted publication")
            try require(workspace.error?.contains("saved") == true && manager.fileExists(atPath: immutable.path),
                "Actual postcommit history failure was not retained as a saved-show warning")
            guard let target = workspace.pending else { throw CocoaError(.fileNoSuchFile) }
            try require(manager.fileExists(atPath: workspace.directory(for: target).appendingPathComponent("stream.scenes.v2.json").path),
                "Postcommit cleanup deleted catalog-referenced imported files")
        }
        print("PASS: actual pruning exception after atomic save confirms durable catalog and retains referenced files")

        // A throwing actual package read must also respect retired UI authority.
        try await preview(package, in: workspace)
        let manifestURL = package.appendingPathComponent("manifest.json")
        let manifest = try Data(contentsOf: manifestURL)
        try Data("{}".utf8).write(to: manifestURL)
        let priorBytes = try Data(contentsOf: catalogURL)
        let priorCatalog = workspace.catalog
        let thrownCount = PackageReadProbe.count("import", package)
        PackageReadProbe.hold("import", package)
        let throwing = Task { await workspace.importPreviewedPackage() }
        try await wait("Actual throwing package IO did not enter hold") { PackageReadProbe.count("import", package) == thrownCount + 1 }
        workspace.importPreview = nil
        workspace.error = "Newer UI intent sentinel"
        try require(workspace.packageBusy, "Canceled throwing IO prematurely released capacity")
        PackageReadProbe.release("import", package)
        await throwing.value
        try manifest.write(to: manifestURL)
        try require(!workspace.packageBusy && workspace.error == "Newer UI intent sentinel" && workspace.catalog == priorCatalog,
            "Retired throwing copy replaced current UI error or model")
        try require(try Data(contentsOf: catalogURL) == priorBytes, "Canceled throwing copy changed catalog")
        print("PASS: late real import error cannot overwrite newer canceled-preview UI authority")

        // Only this final readback is an explicit inert external boundary. The
        // actual package copy and actual catalog write complete in both cases.
        var active = workspace
        for reply in [PackageCatalogReadProbe.Reply.unavailable, .unexpected] {
            try await preview(package, in: active)
            let modelBefore = active.catalog
            let importsBefore = PackageReadProbe.count("import", package)
            PackageCatalogReadProbe.nextReply = reply
            await active.importPreviewedPackage()
            let durable = try JSONDecoder().decode(StudioProjectCatalog.self, from: Data(contentsOf: catalogURL))
            try require(active.catalog == modelBefore && durable.projects.count == modelBefore.projects.count + 1 && active.importPreview != nil,
                "Ambiguous readback published unconfirmed model or discarded retry preview")
            let diskBeforeBlockedEdit = try Data(contentsOf: catalogURL)
            active.archive(other.id, archived: false)
            await active.importPreviewedPackage()
            try require(active.catalog == modelBefore && (try Data(contentsOf: catalogURL)) == diskBeforeBlockedEdit,
                "Uncertain write allowed stale ordinary catalog edit to overwrite durable candidate")
            try require(PackageReadProbe.count("import", package) == importsBefore + 1,
                "Uncertain write admitted a duplicate import retry")
            let appended = durable.projects.last!
            let path = root.appendingPathComponent(StudioProjectCatalog.relativeDirectory(project: appended.id,
                profile: appended.profiles[0].id)).appendingPathComponent("stream.scenes.v2.json")
            try require(manager.fileExists(atPath: path.path), "Ambiguous commit deleted potentially referenced files")
            do {
                defer { try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: catalogURL.path) }
                try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: catalogURL.path)
                try require((try? Data(contentsOf: catalogURL)) == nil, "Owned restart read-denial control failed")
                let unreadableRestart = StudioWorkspace()
                try require(unreadableRestart.recoveryFile == catalogURL,
                    "Restart treated unreadable committed catalog as fresh and allowed auto-save")
            }
            try require(try Data(contentsOf: catalogURL) == diskBeforeBlockedEdit,
                "Unreadable restart replaced potentially committed catalog bytes")
            active = StudioWorkspace() // Actual helper + save guard; no runtime.
            try require(active.catalog == durable, "Explicit readable reopen did not recover durable catalog state")
        }
        print("PASS: unreadable/unexpected readback retains data and blocks all stale catalog saves/imports until reload")
        try require(try Data(contentsOf: protected) == Data("preserve existing show".utf8), "Existing protected data changed")
        try require(!workspace.runtime.controller.outputSessionActive && !workspace.runtime.recorder.state.isActive,
            "Package fixture allocated an output")
    }
}
