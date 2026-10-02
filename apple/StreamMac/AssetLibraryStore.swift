import AVFoundation
import AppKit
import Combine
import Foundation
import ImageIO
import StreamCore
import UniformTypeIdentifiers

/// P03 (issue #80): the asset library's persisted model and runtime.
///
/// **Ownership.** Two modes per asset: PROJECT COPIES live in the App Group
/// container's `Assets/` folder (the project owns the bytes; imports dedup by
/// content hash), LINKED references persist a security-scoped bookmark to the
/// user's original file/folder (the sandbox access grant — A02's pattern).
///
/// **Persistence.** The registry document (`stream.assets.v1.json`) sits in
/// the shared App Group container beside the scene/soundboard documents and
/// follows the same rules: additive `decodeIfPresent` wire format, debounced
/// autosave with atomic writes, quarantine-on-corrupt (never crash-loop,
/// never overwrite unreadable bytes), flush on termination.
///
/// **Availability.** Session state, probed asynchronously — a moved file, a
/// revoked grant, or a disconnected external disk surfaces as a repairable
/// per-asset MISSING state (relink/replace) without stalling anything: probes
/// run off the main actor, and consumers never block on resolution. Probes
/// re-run on import/relink/replace, on volume mount/unmount, and when the app
/// reactivates (files can move while Stream is in the background).
///
/// **Usage seams.** Consumers (G01 media, G06 images, G08 soundboard, E04
/// overlays) register namespaced site keys ("mediaSource/<uuid>") via
/// `noteUsage(of:from:)` so the panel can show where an asset is used and
/// warn before removing an in-use asset. Consumers read bytes through
/// `access(for:)`, which holds the security-scope grant for them.
@MainActor
final class AssetLibraryStore: ObservableObject {
    /// Every registered asset, in import order.
    @Published private(set) var assets: [LibraryAsset] {
        didSet { scheduleAutosave() }
    }
    /// The latest probe result per asset (`.unknown` before the first probe).
    @Published private(set) var availability: [AssetID: AssetAvailability] = [:]
    /// Usage site key → referenced asset IDs (the document's usage map).
    @Published private(set) var usage: [String: [AssetID]] {
        didSet { scheduleAutosave() }
    }

    private static let fileName = "stream.assets.v1.json"
    /// Container-relative folder holding project-owned copies.
    private static let copiesFolderName = "Assets"
    private static let autosaveDelay: TimeInterval = 0.75

    private var autosaveTask: Task<Void, Never>?
    private var probeGeneration = 0
    /// `nonisolated(unsafe)` so `deinit` can unregister (the store lives for
    /// the app's lifetime; belt-and-braces like the other stores).
    nonisolated(unsafe) private var terminationObserver: NSObjectProtocol?
    nonisolated(unsafe) private var activationObserver: NSObjectProtocol?
    nonisolated(unsafe) private var workspaceObservers: [NSObjectProtocol] = []

    private let directory: URL

    init(directory: URL = DesktopStorage.projectDirectory) {
        self.directory = directory
        var document = Self.loadDocument(url: directory.appendingPathComponent(Self.fileName)) ?? AssetLibraryDocument()
        document.pruneUsage()
        assets = document.assets
        usage = document.usage
        // Every asset starts `.unknown` until its first probe lands.
        availability = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, .unknown) })
        refreshAvailability()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushPendingWrites() }
        }
        // External disks connecting/disconnecting change availability without
        // any user action inside Stream — re-probe on volume events and on
        // reactivation (files can move while Stream is backgrounded).
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            workspaceObservers.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAvailability() }
            })
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAvailability() }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Lookups

    func asset(withID id: AssetID) -> LibraryAsset? {
        assets.first(where: { $0.id == id })
    }

    /// Assets whose latest probe says missing (the repair list).
    var missingAssets: [LibraryAsset] {
        assets.filter { availability[$0.id]?.missingReason != nil }
    }

    func availability(of id: AssetID) -> AssetAvailability {
        availability[id] ?? .unknown
    }

    // MARK: - Usage seams (G01/G06/G08/E04)

    /// The site keys referencing an asset, sorted (the row's "Used by" list).
    func usageSites(of id: AssetID) -> [String] {
        usage.filter { $0.value.contains(id) }.map(\.key).sorted()
    }

    func isInUse(_ id: AssetID) -> Bool {
        usageSites(of: id).isEmpty == false
    }

    /// Records that `site` (e.g. "mediaSource/<uuid>") references `id`.
    /// Idempotent per site/asset pair.
    func noteUsage(of id: AssetID, from site: String) {
        var document = currentDocument()
        document.recordUsage(site: site, assetID: id)
        usage = document.usage
    }

    func removeUsage(of id: AssetID, from site: String) {
        var document = currentDocument()
        document.removeUsage(site: site, assetID: id)
        usage = document.usage
    }

    /// Drops every reference a consumer owns (e.g. a deleted media source).
    func clearUsage(site: String) {
        guard usage[site] != nil else { return }
        var document = currentDocument()
        document.removeAllUsage(site: site)
        usage = document.usage
    }

    private func currentDocument() -> AssetLibraryDocument {
        AssetLibraryDocument(assets: assets, usage: usage)
    }

    // MARK: - Import

    /// Imports one user-picked file/folder. `.copy` copies the bytes into the
    /// container (dedup: byte-identical content already in the library returns
    /// the EXISTING asset — no second copy, no second row); `.link` persists
    /// a security-scoped bookmark (dedup: the same resolved path returns the
    /// existing linked asset). Returns nil only when the pick is unreadable
    /// or the container is unavailable.
    @discardableResult
    func importFile(at url: URL, mode: AssetImportMode) async -> LibraryAsset? {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        let isDirectory = values?.isDirectory ?? false
        let standardizedPath = url.standardizedFileURL.path

        // Dedup BEFORE any file work (the hash is the copy-mode identity).
        let hash = isDirectory ? nil : await Self.hashFile(at: url)
        switch AssetImportPlanner.decide(mode: mode,
                                         contentHash: hash,
                                         resolvedPath: standardizedPath,
                                         existing: assets) {
        case .reuseExisting(let id):
            return asset(withID: id)
        case .importNew:
            break
        }

        let id = AssetID()
        let fileName = url.lastPathComponent
        var asset = LibraryAsset(
            id: id,
            name: url.deletingPathExtension().lastPathComponent,
            kind: AssetKind.inferring(fromExtension: url.pathExtension, isDirectory: isDirectory),
            storage: mode == .copy ? .projectCopy : .linked,
            fileName: fileName,
            contentHash: hash,
            lastKnownPath: standardizedPath)

        switch mode {
        case .copy:
            guard let containerURL = containerURL() else { return nil }
            let relativePath = "\(Self.copiesFolderName)/\(id.rawValue.uuidString)/\(fileName)"
            let destination = containerURL.appendingPathComponent(relativePath)
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                // The pick is security-scoped: hold access while copying.
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                return nil
            }
            asset.relativePath = relativePath
        case .link:
            // A nil bookmark is allowed through: the asset registers as
            // missing(.notLinked) — repairable — rather than vanishing.
            asset.bookmarkData = AssetBookmarkCodec.makeBookmark(for: url)
        }

        asset.metadata = await Self.gatherMetadata(for: url,
                                                   isDirectory: isDirectory,
                                                   byteSizeFallback: nil)
        assets.append(asset)
        availability[id] = .unknown
        refreshAvailability(of: id)
        return asset
    }

    /// Imports several picks in order (multi-select import), skipping
    /// unreadable ones.
    @discardableResult
    func importFiles(at urls: [URL], mode: AssetImportMode) async -> [LibraryAsset] {
        var imported: [LibraryAsset] = []
        for url in urls {
            if let asset = await importFile(at: url, mode: mode) {
                imported.append(asset)
            }
        }
        return imported
    }

    // MARK: - Repair: relink and replace

    /// Re-points a LINKED asset at its moved file: new bookmark, same
    /// identity, name, and usage. For project copies this is the "restore the
    /// container file from an original" repair: copies the picked file back
    /// over the missing copy. Either way the missing state clears if the
    /// probe passes.
    @discardableResult
    func relink(_ id: AssetID, to url: URL) async -> Bool {
        guard let index = assets.firstIndex(where: { $0.id == id }) else { return false }
        var asset = assets[index]
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        switch asset.storage {
        case .linked:
            guard let bookmark = AssetBookmarkCodec.makeBookmark(for: url) else { return false }
            asset.bookmarkData = bookmark
        case .projectCopy:
            guard let containerURL = containerURL(),
                  let relativePath = asset.relativePath else { return false }
            let destination = containerURL.appendingPathComponent(relativePath)
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                return false
            }
        }
        asset.fileName = url.lastPathComponent
        asset.lastKnownPath = url.standardizedFileURL.path
        asset.contentHash = await Self.hashFile(at: url)
        asset.metadata = await Self.gatherMetadata(for: url,
                                                   isDirectory: asset.kind == .folder,
                                                   byteSizeFallback: nil)
        assets[index] = asset
        refreshAvailability(of: id)
        return true
    }

    /// Swaps an asset's CONTENT while keeping its identity and usage (the
    /// "replace this logo/clip everywhere" action). Re-runs the full import
    /// pipeline under the existing ID — including copy-mode dedup: replacing
    /// with bytes already owned returns early, re-pointing this asset at the
    /// existing copy's storage.
    @discardableResult
    func replace(_ id: AssetID, with url: URL, mode: AssetImportMode? = nil) async -> Bool {
        guard let index = assets.firstIndex(where: { $0.id == id }) else { return false }
        let old = assets[index]
        let targetMode = mode ?? (old.storage == .projectCopy ? .copy : .link)
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
            ?? (old.kind == .folder)
        let standardizedPath = url.standardizedFileURL.path
        let hash = isDirectory ? nil : await Self.hashFile(at: url)

        // Replacing with content another project copy already owns: adopt its
        // storage so both assets reference one copy on disk.
        if targetMode == .copy, let hash,
           let match = assets.first(where: {
               $0.storage == .projectCopy && $0.contentHash == hash && $0.id != id
           }) {
            var asset = old
            asset.storage = .projectCopy
            asset.relativePath = match.relativePath
            asset.bookmarkData = nil
            asset.contentHash = hash
            asset.fileName = url.lastPathComponent
            asset.lastKnownPath = standardizedPath
            asset.metadata = await Self.gatherMetadata(for: url,
                                                       isDirectory: false,
                                                       byteSizeFallback: nil)
            assets[index] = asset
            refreshAvailability(of: id)
            return true
        }

        var asset = old
        asset.kind = AssetKind.inferring(fromExtension: url.pathExtension,
                                         isDirectory: isDirectory)
        asset.fileName = url.lastPathComponent
        asset.lastKnownPath = standardizedPath
        asset.contentHash = hash

        switch targetMode {
        case .copy:
            guard let containerURL = containerURL() else { return false }
            // Replace always owns a FRESH copy path (the old copy may be
            // shared after a dedup adopt — never mutate shared storage).
            let relativePath = "\(Self.copiesFolderName)/\(id.rawValue.uuidString)/\(url.lastPathComponent)"
            let destination = containerURL.appendingPathComponent(relativePath)
            do {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                return false
            }
            asset.storage = .projectCopy
            asset.relativePath = relativePath
            asset.bookmarkData = nil
        case .link:
            guard let bookmark = AssetBookmarkCodec.makeBookmark(for: url) else { return false }
            asset.storage = .linked
            asset.bookmarkData = bookmark
            asset.relativePath = nil
        }

        asset.metadata = await Self.gatherMetadata(for: url,
                                                   isDirectory: isDirectory,
                                                   byteSizeFallback: nil)
        assets[index] = asset
        refreshAvailability(of: id)
        return true
    }

    /// Renames the display name (file identity untouched).
    func rename(_ id: AssetID, to name: String) {
        guard let index = assets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        assets[index].name = trimmed
    }

    /// Removes the registry entry and its usage edges. A PROJECT COPY's bytes
    /// leave the container with it unless another asset shares the same copy
    /// (a replace-time dedup adopt) — shared storage is never deleted out
    /// from under a remaining owner. Linked assets never touch user files.
    func remove(_ id: AssetID) {
        guard let asset = asset(withID: id) else { return }
        if asset.storage == .projectCopy, let relativePath = asset.relativePath,
           !assets.contains(where: { $0.id != id && $0.relativePath == relativePath }),
           let containerURL = containerURL() {
            try? FileManager.default.removeItem(
                at: containerURL.appendingPathComponent(relativePath).deletingLastPathComponent())
        }
        assets.removeAll { $0.id == id }
        availability.removeValue(forKey: id)
        var document = currentDocument()
        for site in document.usageSites(of: id) {
            document.removeUsage(site: site, assetID: id)
        }
        usage = document.usage
    }

    // MARK: - Consumer access seam (G01/G06/G08/E04)

    /// Resolves an asset to a readable URL, holding the security-scope grant
    /// until the returned token deinits. Nil when the asset can't currently
    /// resolve (the panel shows the missing state; consumers treat nil as
    /// "render nothing, stay running" — the no-stall rule).
    func access(for id: AssetID) -> ResolvedAssetAccess? {
        guard let asset = asset(withID: id) else { return nil }
        switch asset.storage {
        case .projectCopy:
            guard let relativePath = asset.relativePath,
                  let containerURL = containerURL() else { return nil }
            let url = containerURL.appendingPathComponent(relativePath)
            return ResolvedAssetAccess(url: url, needsSecurityScope: false)
        case .linked:
            guard let bookmark = asset.bookmarkData,
                  let resolved = AssetBookmarkCodec.resolve(bookmark) else { return nil }
            return ResolvedAssetAccess(url: resolved.url, needsSecurityScope: true)
        }
    }

    // MARK: - Availability probing (never blocks the caller)

    /// Re-probes every asset. Probes run off the main actor on a snapshot of
    /// the inventory; stale generations are dropped, so a volume-event burst
    /// can't apply out-of-order results.
    func refreshAvailability() {
        refreshAvailability(of: Set(assets.map(\.id)))
    }

    func refreshAvailability(of id: AssetID) {
        refreshAvailability(of: [id])
    }

    private func refreshAvailability(of ids: Set<AssetID>) {
        let snapshot = assets.filter { ids.contains($0.id) }
        guard !snapshot.isEmpty else { return }
        probeGeneration += 1
        let generation = probeGeneration
        let containerURL = containerURL()
        Task.detached(priority: .utility) { [weak self] in
            var results: [AssetID: (AssetAvailability, Data?)] = [:]
            for asset in snapshot {
                results[asset.id] = Self.probe(asset, containerURL: containerURL)
            }
            await MainActor.run { [weak self] in
                guard let self, self.probeGeneration == generation else { return }
                for (id, outcome) in results {
                    let (result, refreshedBookmark) = outcome
                    self.availability[id] = result
                    // A stale-but-working bookmark refreshes in place, so the
                    // stored grant never rots under a healthy asset.
                    if let refreshedBookmark,
                       let index = self.assets.firstIndex(where: { $0.id == id }) {
                        self.assets[index].bookmarkData = refreshedBookmark
                    }
                }
            }
        }
    }

    /// Gathers probe inputs for one asset and evaluates them. Off-actor.
    nonisolated private static func probe(
        _ asset: LibraryAsset,
        containerURL: URL?
    ) -> (AssetAvailability, Data?) {
        switch asset.storage {
        case .projectCopy:
            let exists = asset.relativePath.flatMap { relativePath -> Bool? in
                containerURL.map {
                    FileManager.default.fileExists(
                        atPath: $0.appendingPathComponent(relativePath).path)
                }
            } ?? false
            return (AssetAvailabilityEvaluator.evaluate(
                AssetAvailabilityProbe(storage: .projectCopy,
                                       projectCopyExists: exists)), nil)
        case .linked:
            guard let bookmark = asset.bookmarkData else {
                return (AssetAvailabilityEvaluator.evaluate(
                    AssetAvailabilityProbe(storage: .linked, hasBookmark: false)), nil)
            }
            guard let resolved = AssetBookmarkCodec.resolve(bookmark) else {
                return (AssetAvailabilityEvaluator.evaluate(
                    AssetAvailabilityProbe(storage: .linked,
                                           hasBookmark: true,
                                           bookmarkResolved: false)), nil)
            }
            let fileExists = FileManager.default.fileExists(atPath: resolved.url.path)
            let volumeMounted = fileExists || isVolumeMounted(for: resolved.url)
            let accessGranted = fileExists && resolved.url.startAccessingSecurityScopedResource()
            if accessGranted { resolved.url.stopAccessingSecurityScopedResource() }
            let availability = AssetAvailabilityEvaluator.evaluate(
                AssetAvailabilityProbe(storage: .linked,
                                       hasBookmark: true,
                                       bookmarkResolved: true,
                                       bookmarkStale: resolved.isStale,
                                       resolvedFileExists: fileExists,
                                       volumeMounted: volumeMounted,
                                       accessGranted: accessGranted))
            let refreshed = resolved.isStale && fileExists
                ? AssetBookmarkCodec.refreshedBookmark(for: resolved.url)
                : nil
            return (availability, refreshed)
        }
    }

    /// Whether the volume backing `url` is mounted. Compared against the
    /// mounted volume roots; the boot volume always matches, so a missing
    /// file on the boot disk reads as moved/deleted while a missing file on
    /// an unplugged external disk reads as disconnected.
    nonisolated private static func isVolumeMounted(for url: URL) -> Bool {
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: []) ?? []
        let path = url.standardizedFileURL.path
        return mounted.contains { volume in
            let root = volume.standardizedFileURL.path
            return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    // MARK: - Hashing + metadata helpers (off-actor)

    nonisolated private static func hashFile(at url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            return AssetContentHasher.sha256(contentsOf: url)
        }.value
    }

    /// Best-effort metadata: byte size, uniform type, media duration / pixel
    /// dimensions when cheaply readable. Failures degrade to nil fields —
    /// metadata never gates an import.
    nonisolated private static func gatherMetadata(
        for url: URL,
        isDirectory: Bool,
        byteSizeFallback: Int64?
    ) async -> AssetMetadata {
        await Task.detached(priority: .utility) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            var metadata = AssetMetadata()
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
            metadata.byteSize = isDirectory ? nil : values.flatMap { $0.fileSize.map(Int64.init) }
                ?? byteSizeFallback
            metadata.contentType = values?.contentType?.identifier
                ?? UTType(filenameExtension: url.pathExtension)?.identifier
            guard !isDirectory else { return metadata }
            let kind = AssetKind.inferring(fromExtension: url.pathExtension)
            switch kind {
            case .video, .audio:
                let asset = AVURLAsset(url: url)
                if let duration = try? await asset.load(.duration),
                   duration.isNumeric {
                    metadata.durationSeconds = duration.seconds
                }
                if kind == .video,
                   let track = try? await asset.loadTracks(withMediaType: .video).first,
                   let size = try? await track.load(.naturalSize) {
                    metadata.pixelWidth = Int(size.width)
                    metadata.pixelHeight = Int(size.height)
                }
            case .image:
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                        as? [CFString: Any] {
                    metadata.pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int
                    metadata.pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
                }
            default:
                break
            }
            return metadata
        }.value
    }

    // MARK: - Persistence (the SceneStore/SoundboardStore pattern)

    private func containerURL() -> URL? { directory }

    /// Loads the document, quarantining an unreadable/newer file aside (never
    /// crash-loop, never overwrite data that couldn't be read — the S12 rule).
    private static func loadDocument(url: URL) -> AssetLibraryDocument? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let document = try? JSONDecoder().decode(AssetLibraryDocument.self, from: data)
        else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            try? FileManager.default.moveItem(
                at: url,
                to: url.appendingPathExtension("corrupt.\(formatter.string(from: Date())).bak"))
            return nil
        }
        return document
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autosaveDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.writeDocument()
        }
    }

    /// Writes any pending debounced autosave NOW (app termination).
    func flushPendingWrites() {
        autosaveTask?.cancel()
        writeDocument()
    }

    private func writeDocument() {
        let document = AssetLibraryDocument(assets: assets, usage: usage)
        let url = directory.appendingPathComponent(Self.fileName)
        guard let data = try? JSONEncoder().encode(document) else { return }
        try? ProjectDocumentHistory.write(data, to: url)
    }
}

/// P03: a resolved asset URL with its security-scope grant held. Consumers
/// read bytes through `url` and simply drop the token when done — the grant
/// releases on deinit (the `defer`-free equivalent of MediaSourcePlayback's
/// session-held access, scoped to one consumer's read instead).
final class ResolvedAssetAccess: @unchecked Sendable {
    let url: URL
    private let didStartAccess: Bool

    init(url: URL, needsSecurityScope: Bool) {
        self.url = url
        didStartAccess = needsSecurityScope
            ? url.startAccessingSecurityScopedResource()
            : false
    }

    /// True when the sandbox granted access (always true for container
    /// paths; a false here means the grant was revoked — the missing-state
    /// probe reports it as `.accessRevoked`).
    var isAccessible: Bool {
        didStartAccess || FileManager.default.isReadableFile(atPath: url.path)
    }

    deinit {
        if didStartAccess {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
