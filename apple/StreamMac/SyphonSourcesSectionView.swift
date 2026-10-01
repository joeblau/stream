import SwiftUI

/// C09 (issue #163): the Syphon-source registry UI, embedded in the Sources
/// inspector tab alongside the camera and screen sections. Two halves:
///
/// - REGISTERED sources (project-level `SourceDefinition`s with a `.syphon`
///   payload): rows show the live capture status from `CaptureSourcePool`
///   (capturing / idle / missing-or-error, keyed by the source's payload
///   identity — the same key capture demand uses) and offer rename, relink
///   to another discovered server, and remove.
/// - DISCOVERED servers (the pool's live `SyphonServerDirectory` view): each
///   running server that's not yet registered gets an Add button, which
///   registers it as a reusable source; layers then bind it from the layer
///   panel's Add menu.
///
/// Registry edits are IMMEDIATE (S05 semantics), exactly like the screen
/// section. Honest unavailable states: builds without the Syphon package
/// say so plainly, and an empty directory shows guidance instead of a dead
/// list (no servers running is the normal state, not an error).
struct SyphonSourcesSectionView: View {
    @EnvironmentObject private var sceneStore: SceneStore
    @EnvironmentObject private var controller: StreamController

    @State private var renameTarget: SourceDefinition?
    @State private var draftName = ""

    private var discovery: SyphonServerDiscovery {
        controller.capturePool.syphonDiscovery
    }

    private var syphonSources: [SourceDefinition] {
        sceneStore.sources.filter { $0.payload.isSyphon }
    }

    /// Discovered servers no registered source points at yet.
    private var unregisteredServers: [DiscoveredSyphonServer] {
        discovery.servers.filter { server in
            !syphonSources.contains { source in
                guard case .syphon(let payload) = source.payload else { return false }
                return server.matches(payload)
            }
        }
    }

    var body: some View {
        Section {
            if !SyphonServerDiscovery.isSupported {
                Text("This build doesn't include Syphon support, so feeds from local creative apps can't be received.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if syphonSources.isEmpty && discovery.servers.isEmpty {
                    Text("No Syphon servers detected. Launch a Syphon-enabled app (OBS, MadMapper, Resolume, VDMX, …) and its published outputs appear here, ready to add as sources.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(syphonSources) { source in
                    sourceRow(source)
                }
                ForEach(unregisteredServers) { server in
                    discoveredRow(server)
                }
            }
        } header: {
            Text("Syphon Sources")
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
            Image(systemName: "app.connected.to.app.below.fill")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name)
                    .lineLimit(1)
                if case .syphon(let payload) = source.payload {
                    Text(payload.displayTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            statusBadge(for: source)
        }
        .contextMenu {
            Button("Rename…") {
                draftName = source.name
                renameTarget = source
            }
            Menu("Relink to Server") {
                if discovery.servers.isEmpty {
                    Button("No Syphon Servers Running") {}
                        .disabled(true)
                }
                ForEach(discovery.servers) { server in
                    Button(server.displayTitle) {
                        sceneStore.relinkSource(source.id, to: .syphon(server.payload))
                    }
                }
            }
            .help("Point this source at a different Syphon server — every layer using it follows")
            Divider()
            Button("Remove Source", role: .destructive) {
                sceneStore.removeSource(source.id)
            }
        }
    }

    private func discoveredRow(_ server: DiscoveredSyphonServer) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.displayTitle)
                    .lineLimit(1)
                Text("Available — not added yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Add") {
                sceneStore.addSource(
                    SourceDefinition(name: server.displayTitle,
                                     payload: .syphon(server.payload)))
            }
            .buttonStyle(.borderless)
            .help("Register this server as a reusable source")
        }
    }

    // MARK: - Status

    private enum SourceStatus {
        case capturing, idle, error(String)
    }

    /// The pool's live view of this source, keyed by its payload identity —
    /// the same key capture demand uses, so a status here always matches
    /// what the pool is actually doing. The MISSING state (server quit)
    /// arrives through `sourceErrors`, exactly like hot-unplugged devices.
    private func status(for source: SourceDefinition) -> SourceStatus {
        guard case .syphon(let payload) = source.payload else { return .idle }
        let key = CaptureSourceKey.syphon(payload)
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
            Label("Receiving", systemImage: "circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
                .help("Receiving frames")
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

    // MARK: - Rename alert

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })
    }
}
