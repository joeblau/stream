import SwiftUI

/// C02 (issue #77): the screen-source registry UI, embedded in the Sources
/// inspector tab. Every row is a project-level `SourceDefinition` whose
/// payload pins a display, window, or application; rows show the live capture
/// status from `CaptureSourcePool` (capturing / idle / error, keyed by the
/// source's payload identity) and offer rename, retarget (re-pick the pinned
/// content), and remove.
///
/// Registry edits are IMMEDIATE (S05 semantics): `SceneStore.addSource /
/// renameSource / updateSource / removeSource` write the project registry
/// directly rather than staging through preview/program. Retargeting swaps
/// the payload, which re-keys the capture pool — the old capture stops and
/// the new one starts by demand, with no canvas-geometry side effects.
/// Removing a source leaves bound layers rendering their inline payload
/// (they become unbound), so removal never changes what the canvas shows.
struct ScreenSourcesSectionView: View {
    @EnvironmentObject private var sceneStore: SceneStore
    @EnvironmentObject private var controller: StreamController

    /// Picker sheet mode: registering a new source vs. retargeting an
    /// existing one (intentional reselection).
    @State private var pickerMode: PickerMode?
    @State private var renameTarget: SourceDefinition?
    @State private var draftName = ""

    private enum PickerMode: Identifiable {
        case add
        case retarget(SourceDefinition)

        var id: String {
            switch self {
            case .add: return "add"
            case .retarget(let source): return "retarget:\(source.id.rawValue.uuidString)"
            }
        }
    }

    private var screenSources: [SourceDefinition] {
        sceneStore.sources.filter { $0.payload.isScreen }
    }

    var body: some View {
        Section {
            if screenSources.isEmpty {
                Text("No screen sources yet. Add one to capture a specific display, window, or application as a reusable source.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(screenSources) { source in
                sourceRow(source)
            }
            Button {
                pickerMode = .add
            } label: {
                Label("Add Screen Source…", systemImage: "plus")
            }
        } header: {
            Text("Screen Sources")
        }
        .sheet(item: $pickerMode) { mode in
            ScreenSourcePickerView { name, payload in
                switch mode {
                case .add:
                    sceneStore.addSource(SourceDefinition(name: name, payload: .screen(payload)))
                case .retarget(let source):
                    var updated = source
                    updated.payload = .screen(payload)
                    sceneStore.updateSource(updated)
                }
            }
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

    // MARK: - Rows

    private func sourceRow(_ source: SourceDefinition) -> some View {
        HStack(spacing: 6) {
            Image(systemName: targetImage(for: source))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name)
                    .lineLimit(1)
                Text(targetDescription(for: source))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            statusBadge(for: source)
        }
        .contextMenu {
            Button("Rename…") {
                draftName = source.name
                renameTarget = source
            }
            Button("Change Target…") {
                pickerMode = .retarget(source)
            }
            .help("Re-pick the display, window, or application this source captures")
            Divider()
            Button("Remove Source", role: .destructive) {
                sceneStore.removeSource(source.id)
            }
        }
    }

    // MARK: - Status

    private enum SourceStatus {
        case capturing, idle, error(String)
    }

    /// The pool's live view of this source, keyed by its payload identity —
    /// the same key capture demand uses, so a status here always matches what
    /// the pool is actually doing.
    private func status(for source: SourceDefinition) -> SourceStatus {
        guard case .screen(let payload) = source.payload else { return .idle }
        let key = CaptureSourceKey.screen(payload)
        if controller.capturePool.activeSources.contains(key) {
            return .capturing
        }
        if let message = controller.capturePool.sourceErrors[key] {
            return .error(message)
        }
        return .idle
    }

    @ViewBuilder
    private func statusBadge(for source: SourceDefinition) -> some View {
        switch status(for: source) {
        case .capturing:
            Label("Capturing", systemImage: "circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
                .help("Capturing")
        case .idle:
            Label("Idle", systemImage: "circle")
                .labelStyle(.iconOnly)
                .foregroundStyle(.tertiary)
                .help("Idle — capture starts when a visible layer uses this source")
        case .error(let message):
            Label("Error", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.orange)
                .help(message)
        }
    }

    // MARK: - Descriptions

    private func targetImage(for source: SourceDefinition) -> String {
        guard case .screen(let payload) = source.payload else { return "display" }
        switch payload.target {
        case .display: return "display"
        case .window: return "macwindow"
        case .application: return "app.fill"
        }
    }

    private func targetDescription(for source: SourceDefinition) -> String {
        guard case .screen(let payload) = source.payload else { return "" }
        switch payload.target {
        case .display:
            return payload.targetIdentifier == nil
                ? "Display — chosen by the system picker"
                : "Display \(payload.targetIdentifier ?? "")"
        case .window:
            return "Window"
        case .application:
            return "Application"
        }
    }

    // MARK: - Rename alert

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })
    }
}
