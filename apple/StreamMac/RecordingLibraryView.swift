import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

private struct RecordingSessionGroup: Identifiable {
    let id: String
    let entries: [RecordingLibraryEntry]
}

/// Attached to the main studio transport; playback and all handoff actions are
/// deliberate local controls, never a second required production window.
struct RecordingLibraryView: View {
    @ObservedObject var recorder: RecordingController
    let addMarker: (String) -> Void
    @StateObject private var model = RecordingLibraryModel()
    @State private var presented = false
    @State private var allProfiles = false
    @State private var selected: URL?
    @State private var player: AVPlayer?
    @State private var markerTitle = ""
    @State private var clipStart = 0.0
    @State private var clipEnd = 0.0
    @State private var accessError: String?

    private var scopedEntries: [RecordingLibraryEntry] {
        model.entries.filter { entry in
            allProfiles || recorder.context.profileID == nil ||
                (entry.context.projectID == recorder.context.projectID && entry.context.profileID == recorder.context.profileID)
        }
    }
    private var groups: [RecordingSessionGroup] {
        Dictionary(grouping: scopedEntries, by: \.sessionID)
            .map { RecordingSessionGroup(id: $0.key, entries: $0.value.sorted { $0.segmentIndex < $1.segmentIndex }) }
            .sorted { ($0.entries.first?.startedAt ?? .distantPast) > ($1.entries.first?.startedAt ?? .distantPast) }
    }
    private var selectedEntry: RecordingLibraryEntry? { scopedEntries.first { $0.url == selected } }

    var body: some View {
        Button("Recording Library", systemImage: "film.stack") { presented.toggle() }
            .labelStyle(.iconOnly)
            .help("Recording library, markers, and clip export")
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                library
                    .task { await reload() }
                    .onDisappear { player?.pause(); player = nil }
            }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recording Library").font(.headline)
                Spacer()
                Toggle("All profiles", isOn: $allProfiles).toggleStyle(.checkbox)
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } }
                    .disabled(model.loading)
            }
            if recorder.state == .recording || recorder.state == .paused {
                HStack {
                    TextField("Chapter marker title", text: $markerTitle)
                        .onSubmit { createMarker() }
                    Button("Add Marker", systemImage: "bookmark") { createMarker() }
                }
            }
            HStack(alignment: .top, spacing: 12) {
                List(selection: $selected) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.entries) { entry in
                                RecordingLibraryRow(entry: entry).tag(entry.url)
                            }
                        } header: {
                            if let first = group.entries.first {
                                Text("\(first.context.projectName ?? "Session") · \(first.startedAt.formatted(date: .abbreviated, time: .shortened))")
                            }
                        }
                    }
                }
                .frame(width: 315, height: 430)
                .overlay {
                    if model.loading { ProgressView() }
                    else if scopedEntries.isEmpty { Text("No recordings in this view.").foregroundStyle(.secondary) }
                }
                .onChange(of: selected) { _, _ in selectRecording() }
                .onChange(of: allProfiles) { _, _ in selected = nil; selectRecording() }
                .onChange(of: recorder.context) { _, _ in selected = nil; selectRecording() }
                if let entry = selectedEntry {
                    ScrollView { detail(entry) }.frame(width: 385, height: 430, alignment: .topLeading)
                } else {
                    Text("Select a recording to inspect its media, markers, and recovery status.")
                        .foregroundStyle(.secondary)
                        .frame(width: 385, height: 430)
                }
            }
            if let error = accessError ?? model.error {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            HStack {
                Text(recorder.folderLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Done") { presented = false }
            }
        }
        .padding(16)
        .frame(width: 740)
    }

    @ViewBuilder private func detail(_ entry: RecordingLibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let player { VideoPlayer(player: player).frame(height: 185) }
            Text(entry.url.lastPathComponent).font(.subheadline.bold()).lineLimit(2)
            Text("\(entry.duration, specifier: "%.2f") seconds · \(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file)) · \(entry.status.capitalized)")
                .font(.caption)
            Text(entry.tracks.isEmpty ? "No readable tracks" : entry.tracks.joined(separator: " · "))
                .font(.caption).textSelection(.enabled)
            if !entry.manifestSummary.isEmpty { Text(entry.manifestSummary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if let error = entry.error { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3).help(error) }
            HStack {
                Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                Button("Open in Editor…") { openInEditor(entry) }.disabled(!entry.canExport)
                RecordingShareButton(url: entry.url).frame(width: 65, height: 22).disabled(!entry.canExport)
            }
            HStack {
                Text("Clip (s)").font(.caption)
                TextField("Start", value: $clipStart, format: .number).frame(width: 65)
                Text("to").font(.caption)
                TextField("End", value: $clipEnd, format: .number).frame(width: 65)
                Button(model.exporting ? "Exporting…" : "Export Clip…") { saveClip(entry) }
                    .disabled(!entry.canExport || model.exporting)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entry.markers) { marker in
                        Button {
                            player?.seek(to: CMTime(seconds: marker.seconds, preferredTimescale: 600))
                        } label: {
                            Text("\(marker.seconds, specifier: "%.3f")  \(marker.title)")
                                .font(.caption).lineLimit(2)
                        }.buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 60)
            Menu("Export Markers") {
                ForEach(RecordingMarkerFormat.allCases, id: \.self) { format in
                    Button(format.title) { saveMarkers(entry, format: format) }
                }
            }.disabled(entry.markers.isEmpty)
        }
    }

    private func createMarker() { addMarker(markerTitle); markerTitle = "" }

    private func selectRecording() {
        player?.pause(); player = nil
        guard let entry = selectedEntry else { return }
        if entry.canExport { player = AVPlayer(url: entry.url) }
        clipStart = 0; clipEnd = entry.duration
    }

    private func reload() async {
        player?.pause(); player = nil
        do {
            accessError = nil
            let access = try recorder.libraryAccess()
            await model.refresh(access: access, activeURLs: recorder.activeOutputURLs)
            selectRecording()
        } catch { accessError = error.localizedDescription }
    }

    private func saveMarkers(_ entry: RecordingLibraryEntry, format: RecordingMarkerFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.url.deletingPathExtension().lastPathComponent + "-markers." + format.rawValue
        panel.allowedContentTypes = [format == .json ? .json : format == .csv ? .commaSeparatedText : .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportMarkers(entry, format: format, to: url)
    }

    private func saveClip(_ entry: RecordingLibraryEntry) {
        let panel = NSSavePanel()
        let audioOnly = !entry.tracks.contains { $0.hasPrefix("Video") }
        panel.nameFieldStringValue = entry.url.deletingPathExtension().lastPathComponent + (audioOnly ? "-clip.m4a" : "-clip.mp4")
        panel.allowedContentTypes = audioOnly ? [.mpeg4Audio] : [.mpeg4Movie, .quickTimeMovie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.exportClip(entry, from: clipStart, to: clipEnd, output: url) }
    }

    private func openInEditor(_ entry: RecordingLibraryEntry) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.prompt = "Open Recording"
        panel.message = "Choose the editor or player to open this recording."
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let app = panel.url else { return }
        NSWorkspace.shared.open([entry.url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}

private struct RecordingLibraryRow: View {
    let entry: RecordingLibraryEntry
    var body: some View {
        HStack(spacing: 8) {
            if let thumbnail = entry.thumbnail { Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit).frame(width: 76, height: 43) }
            else { Image(systemName: entry.tracks.contains(where: { $0.hasPrefix("Video") }) ? "film" : "waveform").frame(width: 76, height: 43) }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.url.lastPathComponent).font(.caption).lineLimit(2)
                Text("\(entry.duration, specifier: "%.1f")s · \(entry.status.capitalized)").font(.caption2)
                    .foregroundStyle(entry.status == "complete" ? Color.secondary : Color.orange)
            }
        }
    }
}

private struct RecordingShareButton: NSViewRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Share…", target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .rounded
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.url = url }
    @MainActor final class Coordinator: NSObject {
        var url: URL
        init(url: URL) { self.url = url }
        @objc func share(_ sender: NSButton) {
            NSSharingServicePicker(items: [url]).show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}
