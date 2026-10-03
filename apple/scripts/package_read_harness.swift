import AppKit
import Foundation
import Security
import StreamCore

@MainActor struct PackageReadFixtureCredentials: StudioControlCredentials {
    func read(_ id: UUID) -> String? { nil }
    func write(_ token: String, for id: UUID) -> OSStatus { errSecSuccess }
    func delete(_ id: UUID) -> OSStatus { errSecSuccess }
}

// Generated tool-only IO probes hold the completion of an actual shipping
// preview/import. They neither substitute package data nor cancel the worker.
enum PackageReadProbe {
    private final class State: @unchecked Sendable {
        let condition = NSCondition()
        var held: Set<String> = [], entered: [String: Int] = [:]
        var delivered: [String: Int] = [:]
    }
    private static let state = State()
    private static func key(_ kind: String, _ url: URL) -> String { kind + ":" + url.lastPathComponent }
    static func hold(_ kind: String, _ url: URL) {
        state.condition.lock(); state.held.insert(key(kind, url)); state.condition.unlock()
    }
    static func release(_ kind: String, _ url: URL) {
        state.condition.lock(); state.held.remove(key(kind, url)); state.condition.broadcast(); state.condition.unlock()
    }
    static func count(_ kind: String, _ url: URL, delivered: Bool = false) -> Int {
        state.condition.lock(); defer { state.condition.unlock() }
        return (delivered ? state.delivered : state.entered)[key(kind, url), default: 0]
    }
    private static func completedIO(_ kind: String, _ url: URL) {
        state.condition.lock(); defer { state.condition.unlock() }
        let key = key(kind, url)
        state.entered[key, default: 0] += 1
        let deadline = Date().addingTimeInterval(15)
        while state.held.contains(key) {
            precondition(state.condition.wait(until: deadline), "Owned actual IO completion hold exceeded15 seconds")
        }
    }
    static func preview(_ url: URL) throws -> ShowPackagePreview {
        let result = Result { try ShowPackageIO.preview(url) }
        completedIO("preview", url)
        return try result.get()
    }
    static func importFiles(from source: URL, to destination: URL) throws {
        let result = Result { try ShowPackageIO.importFiles(from: source, to: destination) }
        completedIO("import", source)
        return try result.get()
    }
    static func previewReturned(_ url: URL) {
        state.condition.lock(); state.delivered[key("preview", url), default: 0] += 1; state.condition.unlock()
    }
    static func releaseAll() {
        state.condition.lock(); state.held.removeAll(); state.condition.broadcast(); state.condition.unlock()
    }
}

extension GuestFixtureStorage {
    static var recordingsDirectory: URL { machineDirectory.appendingPathComponent("Recordings") }
}

private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw NSError(domain: "PackageReadHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@main @MainActor struct PackageReadHarness {
    static func main() async {
        setbuf(stdout, nil)
        defer { PackageReadProbe.releaseAll() }
        do { try await run(); print("PASS: actual package IO + shipping Workspace latest-preview/write ownership and retained read capacity") }
        catch { print("FAIL: \(String(describing: error))"); exit(1) }
    }
    static func wait(_ message: String, until test: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while !test() {
            try require(ContinuousClock.now < deadline, message)
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    static func package(_ name: String, root: URL) throws -> URL {
        let scene = Scene(id: SceneID(), name: name, layers: [LayerNode(name: name,
            payload: .text(TextSourcePayload(text: name)), transform: .fullscreen)])
        let document = SceneDocument(sources: [], scenes: [scene], selectedID: scene.id)
        let url = root.appendingPathComponent(name + ".streamshow", isDirectory: true)
        try ShowPackageIO.export(documents: ["stream.scenes.v2.json": JSONEncoder().encode(document)],
            media: [], name: name, includeMedia: false, to: url)
        return url
    }
    static func run() async throws {
        let root = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? GuestFixtureStorage.machineDirectory.appendingPathComponent("PackageReads", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let packages = try (0..<8).map { try package("OwnedPackage\($0)", root: root) }
        // Seed the isolated catalog/profile before constructing the real graph;
        // first-launch legacy migration is outside package-read qualification.
        let seed = StudioProjectCatalog()
        try JSONEncoder().encode(seed).write(to: GuestFixtureStorage.machineDirectory.appendingPathComponent("projects.v1.json"))
        try FileManager.default.createDirectory(at: GuestFixtureStorage.machineDirectory.appendingPathComponent(
            StudioProjectCatalog.relativeDirectory(project: seed.selectedProjectID, profile: seed.selectedProfileID)),
            withIntermediateDirectories: true)
        let workspace = StudioWorkspace()
        let a = packages[0], b = packages[1], c = packages[2]
        PackageReadProbe.hold("preview", a); workspace.previewPackage(a)
        try await wait("Actual A read was not held") { PackageReadProbe.count("preview", a) == 1 }
        workspace.previewPackage(b)
        try await wait("Actual B read did not publish") { !workspace.packageBusy && workspace.importPreview?.url == b }
        PackageReadProbe.release("preview", a)
        try await wait("Actual A completion did not return to Workspace") { PackageReadProbe.count("preview", a, delivered: true) == 1 }
        try require(workspace.importPreview?.url == b && !workspace.packageBusy,
            "Slow actual A completion replaced newer B preview")
        print("PASS: actual slow A completion cannot replace actual B preview")

        PackageReadProbe.hold("preview", a); workspace.previewPackage(a)
        try await wait("Second A read was not held") { PackageReadProbe.count("preview", a) == 2 }
        PackageReadProbe.hold("preview", c); workspace.previewPackage(c)
        try await wait("Actual C read was not held") { PackageReadProbe.count("preview", c) == 1 }
        PackageReadProbe.release("preview", a)
        try await wait("Second A completion did not return") { PackageReadProbe.count("preview", a, delivered: true) == 2 }
        try require(workspace.packageBusy, "Stale A completion cleared latest C busy")
        PackageReadProbe.release("preview", c)
        try await wait("Actual C did not publish") { workspace.importPreview?.url == c && !workspace.packageBusy }
        print("PASS: stale completion cannot clear latest actual read busy")

        let held = Array(packages[3...6]), rejected = packages[7]
        for url in held {
            PackageReadProbe.hold("preview", url); workspace.previewPackage(url)
            try await wait("Held capacity read did not enter") { PackageReadProbe.count("preview", url) == 1 }
        }
        workspace.importPreview = nil // Actual shipping sheet cancellation.
        try require(!workspace.packageBusy, "Cancel did not clear preview authority")
        for _ in 0..<8 { workspace.previewPackage(rejected); workspace.importPreview = nil }
        try require(PackageReadProbe.count("preview", rejected) == 0 && workspace.error != nil,
            "Cancellation evicted occupied reads or a fifth actual read was admitted")
        PackageReadProbe.release("preview", held[0])
        try await wait("Retained canceled read did not return") { PackageReadProbe.count("preview", held[0], delivered: true) == 1 }
        workspace.previewPackage(rejected)
        try await wait("Returned capacity did not admit an explicit new read") { workspace.importPreview?.url == rejected && !workspace.packageBusy }
        for url in held.dropFirst() { PackageReadProbe.release("preview", url) }
        try await wait("Canceled held reads did not clean up") { held.allSatisfy { PackageReadProbe.count("preview", $0, delivered: true) == 1 } }
        try require(workspace.importPreview?.url == rejected && !workspace.packageBusy,
            "Canceled completion restored an obsolete preview")
        print("PASS: four noncooperative reads stay occupied across cancellation; fifth refused until real return")

        let malformed = root.appendingPathComponent("OwnedMalformed.streamshow", isDirectory: true)
        workspace.error = nil
        PackageReadProbe.hold("preview", malformed); workspace.previewPackage(malformed)
        try await wait("Actual malformed read was not held") { PackageReadProbe.count("preview", malformed) == 1 }
        workspace.previewPackage(b)
        try await wait("B preview did not replace pending malformed read") { workspace.importPreview?.url == b && !workspace.packageBusy }
        PackageReadProbe.release("preview", malformed)
        try await wait("Malformed read completion did not return") { PackageReadProbe.count("preview", malformed, delivered: true) == 1 }
        try require(workspace.importPreview?.url == b && workspace.error == nil && !workspace.packageBusy,
            "Late actual malformed read replaced the latest preview/error/busy")
        workspace.previewPackage(malformed)
        try await wait("Latest malformed read did not report its actual failure") {
            PackageReadProbe.count("preview", malformed, delivered: true) == 2 && !workspace.packageBusy
        }
        try require(workspace.importPreview == nil && workspace.error != nil,
            "Latest actual read failure kept a stale import target or omitted its error")
        print("PASS: late real read failure is ignored; current malformed read closes stale preview and reports failure")

        workspace.previewPackage(a)
        try await wait("Import source A preview missing") { workspace.importPreview?.url == a && !workspace.packageBusy }
        PackageReadProbe.hold("import", a)
        let oldCount = workspace.catalog.projects.count
        let importing = Task { await workspace.importPreviewedPackage() }
        try await wait("Actual A import was not held") { PackageReadProbe.count("import", a) == 1 }
        let readsB = PackageReadProbe.count("preview", b)
        workspace.previewPackage(b)
        workspace.exportPackage(includeMedia: false, selectedSceneOnly: false)
        try require(workspace.packageBusy && workspace.importPreview?.url == a && workspace.error != nil,
            "Native preview/export during import cleared write busy or replaced captured source")
        try require(PackageReadProbe.count("preview", b) == readsB,
            "Native delivery allocated another read during active import")
        workspace.importPreview = nil; importing.cancel()
        workspace.previewPackage(b)
        await workspace.importPreviewedPackage()
        try require(workspace.packageBusy && workspace.catalog.projects.count == oldCount
            && PackageReadProbe.count("preview", b) == readsB,
            "Sheet/task cancellation released an occupied import or admitted another package")
        PackageReadProbe.release("import", a); await importing.value
        try require(!workspace.packageBusy && workspace.catalog.projects.count == oldCount + 1,
            "Actual import did not finish its exclusive write")
        let staged = try workspace.pending.unwrap("Imported show was not staged")
        let data = try Data(contentsOf: workspace.directory(for: staged).appendingPathComponent("stream.scenes.v2.json"))
        let imported = try JSONDecoder().decode(SceneDocument.self, from: data)
        try data.write(to: root.appendingPathComponent("actual-imported-scenes.json"), options: .atomic)
        try require(workspace.catalog.projects.last?.name == "OwnedPackage0" && imported.scenes.first?.name == "OwnedPackage0",
            "Actual imported data/catalog came from a replacement package")
        print("PASS: native preview/export and sheet/task cancellation cannot overlap actual import; catalog and real copied scene retain source A")
        try require(!workspace.runtime.controller.outputSessionActive && !workspace.runtime.recorder.state.isActive,
            "Package fixture allocated an output")
        print("Owned synthetic package/read evidence: \(root.path)")
    }
}

private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let value = self else { throw NSError(domain: "PackageReadHarness", code: 2, userInfo: [NSLocalizedDescriptionKey: message]) }
        return value
    }
}
