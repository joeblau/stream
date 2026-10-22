import Foundation
import Darwin

@main struct BrowserLocalContentHarness {
    static func rejected(_ body: () throws -> Void) { do { try body(); preconditionFailure("Accepted invalid local authority") } catch {} }
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("stream-local-content-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true), group = root.appendingPathComponent("group", isDirectory: true)
        for p in [source, group] { try fm.createDirectory(at: p, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        let html = Data("<link rel='stylesheet' href='nested/widget.css'><audio src='tone.wav'></audio>".utf8)
        try html.write(to: source.appendingPathComponent("index.html"))
        try fm.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: false)
        let css = Data("body{background:lime}".utf8)
        try css.write(to: source.appendingPathComponent("nested/widget.css"))
        let wave = Data([0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4])
        try wave.write(to: source.appendingPathComponent("tone.wav"))
        let widget = UUID(), generation = UUID(), session = UUID()
        let file = try BrowserWidgetLocalContent.stage(source: source.appendingPathComponent("index.html"), container: group, session: session, widget: widget, generation: generation)
        let fileAccess = try BrowserWidgetLocalContent.resolve(file.page, container: group, widget: widget, generation: generation)
        let copiedHTML = try Data(contentsOf: fileAccess.entry)
        precondition(copiedHTML == html)
        precondition(!fm.fileExists(atPath: fileAccess.root.appendingPathComponent("tone.wav").path), "File pick inferred sibling authority")
        try file.retire()
        let folder = try BrowserWidgetLocalContent.stage(source: source, container: group, session: session, widget: widget, generation: generation)
        let access = try BrowserWidgetLocalContent.resolve(folder.page, container: group, widget: widget, generation: generation)
        let copiedCSS = try Data(contentsOf: access.root.appendingPathComponent("nested/widget.css"))
        precondition(copiedCSS == css)
        let copiedWave = try Data(contentsOf: access.root.appendingPathComponent("tone.wav"))
        precondition(copiedWave == wave)
        try BrowserWidgetAudioCommand(action: .load, widgetID: widget, generation: generation, localPage: folder.page).validate()
        rejected { try BrowserWidgetAudioCommand(action: .resume, widgetID: widget, generation: generation, localPage: folder.page).validate() }
        rejected { _ = try BrowserWidgetLocalContent.resolve(folder.page, container: group, widget: UUID(), generation: generation) }
        rejected { _ = try BrowserWidgetLocalContent.resolve(folder.page, container: group, widget: widget, generation: UUID()) }
        var forged = folder.page; forged.session = UUID()
        rejected { _ = try BrowserWidgetLocalContent.resolve(forged, container: group, widget: widget, generation: generation) }
        forged = folder.page; forged.entry = "../index.html"
        rejected { _ = try BrowserWidgetLocalContent.resolve(forged, container: group, widget: widget, generation: generation) }
        precondition(BrowserWidgetLocalContent.allowsNavigation(access.entry, root: access.root))
        precondition(!BrowserWidgetLocalContent.allowsNavigation(source.appendingPathComponent("index.html"), root: access.root))
        precondition(!BrowserWidgetLocalContent.allowsNavigation(access.root.appendingPathComponent("../lease.json"), root: access.root))
        precondition(!BrowserWidgetLocalContent.allowsNavigation(access.entry, root: nil))
        for raw in ["about:srcdoc", "data:text/html,owned", "blob:https://example.invalid/owned"] {
            let url = URL(string: raw)!
            precondition(BrowserWidgetLocalContent.allowsNavigation(url, root: nil, isMainFrame: false), "Changed existing non-file child-frame policy")
            precondition(!BrowserWidgetLocalContent.allowsNavigation(url, root: nil, isMainFrame: true))
        }
        precondition(!BrowserWidgetLocalContent.allowsNavigation(source.appendingPathComponent("index.html"), root: access.root, isMainFrame: false))
        var foreign = URLComponents(url: access.entry, resolvingAgainstBaseURL: false)!
        foreign.host = "foreign.invalid"
        precondition(!BrowserWidgetLocalContent.allowsFileNavigation(foreign.url!, root: access.root))
        precondition(!BrowserWidgetLocalContent.allowsFileNavigation(foreign.url!, root: access.entry, singleFile: true))
        try fm.createSymbolicLink(at: source.appendingPathComponent("escape"), withDestinationURL: root)
        rejected { _ = try BrowserWidgetLocalContent.stage(source: source, container: group, session: session, widget: widget, generation: generation) }
        try fm.removeItem(at: source.appendingPathComponent("escape"))
        precondition(link(source.appendingPathComponent("index.html").path, source.appendingPathComponent("hardlink").path) == 0)
        rejected { _ = try BrowserWidgetLocalContent.stage(source: source, container: group, session: session, widget: widget, generation: generation) }
        try fm.removeItem(at: source.appendingPathComponent("hardlink"))
        precondition(mkfifo(source.appendingPathComponent("fifo").path, 0o600) == 0)
        rejected { _ = try BrowserWidgetLocalContent.stage(source: source, container: group, session: session, widget: widget, generation: generation) }
        try fm.removeItem(at: source.appendingPathComponent("fifo"))
        let large = source.appendingPathComponent("large")
        precondition(truncateOrCreate(large.path, count: off_t(BrowserWidgetLocalContent.maximumBytes + 1)))
        rejected { _ = try BrowserWidgetLocalContent.stage(source: source, container: group, session: session, widget: widget, generation: generation) }
        try fm.removeItem(at: large)
        for n in 0...BrowserWidgetLocalContent.maximumFiles { fm.createFile(atPath: source.appendingPathComponent("file\(n)").path, contents: Data()) }
        rejected { _ = try BrowserWidgetLocalContent.stage(source: source, container: group, session: session, widget: widget, generation: generation) }
        // Rejected copies removed only their own fresh directory.
        let remaining = try fm.contentsOfDirectory(at: group.appendingPathComponent(BrowserWidgetLocalContent.folderName), includingPropertiesForKeys: nil)
        let remainingPaths = Set(remaining.filter { $0.lastPathComponent != ".admission.lock" }.map { $0.resolvingSymlinksInPath().path })
        precondition(remainingPaths == [folder.root.resolvingSymlinksInPath().path], "Remaining lease paths: \(remainingPaths); expected \(folder.root.resolvingSymlinksInPath().path)")
        try folder.retire()
        rejected { _ = try BrowserWidgetLocalContent.resolve(folder.page, container: group, widget: widget, generation: generation) }
        let deep = root.appendingPathComponent("deep", isDirectory: true)
        try fm.createDirectory(at: deep, withIntermediateDirectories: false)
        try html.write(to: deep.appendingPathComponent("index.html"))
        var child = deep
        for _ in 0...16 {
            child = child.appendingPathComponent("nested", isDirectory: true)
            try fm.createDirectory(at: child, withIntermediateDirectories: false)
        }
        rejected { _ = try BrowserWidgetLocalContent.stage(source: deep, container: group, session: session, widget: widget, generation: generation) }
        // Persistent inventory, not in-memory session counters, bounds leases
        // left by a previous host; unrelated entries are never deleted.
        var snapshots: [BrowserWidgetLocalContent.Snapshot] = []
        for _ in 0..<(BrowserWidgetAudioCommand.maximumWidgets * 2) {
            snapshots.append(try BrowserWidgetLocalContent.stage(source: source.appendingPathComponent("index.html"),
                container: group, session: UUID(), widget: UUID(), generation: UUID()))
        }
        rejected { _ = try BrowserWidgetLocalContent.stage(source: source.appendingPathComponent("index.html"),
            container: group, session: UUID(), widget: UUID(), generation: UUID()) }
        for page in snapshots { try page.retire() }
        // Cleanup failure preserves ownership and retries without deleting siblings.
        let retry = try BrowserWidgetLocalContent.stage(source: source.appendingPathComponent("index.html"),
            container: group, session: session, widget: widget, generation: generation)
        let parent = retry.root.deletingLastPathComponent()
        guard chmod(parent.path, 0o500) == 0 else { preconditionFailure("chmod fixture parent") }
        BrowserWidgetLocalRetirement.retain([retry], until: { true })
        precondition(BrowserWidgetLocalRetirement.retainedCount == 1)
        guard chmod(parent.path, 0o700) == 0 else { preconditionFailure("restore fixture parent") }
        BrowserWidgetLocalRetirement.retry()
        precondition(BrowserWidgetLocalRetirement.retainedCount == 0 && !fm.fileExists(atPath: retry.root.path))
        let stale = try BrowserWidgetLocalContent.stage(source: source.appendingPathComponent("index.html"),
            container: group, session: session, widget: widget, generation: generation)
        let moved = stale.root.deletingLastPathComponent().appendingPathComponent("retained-" + UUID().uuidString)
        try fm.moveItem(at: stale.root, to: moved)
        try fm.createDirectory(at: stale.root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let sentinel = stale.root.appendingPathComponent("replacement")
        try Data("must survive old retirement".utf8).write(to: sentinel)
        rejected { try stale.retire() }
        precondition(fm.fileExists(atPath: sentinel.path) && fm.fileExists(atPath: moved.path), "Old retirement deleted another incarnation")
        // Only this fixture owns both known trees; production never reaps them.
        try fm.removeItem(at: stale.root); try fm.removeItem(at: moved)
        let cancelled = Task.detached { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try BrowserWidgetLocalContent.stage(source: source.appendingPathComponent("index.html"),
                container: group, session: session, widget: widget, generation: generation)
        }
        do { try await cancelled.value; preconditionFailure("Cancelled staging succeeded") } catch is CancellationError {} catch { throw error }
        print("PASS: persisted cross-session admission bound, exact cleanup failure/retry, replaced-directory incarnation and cancelled staging; no PID-reuse orphan deletion")
        print("PASS: exact-file scope, explicit folder relative CSS/media bytes, bounded no-follow copy, hardlink/FIFO/oversize/count rejection, typed lease/manifest identity, traversal/foreign-file navigation and exact retirement; no WebKit/helper/UI/capture/output")
    }
    static func truncateOrCreate(_ path: String, count: off_t) -> Bool {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600); guard fd >= 0 else { return false }; defer { close(fd) }
        return ftruncate(fd, count) == 0
    }
}
