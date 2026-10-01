import AppKit
import SwiftUI
import StreamCore
import UniformTypeIdentifiers

/// P03 (issue #80): the asset library panel — the inventory UI for every
/// user-picked file/folder the project references. Rows show kind, name,
/// storage mode, metadata (size/duration/dimensions), usage count, and the
/// availability badge; context actions cover reveal, rename, relink (moved
/// file), replace (new content, same identity), and remove.
///
/// Missing assets never fail silently and never block anything: a moved
/// file, a revoked grant, or a disconnected external disk shows as an amber
/// badge with an inline "Relink…" repair — the rest of the library (and the
/// program output) is unaffected.
///
/// **Integration hook (for the app shell — MainWindowView is G03's):**
/// create one `@StateObject AssetLibraryStore()` in `StreamMacApp` next to
/// `dispatcher`, inject it with `.environmentObject(assetLibrary)` on
/// `MainWindowView`, and embed `AssetLibraryPanelView()` as an inspector tab
/// next to `SoundboardPanelView` (same hosting pattern:
/// `.environmentObject(dispatcher.assetLibraryStore)` if the store is parked
/// on the dispatcher instead). No other wiring is required — the panel reads
/// and drives the store directly; asset registry ops are NOT scene edits and
/// deliberately bypass the undo stack and the preview/program staging.
struct AssetLibraryPanelView: View {
    @EnvironmentObject private var store: AssetLibraryStore

    @State private var importMode: AssetImportMode?
    @State private var folderImportPresented = false
    @State private var relinkTarget: LibraryAsset?
    @State private var replaceTarget: LibraryAsset?
    @State private var renameTarget: LibraryAsset?
    @State private var removalTarget: LibraryAsset?
    @State private var draftName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if store.assets.isEmpty {
                Text("No assets yet. Import files as project copies (Stream owns the bytes) or linked references (the original stays where it is).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let missing = store.missingAssets
            if !missing.isEmpty {
                missingSummary(missing)
            }
            ForEach(store.assets) { asset in
                AssetRowView(asset: asset,
                             availability: store.availability(of: asset.id),
                             usageSites: store.usageSites(of: asset.id),
                             onRelink: { relinkTarget = asset },
                             onReplace: { replaceTarget = asset },
                             onRename: {
                                 draftName = asset.name
                                 renameTarget = asset
                             },
                             onReveal: { reveal(asset) },
                             onRemove: { removalTarget = asset })
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // File imports (copy or link — the mode button that opened it).
        .fileImporter(isPresented: fileImportPresented,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            guard let mode = importMode, case .success(let urls) = result else { return }
            Task { await store.importFiles(at: urls, mode: mode) }
            importMode = nil
        }
        // Folder picks are always linked references (a folder copy would
        // snapshot a directory tree the user clearly manages elsewhere).
        .fileImporter(isPresented: $folderImportPresented,
                      allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            Task { await store.importFile(at: url, mode: .link) }
        }
        .fileImporter(isPresented: relinkPresented,
                      allowedContentTypes: relinkTarget.pickTypes) { result in
            guard let relinkTarget, case .success(let url) = result else { return }
            Task { await store.relink(relinkTarget.id, to: url) }
            self.relinkTarget = nil
        }
        .fileImporter(isPresented: replacePresented,
                      allowedContentTypes: replaceTarget.pickTypes) { result in
            guard let replaceTarget, case .success(let url) = result else { return }
            Task { await store.replace(replaceTarget.id, with: url) }
            self.replaceTarget = nil
        }
        .alert("Rename Asset", isPresented: renamePresented) {
            TextField("Name", text: $draftName)
            Button("Rename") {
                if let renameTarget {
                    store.rename(renameTarget.id, to: draftName)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Remove Asset", isPresented: removalPresented) {
            Button("Remove", role: .destructive) {
                if let removalTarget {
                    store.remove(removalTarget.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let removalTarget {
                let sites = store.usageSites(of: removalTarget.id)
                if removalTarget.storage == .projectCopy {
                    Text("\"\(removalTarget.name)\" is used by \(sites.count) site(s) — those will show a missing state. The project's copy of the file is deleted.")
                } else {
                    Text("\"\(removalTarget.name)\" is used by \(sites.count) site(s) — those will show a missing state. The original file is left untouched.")
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Label("Asset Library", systemImage: "shippingbox")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button("Import Copy…") { importMode = .copy }
                Button("Import Link…") { importMode = .link }
                Divider()
                Button("Link Folder…") { folderImportPresented = true }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
            .help("Import files — copy into the project or link to the original")
            Button {
                store.refreshAvailability()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Re-check availability")
        }
    }

    private func missingSummary(_ missing: [LibraryAsset]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("\(missing.count) asset(s) need repair — use Relink on the row below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func reveal(_ asset: LibraryAsset) {
        // The token holds the security-scope grant for the duration of the
        // reveal call; Finder only needs the path.
        guard let access = store.access(for: asset.id), access.isAccessible else { return }
        NSWorkspace.shared.activateFileViewerSelecting([access.url])
    }

    // MARK: - Presentation bindings

    private var fileImportPresented: Binding<Bool> {
        Binding(get: { importMode != nil },
                set: { if !$0 { importMode = nil } })
    }

    private var relinkPresented: Binding<Bool> {
        Binding(get: { relinkTarget != nil },
                set: { if !$0 { relinkTarget = nil } })
    }

    private var replacePresented: Binding<Bool> {
        Binding(get: { replaceTarget != nil },
                set: { if !$0 { replaceTarget = nil } })
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } })
    }

    private var removalPresented: Binding<Bool> {
        Binding(get: { removalTarget != nil },
                set: { if !$0 { removalTarget = nil } })
    }
}

/// One asset row: kind badge, name/file, storage + metadata summary, usage
/// count, and the availability badge with an inline repair affordance.
private struct AssetRowView: View {
    let asset: LibraryAsset
    let availability: AssetAvailability
    let usageSites: [String]
    let onRelink: () -> Void
    let onReplace: () -> Void
    let onRename: () -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: asset.kind.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(asset.name)
                        .font(.callout)
                        .lineLimit(1)
                    Text(asset.fileName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                availabilityBadge
            }
            HStack(spacing: 8) {
                Text(asset.storage.displayName)
                if let size = asset.metadata.byteSize {
                    Text(Self.formatBytes(size))
                }
                if let duration = asset.metadata.durationSeconds {
                    Text(Self.formatDuration(duration))
                }
                if let width = asset.metadata.pixelWidth,
                   let height = asset.metadata.pixelHeight {
                    Text("\(width)×\(height)")
                }
                Spacer()
                Text(usageSites.isEmpty ? "Unused" : "Used by \(usageSites.count)")
                    .foregroundStyle(usageSites.isEmpty ? .tertiary : .secondary)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if case .missing(let reason) = availability {
                HStack(spacing: 6) {
                    Text(repairHint(for: reason))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Relink…", action: onRelink)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Reveal in Finder", action: onReveal)
                .disabled(!availability.isAvailable)
            Button("Rename…", action: onRename)
            Divider()
            Button("Relink…", action: onRelink)
            Button("Replace Content…", action: onReplace)
            Divider()
            Button("Remove from Library", role: .destructive, action: onRemove)
        }
    }

    @ViewBuilder
    private var availabilityBadge: some View {
        switch availability {
        case .unknown:
            ProgressView()
                .controlSize(.small)
                .help("Checking availability…")
        case .available:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("Available")
        case .missing(let reason):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help("Missing: \(reason.displayName)")
        }
    }

    /// The repair guidance per missing reason — honest about what happened
    /// and what Relink will do.
    private func repairHint(for reason: AssetMissingReason) -> String {
        switch reason {
        case .notLinked:
            return "No file is linked. Relink to the original file to grant access."
        case .bookmarkUnresolvable:
            return "The saved link no longer resolves. Relink to the file's current location."
        case .fileMovedOrDeleted:
            return "The file moved or was deleted (last at \(asset.lastKnownPath)). Relink to its new location."
        case .externalVolumeDisconnected:
            return "The file is on a disk that isn't connected (last at \(asset.lastKnownPath)). Reconnect the disk or relink."
        case .accessRevoked:
            return "macOS revoked access to this file. Relink to grant access again."
        case .projectCopyMissing:
            return "The project's copy is missing from the container. Relink to the original file to restore it."
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private extension Optional where Wrapped == LibraryAsset {
    /// The picker's content types for a relink/replace target: folders pick
    /// folders, everything else picks files of any type (the store re-infers
    /// the kind on replace).
    var pickTypes: [UTType] {
        if case .some(let asset) = self, asset.kind == .folder { return [.folder] }
        return [.item]
    }
}
