import AppKit
import ScreenCaptureKit
import SwiftUI

/// C02 (issue #77): the screen-source picker sheet. Unlike the system
/// `SCContentSharingPicker` (which vends a one-off `SCContentFilter` with no
/// restorable identity), this lists the live `SCShareableContent` — displays,
/// on-screen windows, and running applications — so the user's choice is
/// persisted as a pinned `ScreenSourcePayload` (display/window/application)
/// that captures independently through the source registry and survives app
/// restarts (window IDs are volatile; the payload persists the owning app +
/// title for relinking — see `ScreenSourceCapture.start(matching:)`).
///
/// `onSelect` receives a suggested source name plus the pinned payload; the
/// caller decides whether to register a new source or retarget an existing
/// one. A missing Screen Recording permission surfaces in place with repair
/// guidance instead of an empty list.
struct ScreenSourcePickerView: View {
    let onSelect: (String, ScreenSourcePayload) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    /// The highlighted row; the Add button acts on it (single click selects,
    /// double click confirms).
    @State private var selection: RowID?

    private enum Phase {
        case loading
        case failed(String)
        case loaded(ShareableContentSnapshot)
    }

    private enum RowID: Hashable {
        case display(UInt32)
        case window(CGWindowID)
        case application(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose what to capture")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            Group {
                switch phase {
                case .loading:
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Loading shareable content…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Screen Capture Unavailable", systemImage: "rectangle.dashed.badge.record")
                    } description: {
                        Text(message)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded(let snapshot):
                    contentList(snapshot)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Button("Refresh") { phase = .loading; Task { await load() } }
                Spacer()
                Button("Add Source") { confirmSelection() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
            .padding()
        }
        .frame(width: 440, height: 500)
        .task { await load() }
    }

    // MARK: - Content list

    @ViewBuilder
    private func contentList(_ snapshot: ShareableContentSnapshot) -> some View {
        List(selection: $selection) {
            Section("Displays") {
                ForEach(snapshot.displays) { display in
                    Label {
                        Text(display.name)
                    } icon: {
                        Image(systemName: "display")
                    }
                    .tag(RowID.display(display.id))
                    .onTapGesture(count: 2) { select(display: display) }
                }
            }
            Section("Windows") {
                ForEach(snapshot.windows) { window in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(window.title.isEmpty ? "Untitled window" : window.title)
                                .lineLimit(1)
                            Text(window.applicationName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "macwindow")
                    }
                    .tag(RowID.window(window.id))
                    .onTapGesture(count: 2) { select(window: window) }
                }
            }
            Section("Applications") {
                ForEach(snapshot.applications) { application in
                    Label(application.name, systemImage: "app.fill")
                        .tag(RowID.application(application.bundleIdentifier))
                        .onTapGesture(count: 2) { select(application: application) }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if snapshot.displays.isEmpty, snapshot.windows.isEmpty, snapshot.applications.isEmpty {
                ContentUnavailableView("Nothing to Capture",
                                       systemImage: "rectangle.dashed",
                                       description: Text("No displays, windows, or applications are shareable right now."))
            }
        }
    }

    // MARK: - Selection

    private func confirmSelection() {
        guard case .loaded(let snapshot) = phase, let selection else { return }
        switch selection {
        case .display(let id):
            if let display = snapshot.displays.first(where: { $0.id == id }) {
                select(display: display)
            }
        case .window(let id):
            if let window = snapshot.windows.first(where: { $0.id == id }) {
                select(window: window)
            }
        case .application(let bundleID):
            if let application = snapshot.applications.first(where: { $0.bundleIdentifier == bundleID }) {
                select(application: application)
            }
        }
    }

    private func select(display: ShareableContentSnapshot.DisplayItem) {
        onSelect(display.name, ScreenSourcePayload(
            target: .display,
            targetIdentifier: String(display.id)))
        dismiss()
    }

    private func select(window: ShareableContentSnapshot.WindowItem) {
        let title = window.title.isEmpty ? window.applicationName : window.title
        onSelect("\(window.applicationName) — \(title)", ScreenSourcePayload(
            target: .window,
            targetIdentifier: String(window.id),
            applicationBundleID: window.bundleIdentifier,
            windowTitle: window.title.isEmpty ? nil : window.title))
        dismiss()
    }

    private func select(application: ShareableContentSnapshot.ApplicationItem) {
        onSelect(application.name, ScreenSourcePayload(
            target: .application,
            targetIdentifier: application.bundleIdentifier,
            applicationBundleID: application.bundleIdentifier))
        dismiss()
    }

    // MARK: - Loading

    private func load() async {
        do {
            let content = try await SCShareableContent.current
            phase = .loaded(ShareableContentSnapshot(content: content))
        } catch {
            phase = .failed("Screen Recording permission is required to list capturable content. Enable it for StreamMac in System Settings > Privacy & Security > Screen Recording, then relaunch StreamMac. (\(error.localizedDescription))")
        }
    }
}

/// A Sendable snapshot of `SCShareableContent` reduced to what the picker UI
/// renders. `SCShareableContent` and its element types are non-Sendable
/// reference types, so the picker extracts value snapshots on the main actor
/// right after loading and never touches the live objects again.
struct ShareableContentSnapshot: Sendable {
    struct DisplayItem: Identifiable, Hashable, Sendable {
        var id: UInt32   // CGDirectDisplayID
        var name: String
    }

    struct WindowItem: Identifiable, Hashable, Sendable {
        var id: CGWindowID
        var title: String
        var applicationName: String
        var bundleIdentifier: String?
    }

    struct ApplicationItem: Identifiable, Hashable, Sendable {
        var bundleIdentifier: String
        var name: String
        var id: String { bundleIdentifier }
    }

    var displays: [DisplayItem]
    var windows: [WindowItem]
    var applications: [ApplicationItem]

    @MainActor
    init(content: SCShareableContent) {
        // Display names come from AppKit (SCDisplay has no name API): match
        // on the NSScreenNumber device-description key, which IS the
        // CGDirectDisplayID.
        let screenNames: [UInt32: String] = Dictionary(
            NSScreen.screens.compactMap { screen -> (UInt32, String)? in
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
                else { return nil }
                return (id, screen.localizedName)
            },
            uniquingKeysWith: { first, _ in first })
        displays = content.displays.map { display in
            DisplayItem(id: display.displayID,
                        name: screenNames[display.displayID] ?? "Display \(display.displayID)")
        }
        // Only real on-screen, layer-0 windows: everything else (menu bar
        // extras, desktop services) is noise a user would never pick. Our own
        // windows are excluded — capturing StreamMac itself is never intended.
        let ownBundleID = Bundle.main.bundleIdentifier
        windows = content.windows
            .filter { window in
                window.isOnScreen && window.windowLayer == 0
                    && window.owningApplication?.bundleIdentifier != ownBundleID
            }
            .map { window in
                WindowItem(id: window.windowID,
                           title: window.title ?? "",
                           applicationName: window.owningApplication?.applicationName ?? "Unknown",
                           bundleIdentifier: window.owningApplication?.bundleIdentifier)
            }
            .sorted { $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending }
        applications = content.applications
            .filter { $0.bundleIdentifier != ownBundleID }
            .map { ApplicationItem(bundleIdentifier: $0.bundleIdentifier,
                                   name: $0.applicationName) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
