import AppKit
import ScreenCaptureKit
import SwiftUI

/// C03 (issue #78): running-app metadata for the privacy editors. Reading
/// `NSWorkspace.runningApplications` needs no Screen Recording permission,
/// so the exclusion pickers work even before capture is granted.
enum RunningAppList {
    /// Regular (dock-visible) running apps, minus this app and the already
    /// excluded bundle IDs, sorted by name.
    @MainActor
    static func candidates(excluding excluded: Set<String>) -> [(bundleID: String, name: String)] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier,
                  !excluded.contains(bundleID) else { return nil }
            return (bundleID, app.localizedName ?? bundleID)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The running app's display name, or the raw bundle ID when the app
    /// isn't running right now (the exclusion still applies when it is).
    @MainActor
    static func name(for bundleID: String) -> String {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleID }?.localizedName ?? bundleID
    }
}

/// C03 (issue #78): the per-source capture-privacy editor, presented as a
/// sheet from the Sources tab. Edits a DRAFT of the source's
/// `CapturePrivacyOptions`; Apply writes the payload back through
/// `SceneStore.updateSource`, which re-keys the capture pool — the old
/// capture stops and the new one starts with the resolved filter, so
/// exclusions always apply deliberately, never mid-frame.
///
/// The cursor/audio pickers are tri-state: Default (inherit the global
/// settings value), or an explicit per-source override. Exclusions are
/// additive on top of the global default exclusion list — a source can hide
/// MORE than the defaults, never less.
///
/// Over-exclusion fails CLOSED: when the edited options exclude the source's
/// own target, the editor says so and the capture reports an error (black +
/// warning) instead of re-pointing at other content — the C02 "no silent
/// fallback" contract holds.
struct ScreenSourcePrivacyView: View {
    let source: SourceDefinition
    /// The screen payload being edited (callers open this sheet only for
    /// screen sources).
    let payload: ScreenSourcePayload

    @EnvironmentObject private var sceneStore: SceneStore
    @EnvironmentObject private var session: SettingsSession
    @Environment(\.dismiss) private var dismiss

    @State private var draft: CapturePrivacyOptions
    /// Live window list for the add-window menu; nil until loaded (and stays
    /// nil without the Screen Recording permission — the menu then explains
    /// why it is empty).
    @State private var windowSnapshot: ShareableContentSnapshot?

    init(source: SourceDefinition, payload: ScreenSourcePayload) {
        self.source = source
        self.payload = payload
        _draft = State(initialValue: payload.privacy)
    }

    /// Cursor/audio tri-state: nil (inherit) or an explicit override.
    private enum TriState: String, Hashable {
        case inherit, on, off
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Privacy — \(source.name)")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            Form {
                cursorAudioSection
                appExclusionsSection
                if payload.target != .window {
                    windowExclusionsSection
                }
            }
            .formStyle(.grouped)

            if let warning = overExclusionWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }

            Divider()

            HStack {
                Text("Applying restarts this source's capture with the new filter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft == payload.privacy)
            }
            .padding()
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .task { await loadWindows() }
    }

    // MARK: - Cursor and audio

    @ViewBuilder
    private var cursorAudioSection: some View {
        Section {
            Picker("Cursor", selection: Binding(
                get: { draft.showsCursor.map { $0 ? TriState.on : .off } ?? .inherit },
                set: { draft.showsCursor = $0 == .inherit ? nil : $0 == .on }
            )) {
                Text("Default (\(session.activeSettings.captureShowsCursor ? "Shown" : "Hidden"))")
                    .tag(TriState.inherit)
                Text("Show").tag(TriState.on)
                Text("Hide").tag(TriState.off)
            }

            Picker("App Audio", selection: Binding(
                get: { draft.capturesAudio.map { $0 ? TriState.on : .off } ?? .inherit },
                set: { draft.capturesAudio = $0 == .inherit ? nil : $0 == .on }
            )) {
                Text("Default (\(session.activeSettings.captureIncludesAudio ? "Included" : "Excluded"))")
                    .tag(TriState.inherit)
                Text("Include").tag(TriState.on)
                Text("Exclude").tag(TriState.off)
            }
        } header: {
            Text("Capture Options")
        } footer: {
            Text("“Default” follows the Capture Privacy settings; the other choices override them for this source only.")
        }
    }

    // MARK: - App exclusions

    /// Every bundle ID this capture excludes: the global defaults plus the
    /// source's own additions.
    private var effectiveExcludedBundleIDs: Set<String> {
        Set(session.activeSettings.captureExcludedBundleIDs + draft.excludedBundleIDs)
    }

    @ViewBuilder
    private var appExclusionsSection: some View {
        Section {
            ForEach(session.activeSettings.captureExcludedBundleIDs, id: \.self) { bundleID in
                HStack {
                    Label {
                        Text(RunningAppList.name(for: bundleID))
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "eye.slash")
                    }
                    Spacer()
                    Text("default")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .help("Excluded by the global Capture Privacy settings — change it there")
            }
            ForEach(draft.excludedBundleIDs, id: \.self) { bundleID in
                HStack {
                    Label {
                        Text(RunningAppList.name(for: bundleID))
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "eye.slash")
                    }
                    Spacer()
                    Button {
                        draft.excludedBundleIDs.removeAll { $0 == bundleID }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Stop excluding this app")
                }
            }
            Menu("Exclude an App…") {
                let candidates = RunningAppList.candidates(excluding: effectiveExcludedBundleIDs)
                if candidates.isEmpty {
                    Text("No other running apps")
                } else {
                    ForEach(candidates, id: \.bundleID) { candidate in
                        Button(candidate.name) {
                            draft.excludedBundleIDs.append(candidate.bundleID)
                        }
                    }
                }
            }
        } header: {
            Text("Excluded Apps")
        } footer: {
            if payload.target == .display {
                Text("Excluded apps' windows never appear in this capture. StreamMac's own windows are always excluded, including sheets and windows opened later — the studio can't capture itself.")
            } else {
                Text("Excluding the app this source targets fails closed: the source shows black with an error instead of capturing something else.")
            }
        }
    }

    // MARK: - Window exclusions

    /// Windows offered by the add-window menu: everything shareable except
    /// this app's windows (already impossible to pick), windows of excluded
    /// apps (already hidden), and windows already on the list. For an
    /// APPLICATION target only the target app's windows make sense — the
    /// filter only ever includes that app's windows.
    private var excludableWindows: [ShareableContentSnapshot.WindowItem] {
        guard let windowSnapshot else { return [] }
        return windowSnapshot.windows.filter { window in
            if payload.target == .application {
                guard window.bundleIdentifier == (payload.targetIdentifier ?? payload.applicationBundleID)
                else { return false }
            }
            if let bundleID = window.bundleIdentifier,
               effectiveExcludedBundleIDs.contains(bundleID) { return false }
            return !draft.excludedWindows.contains { $0.windowID == String(window.id) }
        }
    }

    @ViewBuilder
    private var windowExclusionsSection: some View {
        Section {
            ForEach(draft.excludedWindows, id: \.windowID) { window in
                HStack {
                    Label {
                        Text(windowTitle(window))
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "macwindow.badge.minus")
                    }
                    Spacer()
                    Button {
                        draft.excludedWindows.removeAll { $0.windowID == window.windowID }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Stop excluding this window")
                }
            }
            Menu("Exclude a Window…") {
                if windowSnapshot == nil {
                    Text("Window list needs the Screen Recording permission")
                } else {
                    let windows = excludableWindows
                    if windows.isEmpty {
                        Text("No other windows to exclude")
                    } else {
                        ForEach(windows) { window in
                            Button(windowMenuTitle(window)) {
                                draft.excludedWindows.append(CapturePrivacyOptions.ExcludedWindow(
                                    windowID: String(window.id),
                                    applicationBundleID: window.bundleIdentifier,
                                    windowTitle: window.title.isEmpty ? nil : window.title))
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Excluded Windows")
        } footer: {
            Text("Specific windows this capture hides. With window exclusions active, app exclusions resolve to the apps' current windows (a ScreenCaptureKit limitation): an excluded app can show windows it opens after capture starts.")
        }
    }

    private func windowTitle(_ window: CapturePrivacyOptions.ExcludedWindow) -> String {
        let app = window.applicationBundleID.map(RunningAppList.name(for:))
        let title = window.windowTitle?.isEmpty == false ? window.windowTitle! : "Untitled window"
        return app.map { "\($0) — \(title)" } ?? title
    }

    private func windowMenuTitle(_ window: ShareableContentSnapshot.WindowItem) -> String {
        let title = window.title.isEmpty ? "Untitled window" : window.title
        return "\(window.applicationName) — \(title)"
    }

    // MARK: - Over-exclusion (fail closed)

    /// Non-nil when the edited options exclude the source's OWN target — the
    /// capture then errors (black + warning) rather than re-pointing, and
    /// the user should know before applying.
    private var overExclusionWarning: String? {
        switch payload.target {
        case .display:
            return nil
        case .application:
            let bundleID = payload.targetIdentifier ?? payload.applicationBundleID
            guard let bundleID, effectiveExcludedBundleIDs.contains(bundleID) else { return nil }
            return "These options exclude \(RunningAppList.name(for: bundleID)), which is this source's target. Capture fails closed: the source shows black with an error and never captures anything else."
        case .window:
            if let bundleID = payload.applicationBundleID,
               effectiveExcludedBundleIDs.contains(bundleID) {
                return "These options exclude the app that owns this source's pinned window. Capture fails closed: the source shows black with an error and never captures anything else."
            }
            if let id = payload.targetIdentifier,
               draft.excludedWindows.contains(where: { $0.windowID == id }) {
                return "These options exclude this source's pinned window. Capture fails closed: the source shows black with an error and never captures anything else."
            }
            return nil
        }
    }

    // MARK: - Loading and applying

    private func loadWindows() async {
        guard payload.target != .window, windowSnapshot == nil,
              let content = try? await SCShareableContent.current else { return }
        windowSnapshot = ShareableContentSnapshot(content: content)
    }

    /// Writes the edited privacy back through the registry. The payload is
    /// the capture key, so the pool stops the old capture and starts one
    /// with the resolved filter — deliberate application, no mid-frame
    /// filter swaps.
    private func apply() {
        var updated = source
        var payload = payload
        payload.privacy = draft
        updated.payload = .screen(payload)
        sceneStore.updateSource(updated)
        dismiss()
    }
}
