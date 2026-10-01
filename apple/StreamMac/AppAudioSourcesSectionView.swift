import AppKit
import SwiftUI

/// A06 (issue #118): the app-audio source registry UI, embedded in the
/// Sources inspector tab. Every row is a project-level `SourceDefinition`
/// whose payload names a running application (by bundle ID) or the
/// whole-system mix; rows show the live capture status from
/// `CaptureSourcePool` (capturing / idle / missing / error, keyed by the
/// source's payload identity) and offer enable/disable, rename, retarget,
/// and remove.
///
/// Unlike screen sources, demand is REGISTRATION-based: an enabled source
/// captures regardless of which scene is staged or program (gated only by
/// the W02 pipeline), so its A04 mixer strip and level survive every scene
/// switch. Levels are mixer-owned (the mixer tab's fader/mute); scene
/// `AudioBinding`s never address app-audio channels.
///
/// Registry edits are IMMEDIATE (the C02/S05 semantics): add/rename/
/// retarget/remove/toggle write `SceneStore` directly; a payload change
/// re-keys the capture pool, so the old capture stops and the new one
/// starts by demand. An app that quits reads MISSING (auto-recovery on
/// relaunch — the C10 pattern with the running-app directory as the
/// hot-plug signal), never a silent substitution.
struct AppAudioSourcesSectionView: View {
    @EnvironmentObject private var sceneStore: SceneStore
    @EnvironmentObject private var controller: StreamController
    @EnvironmentObject private var session: SettingsSession
    @EnvironmentObject private var permissions: PermissionsManager

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

    private var appAudioSources: [SourceDefinition] {
        sceneStore.sources.filter { $0.payload.isAppAudio }
    }

    var body: some View {
        Section {
            if permissions.status(for: .screenCapture) != .granted {
                Label("App audio capture needs Screen Recording permission.",
                      systemImage: "exclamationmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Open Screen Recording Settings…") {
                    permissions.openSystemSettings(for: .screenCapture)
                }
                .font(.caption)
            }
            if appAudioSources.isEmpty {
                Text("No app audio sources yet. Add one to capture an application's sound — or the whole-system mix — independently of any screen scene.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(appAudioSources) { source in
                sourceRow(source)
            }
            if showsDoubleAudioFootnote {
                Text("A screen source that also captures audio can double with app audio. Turn off audio in that screen source's Privacy options, or mute one of the two in the Mixer tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                pickerMode = .add
            } label: {
                Label("Add App Audio Source…", systemImage: "plus")
            }
        } header: {
            Text("App Audio")
        }
        .sheet(item: $pickerMode) { mode in
            AppAudioTargetPickerView(monitor: controller.capturePool.runningApps) { name, payload in
                switch mode {
                case .add:
                    sceneStore.addSource(SourceDefinition(name: name, payload: .appAudio(payload)))
                case .retarget(let source):
                    var updated = source
                    updated.payload = .appAudio(payload)
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
            targetIcon(for: source)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name)
                    .lineLimit(1)
                Text(targetDescription(for: source))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            doubleAudioIndicator(for: source)
            statusBadge(for: source)
            enableToggle(for: source)
        }
        .contextMenu {
            Button("Rename…") {
                draftName = source.name
                renameTarget = source
            }
            Button("Change Target…") {
                pickerMode = .retarget(source)
            }
            .help("Re-pick the application, or switch to the system mix")
            Divider()
            Button("Remove Source", role: .destructive) {
                sceneStore.removeSource(source.id)
            }
        }
    }

    /// The enable/disable switch: writes the payload back through
    /// `updateSource`, which re-keys the capture pool — disabling drops the
    /// source out of demand (capture stops), enabling restarts it.
    private func enableToggle(for source: SourceDefinition) -> some View {
        Toggle(isOn: Binding(
            get: {
                guard case .appAudio(let payload) = source.payload else { return false }
                return payload.isEnabled
            },
            set: { enabled in
                guard case .appAudio(var payload) = source.payload else { return }
                payload.isEnabled = enabled
                var updated = source
                updated.payload = .appAudio(payload)
                sceneStore.updateSource(updated)
            })
        ) {
            EmptyView()
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .labelsHidden()
        .help("Enabled app-audio sources capture independently of any scene")
    }

    // MARK: - Status

    private enum SourceStatus {
        case capturing, idle, disabled, missing(String), error(String)
    }

    /// The pool's live view of this source, keyed by its payload identity —
    /// the same key capture demand uses, so a status here always matches what
    /// the pool is actually doing.
    private func status(for source: SourceDefinition) -> SourceStatus {
        guard case .appAudio(let payload) = source.payload else { return .idle }
        guard payload.isEnabled else { return .disabled }
        let key = CaptureSourceKey.appAudio(payload)
        if controller.capturePool.activeSources.contains(key) {
            return .capturing
        }
        if let message = controller.capturePool.sourceErrors[key] {
            return controller.capturePool.missingSources.contains(key)
                ? .missing(message) : .error(message)
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
                .help("Capturing — mixed on its own channel in the Mixer tab")
        case .idle:
            Label("Idle", systemImage: "circle")
                .labelStyle(.iconOnly)
                .foregroundStyle(.tertiary)
                .help("Idle — capture starts with the stream/preview/recording pipeline")
        case .disabled:
            Label("Disabled", systemImage: "circle.slash")
                .labelStyle(.iconOnly)
                .foregroundStyle(.tertiary)
                .help("Disabled — enable the source to capture")
        case .missing(let message):
            Label("Missing", systemImage: "questionmark.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.yellow)
                .help(message)
        case .error(let message):
            Label("Error", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.orange)
                .help(message)
        }
    }

    // MARK: - Double-audio honesty

    /// Screen sources capture an app's audio too when their privacy options
    /// allow it. A per-app source whose target matches an app-targeted screen
    /// source with audio ON would double that app's sound in the mix — badge
    /// it, never let it pass silently. (The system mix already excludes apps
    /// that carry their own per-app source, so no indicator is needed there.)
    @ViewBuilder
    private func doubleAudioIndicator(for source: SourceDefinition) -> some View {
        if let culprit = doubleAudioScreenSource(for: source) {
            Label("Also captured by screen source \"\(culprit)\"", systemImage: "speaker.triangle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.purple)
                .help("Screen source \"\(culprit)\" captures this app's audio too — the mix doubles it. Turn off audio in that source's Privacy options, or mute one of the two in the Mixer tab.")
        }
    }

    private func doubleAudioScreenSource(for source: SourceDefinition) -> String? {
        guard case .appAudio(let payload) = source.payload,
              payload.mode == .application, payload.isEnabled,
              let bundleID = payload.bundleID else { return nil }
        for candidate in sceneStore.sources {
            guard case .screen(let screen) = candidate.payload,
                  screen.target == .application,
                  screen.targetIdentifier == bundleID || screen.applicationBundleID == bundleID,
                  screen.effectivePrivacy(defaults: session.activeSettings).capturesAudio
            else { continue }
            return candidate.name
        }
        return nil
    }

    /// True when any enabled app-audio source coexists with a screen source
    /// capturing audio — the general double-audio guidance footnote.
    private var showsDoubleAudioFootnote: Bool {
        let hasEnabledAppAudio = appAudioSources.contains { source in
            guard case .appAudio(let payload) = source.payload else { return false }
            return payload.isEnabled
        }
        guard hasEnabledAppAudio else { return false }
        return sceneStore.sources.contains { source in
            guard case .screen(let screen) = source.payload else { return false }
            return screen.effectivePrivacy(defaults: session.activeSettings).capturesAudio
        }
    }

    // MARK: - Descriptions

    @ViewBuilder
    private func targetIcon(for source: SourceDefinition) -> some View {
        if case .appAudio(let payload) = source.payload,
           payload.mode == .application,
           let bundleID = payload.bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
        } else {
            Image(systemName: payloadSystemImage(for: source))
                .foregroundStyle(.secondary)
        }
    }

    private func payloadSystemImage(for source: SourceDefinition) -> String {
        guard case .appAudio(let payload) = source.payload else { return "speaker.wave.2.fill" }
        switch payload.mode {
        case .application: return "app.badge"
        case .system: return "speaker.wave.2.fill"
        }
    }

    private func targetDescription(for source: SourceDefinition) -> String {
        guard case .appAudio(let payload) = source.payload else { return "" }
        switch payload.mode {
        case .application:
            return "Application — \(payload.bundleID ?? "not configured")"
        case .system:
            return "System mix — every app except StreamMac"
        }
    }

    // MARK: - Rename alert

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })
    }
}

/// A06: the app-audio target picker — "System Audio" (the whole-system mix)
/// plus every running regular UI application, read live from the pool's
/// `RunningApplicationMonitor`. Picking returns a source name and a fully
/// formed payload; registration/retarget writes ride the section view.
private struct AppAudioTargetPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var monitor: RunningApplicationMonitor
    let onPick: (String, AppAudioSourcePayload) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add App Audio Source")
                .font(.headline)
                .padding([.top, .horizontal])
            List {
                Button {
                    pick(name: "System Audio",
                         payload: AppAudioSourcePayload(mode: .system))
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("System Audio")
                            Text("Every app except StreamMac — apps with their own source are excluded automatically")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "speaker.wave.2.fill")
                    }
                }
                .buttonStyle(.plain)
                Section("Running Applications") {
                    ForEach(monitor.audioApps) { app in
                        Button {
                            pick(name: app.name,
                                 payload: AppAudioSourcePayload(mode: .application,
                                                                bundleID: app.bundleID,
                                                                appName: app.name))
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(app.name)
                                    Text(app.bundleID)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                appIcon(for: app.bundleID)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 420, height: 460)
    }

    @ViewBuilder
    private func appIcon(for bundleID: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "app.badge")
        }
    }

    private func pick(name: String, payload: AppAudioSourcePayload) {
        onPick(name, payload)
        dismiss()
    }
}
