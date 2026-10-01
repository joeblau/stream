import Foundation
import Testing
@testable import StreamCore

/// P03 (issue #80): asset library model, dedup planning, missing-state logic,
/// and the security-scoped bookmark codec. Everything here is pure StreamCore
/// logic — no host app — so the suite runs on the iOS simulator like the rest
/// of StreamCoreTests.
@Suite struct AssetLibraryTests {

    // MARK: - Helpers

    private func makeAsset(storage: AssetStorage = .linked,
                           contentHash: String? = nil,
                           path: String = "/tmp/a.mp4") -> LibraryAsset {
        LibraryAsset(name: "A",
                     kind: .video,
                     storage: storage,
                     relativePath: storage == .projectCopy ? "Assets/x/a.mp4" : nil,
                     fileName: "a.mp4",
                     contentHash: contentHash,
                     lastKnownPath: path,
                     // A whole-second date round-trips exactly through the
                     // JSON encoder's Double representation.
                     addedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func tempFile(named name: String = "clip.mp4",
                          contents: String = "hello stream") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("assetlib-\(UUID().uuidString)")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: - Document wire format (additive decode)

    @Test("An empty object decodes to an empty library")
    func emptyDocumentDecodes() throws {
        let doc = try JSONDecoder().decode(AssetLibraryDocument.self, from: Data("{}".utf8))
        #expect(doc.version == AssetLibraryDocument.currentVersion)
        #expect(doc.assets.isEmpty)
        #expect(doc.usage.isEmpty)
    }

    @Test("A document round-trips assets and usage")
    func documentRoundTrip() throws {
        var doc = AssetLibraryDocument()
        let asset = makeAsset(storage: .projectCopy, contentHash: "abc123")
        doc.assets = [asset]
        doc.recordUsage(site: "mediaSource/\(UUID().uuidString)", assetID: asset.id)
        let decoded = try JSONDecoder().decode(
            AssetLibraryDocument.self, from: JSONEncoder().encode(doc))
        #expect(decoded == doc)
    }

    @Test("An asset record written before later fields existed decodes with defaults")
    func legacyAssetDecodes() throws {
        let json = #"{"name": "Logo", "fileName": "logo.png", "lastKnownPath": "/x/logo.png"}"#
        let asset = try JSONDecoder().decode(LibraryAsset.self, from: Data(json.utf8))
        #expect(asset.name == "Logo")
        #expect(asset.kind == .other)
        #expect(asset.storage == .linked)
        #expect(asset.bookmarkData == nil)
        #expect(asset.metadata.byteSize == nil)
    }

    @Test("Unknown future keys are ignored (forward compatibility)")
    func unknownKeysIgnored() throws {
        let json = #"{"version": 1, "assets": [], "usage": {}, "future": {"x": 1}}"#
        let doc = try JSONDecoder().decode(AssetLibraryDocument.self, from: Data(json.utf8))
        #expect(doc.assets.isEmpty)
    }

    // MARK: - Dedup (import planning)

    @Test("Copy import of byte-identical content reuses the existing project copy")
    func copyDedupReusesExisting() throws {
        let existing = makeAsset(storage: .projectCopy, contentHash: "hash-1")
        let decision = AssetImportPlanner.decide(mode: .copy,
                                                 contentHash: "hash-1",
                                                 resolvedPath: "/elsewhere/renamed.mp4",
                                                 existing: [existing])
        #expect(decision == .reuseExisting(existing.id))
    }

    @Test("Copy import of new content imports a new asset")
    func copyNewContentImportsNew() {
        let existing = makeAsset(storage: .projectCopy, contentHash: "hash-1")
        let decision = AssetImportPlanner.decide(mode: .copy,
                                                 contentHash: "hash-2",
                                                 resolvedPath: "/elsewhere/b.mp4",
                                                 existing: [existing])
        #expect(decision == .importNew)
    }

    @Test("Unhashable candidates (folders) never dedup by content")
    func folderNeverDedupsByHash() {
        let existing = makeAsset(storage: .projectCopy, contentHash: nil)
        let decision = AssetImportPlanner.decide(mode: .copy,
                                                 contentHash: nil,
                                                 resolvedPath: "/Volumes/X/folder",
                                                 existing: [existing])
        #expect(decision == .importNew)
    }

    @Test("Link import of the same resolved path reuses the existing linked asset")
    func linkDedupByPath() throws {
        let existing = makeAsset(storage: .linked, path: "/Users/j/Movies/intro.mp4")
        let decision = AssetImportPlanner.decide(mode: .link,
                                                 contentHash: "hash-9",
                                                 resolvedPath: "/Users/j/Movies/intro.mp4",
                                                 existing: [existing])
        #expect(decision == .reuseExisting(existing.id))
    }

    @Test("Link import never dedups against a project copy (different ownership)")
    func linkNeverMatchesProjectCopy() {
        let existing = makeAsset(storage: .projectCopy, contentHash: "hash-1")
        let decision = AssetImportPlanner.decide(mode: .link,
                                                 contentHash: "hash-1",
                                                 resolvedPath: "/Users/j/Movies/intro.mp4",
                                                 existing: [existing])
        #expect(decision == .importNew)
    }

    @Test("Copy import never dedups against a linked asset's hash")
    func copyNeverMatchesLinked() {
        let existing = makeAsset(storage: .linked, contentHash: "hash-1")
        let decision = AssetImportPlanner.decide(mode: .copy,
                                                 contentHash: "hash-1",
                                                 resolvedPath: "/tmp/pick.mp4",
                                                 existing: [existing])
        #expect(decision == .importNew)
    }

    // MARK: - Missing-state logic (availability evaluation)

    @Test("Project copies are available iff the container file exists")
    func projectCopyAvailability() {
        #expect(AssetAvailabilityEvaluator.evaluate(
            AssetAvailabilityProbe(storage: .projectCopy, projectCopyExists: true)) == .available)
        #expect(AssetAvailabilityEvaluator.evaluate(
            AssetAvailabilityProbe(storage: .projectCopy, projectCopyExists: false))
            == .missing(.projectCopyMissing))
    }

    @Test("A linked asset with no bookmark is missing as not-linked")
    func linkedNoBookmark() {
        #expect(AssetAvailabilityEvaluator.evaluate(
            AssetAvailabilityProbe(storage: .linked, hasBookmark: false))
            == .missing(.notLinked))
    }

    @Test("An unresolvable bookmark is a broken link")
    func linkedUnresolvableBookmark() {
        #expect(AssetAvailabilityEvaluator.evaluate(
            AssetAvailabilityProbe(storage: .linked,
                                   hasBookmark: true,
                                   bookmarkResolved: false))
            == .missing(.bookmarkUnresolvable))
    }

    @Test("A resolved bookmark with a missing file on a mounted volume reads moved/deleted")
    func linkedFileMoved() {
        #expect(AssetAvailabilityEvaluator.evaluate(
            AssetAvailabilityProbe(storage: .linked,
                                   hasBookmark: true,
                                   bookmarkResolved: true,
                                   resolvedFileExists: false,
                                   volumeMounted: true))
            == .missing(.fileMovedOrDeleted))
    }

    @Test("A missing file on an unmounted volume reads as external disk disconnected")
    func linkedVolumeDisconnected() {
        #expect(AssetAvailabilityEvaluator.evaluate(
            AssetAvailabilityProbe(storage: .linked,
                                   hasBookmark: true,
                                   bookmarkResolved: true,
                                   resolvedFileExists: false,
                                   volumeMounted: false))
            == .missing(.externalVolumeDisconnected))
    }

    @Test("An existing file the sandbox refuses reads as access revoked")
    func linkedAccessRevoked() {
        #expect(AssetAvailabilityEvaluator.evaluate(
            AssetAvailabilityProbe(storage: .linked,
                                   hasBookmark: true,
                                   bookmarkResolved: true,
                                   resolvedFileExists: true,
                                   accessGranted: false))
            == .missing(.accessRevoked))
    }

    @Test("A stale bookmark that still resolves and reads is available (refreshed, not missing)")
    func linkedStaleStillAvailable() {
        #expect(AssetAvailabilityEvaluator.evaluate(
            AssetAvailabilityProbe(storage: .linked,
                                   hasBookmark: true,
                                   bookmarkResolved: true,
                                   bookmarkStale: true,
                                   resolvedFileExists: true,
                                   accessGranted: true)) == .available)
    }

    // MARK: - Bookmark round-trip

    @Test("A bookmark round-trips to the same file, not stale")
    func bookmarkRoundTrip() throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let bookmark = try #require(AssetBookmarkCodec.makeBookmark(for: url))
        let resolved = try #require(AssetBookmarkCodec.resolve(bookmark))
        #expect(resolved.url.standardizedFileURL.path == url.standardizedFileURL.path)
        #expect(resolved.isStale == false)
    }

    @Test("Resolving garbage bookmark data fails cleanly (repairable, not a crash)")
    func bookmarkGarbageFailsCleanly() {
        #expect(AssetBookmarkCodec.resolve(Data([0x00, 0x01, 0x02])) == nil)
    }

    @Test("A deleted file's bookmark never resolves to an existing file (missing surfaces, never stale-green)")
    func bookmarkNeverResolvesToDeletedFile() throws {
        let url = try tempFile()
        let bookmark = try #require(AssetBookmarkCodec.makeBookmark(for: url))
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        // macOS often still resolves the stale path (the file-level probe then
        // reports moved/deleted); iOS refuses resolution outright (the probe
        // reports a broken link). Either way the outcome is a repairable
        // missing state — the one thing that must NEVER happen is resolving
        // to a file that exists, which would light the row green falsely.
        if let resolved = AssetBookmarkCodec.resolve(bookmark) {
            #expect(FileManager.default.fileExists(atPath: resolved.url.path) == false)
        }
    }

    // MARK: - Content hashing

    @Test("Identical bytes hash identically; different bytes differ")
    func contentHashIdentity() throws {
        let a = try tempFile(named: "a.mp4", contents: "same bytes")
        let b = try tempFile(named: "renamed.mp4", contents: "same bytes")
        let c = try tempFile(named: "c.mp4", contents: "different bytes")
        defer {
            for url in [a, b, c] {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }
        let hashA = try #require(AssetContentHasher.sha256(contentsOf: a))
        let hashB = try #require(AssetContentHasher.sha256(contentsOf: b))
        let hashC = try #require(AssetContentHasher.sha256(contentsOf: c))
        // Content-addressed, not name-addressed: the renamed copy dedups.
        #expect(hashA == hashB)
        #expect(hashA != hashC)
        #expect(hashA.count == 64) // hex SHA-256
    }

    @Test("Directories and missing files are unhashable (nil, never a crash)")
    func hashEdgeCases() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("assetlib-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(AssetContentHasher.sha256(contentsOf: dir) == nil)
        #expect(AssetContentHasher.sha256(
            contentsOf: dir.appendingPathComponent("nope.mp4")) == nil)
    }

    // MARK: - Kind inference

    @Test("Kinds infer from extensions; directories are folders")
    func kindInference() {
        #expect(AssetKind.inferring(fromExtension: "MP4") == .video)
        #expect(AssetKind.inferring(fromExtension: "wav") == .audio)
        #expect(AssetKind.inferring(fromExtension: "heic") == .image)
        #expect(AssetKind.inferring(fromExtension: "pdf") == .document)
        #expect(AssetKind.inferring(fromExtension: "xyz") == .other)
        #expect(AssetKind.inferring(fromExtension: "", isDirectory: true) == .folder)
    }

    // MARK: - Usage tracking seams

    @Test("Usage records idempotently, lists sites, and tears down per site")
    func usageLifecycle() {
        var doc = AssetLibraryDocument(assets: [makeAsset()])
        let id = doc.assets[0].id
        doc.recordUsage(site: "mediaSource/1", assetID: id)
        doc.recordUsage(site: "mediaSource/1", assetID: id) // idempotent
        doc.recordUsage(site: "overlay/2", assetID: id)
        #expect(doc.usage["mediaSource/1"] == [id])
        #expect(doc.usageSites(of: id) == ["mediaSource/1", "overlay/2"])
        doc.removeUsage(site: "overlay/2", assetID: id)
        #expect(doc.usageSites(of: id) == ["mediaSource/1"])
        doc.removeAllUsage(site: "mediaSource/1")
        #expect(doc.usageSites(of: id).isEmpty)
        #expect(doc.usage.isEmpty)
    }

    @Test("Usage edges to deleted assets prune on load hygiene")
    func usagePrunesWithAsset() {
        let kept = makeAsset()
        let dropped = makeAsset()
        var doc = AssetLibraryDocument(assets: [kept, dropped])
        doc.recordUsage(site: "mediaSource/1", assetID: kept.id)
        doc.recordUsage(site: "mediaSource/1", assetID: dropped.id)
        doc.assets.removeAll { $0.id == dropped.id }
        doc.pruneUsage()
        #expect(doc.usage["mediaSource/1"] == [kept.id])
    }

    @Test("Usage records reject unknown assets and blank sites")
    func usageValidation() {
        var doc = AssetLibraryDocument()
        doc.recordUsage(site: "mediaSource/1", assetID: AssetID())
        doc.recordUsage(site: "  ", assetID: AssetID())
        #expect(doc.usage.isEmpty)
    }
}
