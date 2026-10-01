import SwiftUI
import PDFKit
import StreamCore
import UniformTypeIdentifiers

/// G06 (issue #113): the PDF/slide-deck source registry + page-navigation
/// UI. Rows for every registered `.pdf` source show the document's page
/// count and a low-res thumbnail strip, and carry the navigation the issue
/// requires: previous/next page, a jump slider with "Page X of N", thumbnail
/// taps, and the fit/fill framing picker.
///
/// Every navigation action routes through the W05 dispatcher (program-aware
/// session state, never undoable — the A02 media-transport precedent): page
/// state lives in the dispatcher's `PDFDeckStore` per SOURCE, so the preview
/// and program engines paint the same page on their next tick and navigation
/// can never fork between canvases. Page controls stay out of the output:
/// only the engine's rasterized page pixels composite.
///
/// Documents import through the P03 asset library as PROJECT COPIES (the
/// packaging criterion — the project owns the bytes) and register usage
/// under the `pdfSource/<sourceID>` site key; relink replaces the asset's
/// content in place, keeping the source identity.
///
/// **Integration hook (MainWindowView is G01's — not edited here):** embed
/// `PDFSourceSectionView()` next to `MediaSourcesSectionView()` in the
/// sources column (a one-line change; the view is a plain VStack so it can
/// also drop into an inspector `Form`). It reads `SceneStore`,
/// `CaptureSourcePool`, and `StudioCommandDispatcher` from the environment —
/// the dispatcher owns `pdfDecks` and `assetLibrary`, so no extra injection.
struct PDFSourceSectionView: View {
    @EnvironmentObject private var sceneStore: SceneStore
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher

    @State private var addPickerPresented = false
    @State private var renameTarget: SourceDefinition?
    @State private var draftName = ""
    @State private var relinkTarget: SourceDefinition?

    private var pdfSources: [SourceDefinition] {
        // `LayerPayload.isPDF` is G01's hook (LayerGraph.swift); match the
        // case directly here so this file doesn't depend on that edit.
        sceneStore.sources.filter {
            if case .pdf = $0.payload { return true }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("Presentations", systemImage: "rectangle.on.rectangle.angled")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    addPickerPresented = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Import a PDF document or slide deck as a presentation source")
            }
            if pdfSources.isEmpty {
                Text("No presentations. Import a PDF, then bind it to a layer from the Add Layer menu.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ForEach(pdfSources) { source in
                PDFSourceRowView(source: source,
                                 onRename: {
                                     draftName = source.name
                                     renameTarget = source
                                 },
                                 onRelink: { relinkTarget = source },
                                 onRemove: { remove(source) })
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .fileImporter(isPresented: $addPickerPresented,
                      allowedContentTypes: [.pdf]) { result in
            guard case .success(let url) = result else { return }
            Task { await addSource(forPickedFile: url) }
        }
        .fileImporter(isPresented: relinkPresented,
                      allowedContentTypes: [.pdf]) { result in
            guard let relinkTarget, case .success(let url) = result,
                  case .pdf(let payload) = relinkTarget.payload,
                  let identifier = payload.assetIdentifier,
                  let assetID = UUID(uuidString: identifier) else { return }
            // Relink keeps the source (and its deck state) and replaces the
            // asset's CONTENT in place — page count/framing re-clamp when the
            // new document loads (`PDFDeckStore.notePageCount`).
            Task { await dispatcher.assetLibrary.replace(AssetID(assetID),
                                                         with: url,
                                                         mode: .copy) }
            self.relinkTarget = nil
        }
        .alert("Rename Source", isPresented: renamePresented) {
            TextField("Name", text: $draftName)
            Button("Rename") {
                if let renameTarget {
                    let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        sceneStore.renameSource(renameTarget.id, to: trimmed)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Import gate (the G09 pattern): probe BEFORE registering, so an
    /// unreadable/locked/empty document is an explicit rejection at the pick,
    /// never a source that errors on program.
    private func addSource(forPickedFile url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard case .success = PDFSourceClassifier.probe(url: url) else { return }
        // Project copy: packaging the project retains the document bytes.
        guard let asset = await dispatcher.assetLibrary.importFile(at: url, mode: .copy)
        else { return }
        let source = sceneStore.addSource(SourceDefinition(
            name: url.deletingPathExtension().lastPathComponent,
            payload: .pdf(PDFSourcePayload(assetIdentifier: asset.id.rawValue.uuidString,
                                           page: 0))))
        dispatcher.assetLibrary.noteUsage(of: asset.id,
                                          from: Self.usageSite(for: source.id))
    }

    private func remove(_ source: SourceDefinition) {
        dispatcher.assetLibrary.clearUsage(site: Self.usageSite(for: source.id))
        dispatcher.pdfDecks.removeDeck(for: source.id)
        sceneStore.removeSource(source.id)
    }

    /// The P03 usage site key for a registry source (the panel's "Used by"
    /// list and in-use removal warning read these).
    static func usageSite(for id: SourceDefinitionID) -> String {
        "pdfSource/\(id.rawValue.uuidString)"
    }

    private var relinkPresented: Binding<Bool> {
        Binding(
            get: { relinkTarget != nil },
            set: { if !$0 { relinkTarget = nil } })
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })
    }
}

/// One PDF source row: status badge, page navigation (prev/next, jump
/// slider, "Page X of N"), the thumbnail strip, and the framing picker.
private struct PDFSourceRowView: View {
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher

    let source: SourceDefinition
    let onRename: () -> Void
    let onRelink: () -> Void
    let onRemove: () -> Void

    @StateObject private var thumbnails = PDFThumbnailModel()

    private var payload: PDFSourcePayload? {
        guard case .pdf(let payload) = source.payload else { return nil }
        return payload
    }

    private var deckState: DeckPageState {
        dispatcher.pdfDecks.state(for: source.id, fallbackPage: payload?.page ?? 0)
    }

    /// The page count the UI trusts: the engine's report once loaded, else
    /// the thumbnail model's probe (so "Page X of N" shows before the pool
    /// has demanded the source).
    private var pageCount: Int {
        dispatcher.pdfDecks.pageCount(for: source.id) ?? thumbnails.pageCount
    }

    private var currentPage: Int {
        deckState.clampedPage(pageCount: pageCount > 0 ? pageCount : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                statusBadge
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.name)
                        .font(.callout)
                        .lineLimit(1)
                    Text(fileSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                navigationButtons
            }
            if pageCount > 1 {
                HStack(spacing: 8) {
                    Slider(value: pageBinding, in: 1...Double(pageCount), step: 1)
                    Text("Page \(currentPage + 1) of \(pageCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                thumbnailStrip
            }
            Picker("Framing", selection: framingBinding) {
                ForEach(DeckFraming.allCases, id: \.self) { framing in
                    Text(framing.displayName).tag(framing)
                }
            }
            .pickerStyle(.segmented)
            .font(.caption)
        }
        .contextMenu {
            Button("Rename…", action: onRename)
            Button("Replace Document…", action: onRelink)
            Divider()
            Button("Remove Source", role: .destructive, action: onRemove)
        }
        .task(id: payload?.assetIdentifier) {
            if let identifier = payload?.assetIdentifier {
                await thumbnails.load(assetIdentifier: identifier,
                                      assetLibrary: dispatcher.assetLibrary)
                if thumbnails.pageCount > 0 {
                    dispatcher.pdfDecks.notePageCount(thumbnails.pageCount, for: source.id)
                }
            }
        }
    }

    // MARK: - Navigation

    @ViewBuilder
    private var navigationButtons: some View {
        Button {
            dispatcher.execute(.pdfPreviousPage(source.id))
        } label: {
            Image(systemName: "chevron.left")
        }
        .buttonStyle(.borderless)
        .disabled(!dispatcher.canExecute(.pdfPreviousPage(source.id)) || currentPage <= 0)
        .help("Previous page")
        Button {
            dispatcher.execute(.pdfNextPage(source.id))
        } label: {
            Image(systemName: "chevron.right")
        }
        .buttonStyle(.borderless)
        .disabled(!dispatcher.canExecute(.pdfNextPage(source.id))
                  || (pageCount > 0 && currentPage >= pageCount - 1))
        .help("Next page")
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let identifier = payload?.assetIdentifier,
           let uuid = UUID(uuidString: identifier),
           dispatcher.assetLibrary.availability(of: AssetID(uuid)).missingReason != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help("The document is unavailable — replace or relink it from the asset library.")
        } else if pageCount > 0 {
            Image(systemName: "doc.fill")
                .foregroundStyle(.secondary)
                .help("\(pageCount) pages")
        } else {
            Image(systemName: "doc")
                .foregroundStyle(.tertiary)
                .help("Document not loaded yet")
        }
    }

    private var fileSummary: String {
        if let identifier = payload?.assetIdentifier,
           let uuid = UUID(uuidString: identifier),
           let asset = dispatcher.assetLibrary.asset(withID: AssetID(uuid)) {
            return asset.fileName
        }
        return "No document linked"
    }

    // MARK: - Thumbnails

    /// Low-res per-page thumbnails (PDFKit at 120 pt wide). Tapping a
    /// thumbnail jumps to that page through the dispatcher — the same
    /// program-aware command the buttons and keyboard fire.
    @ViewBuilder
    private var thumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: [GridItem(.fixed(72))], spacing: 6) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Button {
                        dispatcher.execute(.pdfGoToPage(source.id, page: index))
                    } label: {
                        thumbnailCell(index)
                    }
                    .buttonStyle(.plain)
                    .help("Go to page \(index + 1)")
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: 80)
    }

    @ViewBuilder
    private func thumbnailCell(_ index: Int) -> some View {
        ZStack {
            if let image = thumbnails.thumbnails[index] {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Text("\(index + 1)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: 56, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(index == currentPage ? Color.accentColor : Color.clear,
                        lineWidth: 2)
        }
    }

    // MARK: - Bindings

    /// The jump slider is 1-based for display; the command takes 0-based.
    private var pageBinding: Binding<Double> {
        Binding(
            get: { Double(currentPage + 1) },
            set: { dispatcher.execute(.pdfGoToPage(source.id, page: Int($0) - 1)) })
    }

    private var framingBinding: Binding<DeckFraming> {
        Binding(
            get: { deckState.framing },
            set: { dispatcher.execute(.pdfSetFraming(source.id, framing: $0)) })
    }
}

/// Loads a source's document and renders its low-res page thumbnails.
/// Rendering runs off the main actor (PDFKit's CG-level thumbnail API); the
/// published images land back on main. The P03 access grant is held for the
/// render's duration.
@MainActor
private final class PDFThumbnailModel: ObservableObject {
    @Published private(set) var thumbnails: [Int: NSImage] = [:]
    @Published private(set) var pageCount = 0

    private var loadTask: Task<(Int, [Int: NSImage]), Never>?
    private var generation = 0

    func load(assetIdentifier: String, assetLibrary: AssetLibraryStore) async {
        loadTask?.cancel()
        generation += 1
        let generation = generation
        guard let uuid = UUID(uuidString: assetIdentifier),
              let access = assetLibrary.access(for: AssetID(uuid)),
              access.isAccessible else {
            thumbnails = [:]
            pageCount = 0
            return
        }
        let url = access.url
        // PDFKitPlatformImage is NSImage on macOS — the thumbnail API returns
        // immutable platform images, safe to hand across the actor hop.
        let task = Task.detached(priority: .utility) {
                () -> (Int, [Int: NSImage]) in
            guard let document = PDFDocument(url: url) else { return (0, [:]) }
            var images: [Int: NSImage] = [:]
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                let image = page.thumbnail(of: CGSize(width: 120, height: 160),
                                           for: .mediaBox)
                images[index] = image
            }
            return (document.pageCount, images)
        }
        loadTask = task
        let (count, images) = await task.value
        // A superseding load owns the publication now.
        guard generation == self.generation else { return }
        pageCount = count
        thumbnails = images
        // The grant releases with the token once rendering is done.
        _ = access
    }
}
