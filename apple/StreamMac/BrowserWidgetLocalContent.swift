import Foundation
import Darwin

/// A private App Group copy, never a bookmark or URL into the operator's files.
/// An individual HTML pick grants exactly that file. A deliberately selected
/// folder grants that bounded tree; its entry point is index.html.
struct BrowserWidgetLocalPage: Codable, Equatable, Sendable {
    var session: UUID
    var widget: UUID
    var generation: UUID
    var token: UUID
    var entry: String

    func validate(widget: UUID?, generation: UUID?) throws {
        guard self.widget == widget, self.generation == generation,
              !entry.isEmpty, entry.utf8.count <= 255,
              entry != ".", entry != "..", !entry.contains("/"), !entry.contains("\\"),
              !entry.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              ["html", "htm"].contains((entry as NSString).pathExtension.lowercased()) else {
            throw BrowserWidgetLocalContent.Failure.invalid
        }
    }
}

enum BrowserWidgetLocalContent {
    enum Failure: Error { case unavailable, invalid, limit, cancelled }
    static let maximumFiles = 256
    static let maximumBytes = 64 * 1_024 * 1_024
    static let folderName = "BrowserWidgetPages"

    static func container() throws -> URL {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.joeblau.Stream") else {
            throw Failure.unavailable
        }
        return root
    }

    /// Explicit cleanup only: deinitialization cannot delete a still-live page's files.
    final class Snapshot: @unchecked Sendable {
        let page: BrowserWidgetLocalPage
        let root: URL
        private let device: dev_t
        private let inode: ino_t
        init(page: BrowserWidgetLocalPage, root: URL) throws {
            self.page = page; self.root = root
            var value = stat()
            guard lstat(root.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR,
                  value.st_uid == geteuid() else { throw Failure.invalid }
            device = value.st_dev; inode = value.st_ino
        }
        func retire() throws {
            // Never let an old ACK delete a replacement at the same pathname.
            // An incarnation mismatch remains counted/quarantined, not repaired
            // by guessing ownership from a name, a PID or a new manifest.
            var value = stat()
            if lstat(root.path, &value) == 0 {
                guard value.st_mode & S_IFMT == S_IFDIR, value.st_uid == geteuid(),
                      value.st_dev == device, value.st_ino == inode else { throw Failure.invalid }
                try FileManager.default.removeItem(at: root)
            } else if errno != ENOENT { throw Failure.unavailable }
        }
    }

    static func stage(source: URL, container: URL, session: UUID, widget: UUID, generation: UUID) throws -> Snapshot {
        try Task.checkCancellation()
        guard source.isFileURL, source.host == nil || source.host?.lowercased() == "localhost",
              source.user == nil, source.password == nil, source.port == nil else { throw Failure.invalid }
        let input = open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard input >= 0 else { throw Failure.unavailable }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0 else { throw Failure.invalid }
        let directory = info.st_mode & S_IFMT == S_IFDIR
        let entry = directory ? "index.html" : source.lastPathComponent
        let page = BrowserWidgetLocalPage(session: session, widget: widget, generation: generation, token: UUID(), entry: entry)
        try page.validate(widget: widget, generation: generation)
        let parent = container.appendingPathComponent(folderName, isDirectory: true)
        if mkdir(parent.path, 0o700) != 0 && errno != EEXIST { throw Failure.unavailable }
        try checkDirectory(parent)
        // Persistent, cross-process admission: even after a host crash, unknown
        // old leases remain counted. No PID-only heuristic deletes them (PID
        // reuse is not exit proof). Do not silently accumulate across restarts.
        let lockFD = open(parent.appendingPathComponent(".admission.lock").path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw Failure.unavailable }
        defer { close(lockFD) }
        var lockInfo = stat()
        guard fstat(lockFD, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG,
              lockInfo.st_uid == geteuid(), lockInfo.st_nlink == 1, lockInfo.st_mode & 0o077 == 0,
              flock(lockFD, LOCK_EX) == 0 else { throw Failure.invalid }
        defer { _ = flock(lockFD, LOCK_UN) }
        let inventory = try FileManager.default.contentsOfDirectory(atPath: parent.path).filter { $0 != ".admission.lock" }
        guard inventory.count < BrowserWidgetAudioCommand.maximumWidgets * 2 else { throw Failure.limit }
        let root = parent.appendingPathComponent(page.token.uuidString, isDirectory: true)
        guard mkdir(root.path, 0o700) == 0 else { throw Failure.unavailable }
        let snapshot = try Snapshot(page: page, root: root)
        do {
            let content = root.appendingPathComponent("content", isDirectory: true)
            guard mkdir(content.path, 0o700) == 0 else { throw Failure.unavailable }
            let manifest = root.appendingPathComponent("lease.json")
            try JSONEncoder().encode(page).write(to: manifest, options: .withoutOverwriting)
            guard chmod(manifest.path, 0o600) == 0 else { throw Failure.unavailable }
            var files = 0, bytes = 0
            if directory { try copyDirectory(input, to: content, depth: 0, files: &files, bytes: &bytes) }
            else { try copyFile(input, info: info, to: content.appendingPathComponent(entry), files: &files, bytes: &bytes) }
            _ = try resolve(page, container: container, widget: widget, generation: generation)
            try Task.checkCancellation()
            return snapshot
        } catch { try? snapshot.retire(); throw error }
    }

    /// Called by the authenticated helper before creating/loading its WebView.
    /// The returned read root is one lease, not the App Group container.
    static func resolve(_ page: BrowserWidgetLocalPage, container: URL, widget: UUID?, generation: UUID?) throws -> (entry: URL, root: URL) {
        try page.validate(widget: widget, generation: generation)
        let parent = container.appendingPathComponent(folderName, isDirectory: true)
        try checkDirectory(parent)
        let root = parent.appendingPathComponent(page.token.uuidString, isDirectory: true)
        try checkDirectory(root)
        let manifest = root.appendingPathComponent("lease.json")
        let manifestFD = open(manifest.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard manifestFD >= 0 else { throw Failure.invalid }
        defer { close(manifestFD) }
        var manifestInfo = stat()
        guard fstat(manifestFD, &manifestInfo) == 0, manifestInfo.st_mode & S_IFMT == S_IFREG,
              manifestInfo.st_nlink == 1, manifestInfo.st_uid == geteuid(), manifestInfo.st_mode & 0o077 == 0,
              manifestInfo.st_size <= 2048 else { throw Failure.invalid }
        var manifestBytes = [UInt8](repeating: 0, count: 2048)
        let count = read(manifestFD, &manifestBytes, manifestBytes.count)
        guard count > 0, try JSONDecoder().decode(BrowserWidgetLocalPage.self, from: Data(manifestBytes.prefix(count))) == page else { throw Failure.invalid }
        let content = root.appendingPathComponent("content", isDirectory: true)
        try checkDirectory(content)
        let entry = content.appendingPathComponent(page.entry)
        var info = stat()
        guard lstat(entry.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_size > 0,
              info.st_size <= maximumBytes else { throw Failure.invalid }
        return (entry, content)
    }

    static func allowsNavigation(_ url: URL, root: URL?, isMainFrame: Bool = true) -> Bool {
        // File authority is checked in every frame. Preserve existing embedded
        // widget srcdoc/data/blob navigation policy for non-file child frames.
        if url.isFileURL { return allowsFileNavigation(url, root: root) }
        if !isMainFrame { return true }
        if url.absoluteString == "about:blank" { return true }
        return url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
    }

    static func allowsFileNavigation(_ url: URL, root: URL?, singleFile: Bool = false) -> Bool {
        guard url.isFileURL, url.host == nil || url.host?.lowercased() == "localhost",
              url.user == nil, url.password == nil, url.port == nil, let root else { return false }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let allowed = root.resolvingSymlinksInPath().standardizedFileURL.path
        return singleFile ? resolved == allowed : resolved.hasPrefix(allowed + "/")
    }

    private static func checkDirectory(_ url: URL) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR,
              value.st_uid == geteuid(), value.st_mode & 0o077 == 0 else { throw Failure.invalid }
    }
    private static func copyDirectory(_ fd: Int32, to destination: URL, depth: Int, files: inout Int, bytes: inout Int) throws {
        guard depth <= 16, let stream = fdopendir(dup(fd)) else { throw Failure.limit }
        defer { closedir(stream) }
        while let item = readdir(stream) {
            try Task.checkCancellation()
            let name = withUnsafePointer(to: &item.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard !name.contains("\\"), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.invalid }
            let child = openat(fd, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard child >= 0 else { throw Failure.invalid }
            defer { close(child) }
            var info = stat()
            guard fstat(child, &info) == 0 else { throw Failure.invalid }
            let target = destination.appendingPathComponent(name)
            if info.st_mode & S_IFMT == S_IFDIR {
                files += 1
                guard files <= maximumFiles, mkdir(target.path, 0o700) == 0 else { throw Failure.limit }
                try copyDirectory(child, to: target, depth: depth + 1, files: &files, bytes: &bytes)
            } else { try copyFile(child, info: info, to: target, files: &files, bytes: &bytes) }
        }
    }
    private static func copyFile(_ fd: Int32, info: stat, to target: URL, files: inout Int, bytes: inout Int) throws {
        files += 1
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size >= 0,
              files <= maximumFiles, info.st_size <= maximumBytes - bytes else { throw Failure.limit }
        let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw Failure.unavailable }
        defer { close(output) }
        var buffer = [UInt8](repeating: 0, count: 32 * 1_024)
        while true {
            try Task.checkCancellation()
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw Failure.unavailable }
            if count == 0 { break }
            guard count <= maximumBytes - bytes else { throw Failure.limit }
            bytes += count
            try buffer.withUnsafeBytes { raw in
                var sent = 0
                while sent < count {
                    let n = write(output, raw.baseAddress!.advanced(by: sent), count - sent)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw Failure.unavailable }; sent += n
                }
            }
        }
    }
}

/// Unacknowledged pages remain private until the exact owned process exits.
/// terminate() is a request, never a retirement receipt. Failed removals retry.
@MainActor enum BrowserWidgetLocalRetirement {
    private struct Pending {
        var pages: [BrowserWidgetLocalContent.Snapshot]
        var safe: @MainActor () -> Bool
    }
    private static var pending: [UUID: Pending] = [:]
    private static var worker: Task<Void, Never>?
    static var retainedCount: Int { pending.values.reduce(0) { $0 + $1.pages.count } }
    static func retain(_ pages: [BrowserWidgetLocalContent.Snapshot], until safe: @escaping @MainActor () -> Bool) {
        guard !pages.isEmpty else { return }
        pending[UUID()] = Pending(pages: pages, safe: safe)
        retry()
        if worker == nil, !pending.isEmpty {
            worker = Task {
                while !pending.isEmpty {
                    try? await Task.sleep(for: .seconds(1))
                    retry()
                }
                worker = nil
            }
        }
    }
    static func retry() {
        for id in Array(pending.keys) {
            guard let item = pending[id], item.safe() else { continue }
            let remaining = item.pages.filter { page in do { try page.retire(); return false } catch { return true } }
            if remaining.isEmpty { pending[id] = nil }
            else { pending[id]?.pages = remaining }
        }
    }
}
