import AppKit
import ScreenCaptureKit
import SwiftUI

/// C04 (issue #104): the per-source region / zoom / app-tracking editor,
/// presented as a sheet from the Sources tab (the embedded inspector),
/// following the C03 `ScreenSourcePrivacyView` pattern. Edits a DRAFT of the
/// source's region, zoom, and tracking options; Apply writes the payload
/// back through `SceneStore.updateSource`, which re-keys the capture pool —
/// the old capture stops and the new one starts with the resolved crop, so
/// geometry changes always apply deliberately, never mid-frame.
///
/// - REGION (display targets with a pinned display): edit named point fields
///   with the keyboard/steppers, or drag a marquee over a
///   live `SCScreenshotManager` thumbnail of the captured display (the
///   studio's own windows are excluded from the thumbnail, exactly like
///   capture). The region is persisted in display points plus the display's
///   size, so its relative geometry survives resolution changes.
/// - ZOOM: a follow-cursor zoom of the region/display (factor, cursor
///   tracking, ⌃-to-freeze), panned live while capturing.
/// - TRACKING: opt-in; the region follows the frontmost app, restricted to
///   an allow-list that can never contain Stream itself. A tracked app that
///   is also privacy-excluded fails closed at capture start (error + black),
///   never a silent re-point.
///
/// Honest capability states: window/application targets and unpinned
/// (system-picker) sources get an explanation instead of the region editor;
/// a disconnected display keeps the zoom/tracking sections editable and
/// allows region editing against honestly labeled stored display geometry.
struct ScreenSourceRegionView: View {
    let source: SourceDefinition
    /// The screen payload being edited (callers open this sheet only for
    /// screen sources).
    let payload: ScreenSourcePayload

    @EnvironmentObject private var sceneStore: SceneStore
    @EnvironmentObject private var session: SettingsSession
    @Environment(\.dismiss) private var dismiss

    @State private var draftRegion: CaptureRegion?
    @State private var draftZoom: ScreenZoomOptions
    @State private var draftTracking: ActiveAppTrackingOptions
    /// The pinned display's live point size; nil when the display is
    /// disconnected (or the Screen Recording permission is missing).
    @State private var displaySize: CGSize?
    @State private var thumbnail: NSImage?
    /// Why the live preview is unavailable (disconnected display, missing
    /// permission); nil when the thumbnail path loaded.
    @State private var previewNote: String?
    /// The in-progress marquee drag, normalized 0...1 (top-left origin).
    @State private var marquee: CGRect?
    @State private var numericRegion: ScreenRegionDraftGeometry?
    @State private var hasNumericInput = false

    init(source: SourceDefinition, payload: ScreenSourcePayload) {
        self.source = source
        self.payload = payload
        _draftRegion = State(initialValue: payload.region)
        _draftZoom = State(initialValue: payload.zoom)
        _draftTracking = State(initialValue: payload.appTracking)
        _numericRegion = State(initialValue: payload.region.flatMap {
            ScreenRegionDraftGeometry(rect: $0.rect, displaySize: $0.displaySize)
        })
    }

    /// Region/zoom/tracking crop a DISPLAY; other targets get the honest
    /// explanation instead of the editors.
    private var supportsRegionDynamics: Bool {
        payload.target == .display && payload.targetIdentifier != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Region & Zoom — \(source.name)")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            if supportsRegionDynamics {
                Form {
                    regionSection
                    zoomSection
                    trackingSection
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView {
                    Label("Display Sources Only", systemImage: "crop")
                } description: {
                    Text(payload.target == .display
                         ? "This source captures through the system picker. Pin a specific display (Change Target…) to define a region, zoom, or app tracking."
                         : "Regions, zoom, and app tracking crop a display. Window and application sources already capture exactly their target.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            HStack {
                Text("Applying restarts this source's capture with the new crop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty || !canApplyRegion)
            }
            .padding()
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .task { await loadPreview() }
        .onChange(of: displaySize) { _, _ in updateNumericBasis() }
    }

    private var isDirty: Bool {
        draftRegion != payload.region
            || draftZoom != payload.zoom
            || draftTracking != payload.appTracking
    }

    private var canApplyRegion: Bool {
        // Zoom/tracking remain editable without geometry for a full display.
        if draftRegion == nil && !hasNumericInput { return true }
        return numericRegion?.rect != nil
    }

    private var editingDisplaySize: CGSize? {
        ScreenRegionDraftGeometry.validDisplaySize(displaySize)
            ?? ScreenRegionDraftGeometry.validDisplaySize(payload.region?.displaySize)
    }

    // MARK: - Region

    @ViewBuilder
    private var regionSection: some View {
        Section {
            if let thumbnail, let displaySize = ScreenRegionDraftGeometry.validDisplaySize(displaySize) {
                regionEditor(thumbnail: thumbnail, displaySize: displaySize)
            } else {
                if let note = previewNote {
                    Label(note, systemImage: "display.trianglebadge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            numericRegionEditor
            if draftRegion != nil || hasNumericInput {
                Button("Reset to Full Display") {
                    draftRegion = nil
                    marquee = nil
                    hasNumericInput = false
                    numericRegion = editingDisplaySize.flatMap { ScreenRegionDraftGeometry(displaySize: $0) }
                }
            }
        } header: {
            Text("Capture Region")
        } footer: {
            Text(draftRegion == nil
                 ? "The full display is captured. Enter point values or drag across the preview to capture only part of it."
                 : "Only the marked area is captured. The region scales with the display's resolution; if it no longer fits, the source fails closed (black + error) instead of capturing the wrong area.")
        }
    }

    @ViewBuilder
    private var numericRegionEditor: some View {
        if let geometry = numericRegion {
            if ScreenRegionDraftGeometry.validDisplaySize(displaySize) != nil {
                Text("Display: \(geometry.displaySize.width, specifier: "%.2f") × \(geometry.displaySize.height, specifier: "%.2f") points. X and Y start at the top-left.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Using stored display size: \(geometry.displaySize.width, specifier: "%.2f") × \(geometry.displaySize.height, specifier: "%.2f") points. Live geometry is unavailable; capture will rescale and validate the region when the display is available.",
                      systemImage: "display.trianglebadge.exclamationmark")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(ScreenRegionDraftGeometry.Field.allCases, id: \.self) { field in
                LabeledContent("\(field.title) (points)") {
                    HStack {
                        TextField(field.title, text: Binding(
                            get: { numericRegion?[field] ?? "" },
                            set: { updateNumericField(field, text: $0) }))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 130)
                            .accessibilityLabel("Region \(field.title) in display points")
                            .accessibilityIdentifier("screenRegion.\(field.title)")
                        Stepper("Adjust region \(field.title)",
                                onIncrement: stepAction(field, by: 1),
                                onDecrement: stepAction(field, by: -1))
                            .labelsHidden()
                            .accessibilityLabel("Adjust region \(field.title)")
                            .accessibilityValue(geometry[field])
                            .accessibilityHint("Changes by one display point. Apply saves the draft.")
                    }
                }
            }
            if let message = geometry.validationMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if draftRegion == nil {
                Button("Use These Region Values") { commitNumericRegion() }
                    .disabled(geometry.rect == nil)
            }
        } else {
            Text(editingDisplaySize != nil && draftRegion != nil
                 ? "The stored region's display dimensions are invalid. Reset to Full Display to start a new region using the known display dimensions."
                 : "Region coordinates are unavailable until valid display dimensions or a stored region's display size are available. Full-display capture, zoom, and tracking can still be selected.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func updateNumericBasis() {
        guard let size = editingDisplaySize else { numericRegion = nil; return }
        if let geometry = numericRegion {
            numericRegion = geometry.rebased(to: size)
        } else if let draftRegion {
            numericRegion = ScreenRegionDraftGeometry(rect: draftRegion.rect, displaySize: draftRegion.displaySize)?.rebased(to: size)
        } else {
            numericRegion = ScreenRegionDraftGeometry(displaySize: size)
        }
    }

    private func updateNumericField(_ field: ScreenRegionDraftGeometry.Field, text: String) {
        guard numericRegion != nil else { return }
        hasNumericInput = true
        numericRegion?[field] = text
        commitNumericRegion()
    }

    private func commitNumericRegion() {
        guard let geometry = numericRegion, let rect = geometry.rect else { return }
        draftRegion = CaptureRegion(rect: rect, displaySize: geometry.displaySize)
        marquee = nil
    }

    private func stepAction(_ field: ScreenRegionDraftGeometry.Field, by delta: CGFloat) -> (() -> Void)? {
        guard numericRegion?.stepping(field, by: delta) != nil else { return nil }
        return {
            guard let next = numericRegion?.stepping(field, by: delta) else { return }
            numericRegion = next
            commitNumericRegion()
        }
    }

    /// The live thumbnail with the marquee drag surface and the current
    /// region overlay. Coordinates are normalized (0...1, top-left origin),
    /// matching the S04 canvas-interaction pattern.
    @ViewBuilder
    private func regionEditor(thumbnail: NSImage, displaySize: CGSize) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Image(nsImage: thumbnail)
                    .resizable()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                let region = marquee ?? normalizedDraftRegion(displaySize: displaySize)
                if let region {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: region.width * proxy.size.width,
                               height: region.height * proxy.size.height)
                        .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1.5)
                            .frame(width: region.width * proxy.size.width,
                                   height: region.height * proxy.size.height))
                        .offset(x: region.minX * proxy.size.width,
                                y: region.minY * proxy.size.height)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        let start = normalized(value.startLocation, in: proxy.size)
                        let now = normalized(value.location, in: proxy.size)
                        marquee = CGRect(x: min(start.x, now.x), y: min(start.y, now.y),
                                         width: abs(now.x - start.x), height: abs(now.y - start.y))
                    }
                    .onEnded { _ in commitMarquee(displaySize: displaySize) }
            )
        }
        .aspectRatio(displaySize.width / displaySize.height, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    }

    private func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: min(1, max(0, point.x / size.width)),
                y: min(1, max(0, point.y / size.height)))
    }

    /// The draft region normalized against the LIVE display size (rescaled
    /// with the same math capture uses, so the overlay shows what capture
    /// will crop even after a resolution change).
    private func normalizedDraftRegion(displaySize: CGSize) -> CGRect? {
        guard let region = draftRegion,
              let resolved = ScreenSourceCapture.resolvedRegion(region, displaySize: displaySize)
        else { return nil }
        return CGRect(x: resolved.minX / displaySize.width,
                      y: resolved.minY / displaySize.height,
                      width: resolved.width / displaySize.width,
                      height: resolved.height / displaySize.height)
    }

    /// Commits the drag as the new region (display points + the live display
    /// size — the pair the rescaler needs). Drags below the minimum region
    /// size are treated as taps and keep the existing region.
    private func commitMarquee(displaySize: CGSize) {
        defer { marquee = nil }
        guard let marquee else { return }
        let rect = CGRect(x: marquee.minX * displaySize.width,
                          y: marquee.minY * displaySize.height,
                          width: marquee.width * displaySize.width,
                          height: marquee.height * displaySize.height)
        guard rect.width >= 32, rect.height >= 32 else { return }
        guard let geometry = ScreenRegionDraftGeometry(rect: rect, displaySize: displaySize), geometry.rect != nil else { return }
        draftRegion = CaptureRegion(rect: rect, displaySize: displaySize)
        numericRegion = geometry
    }

    // MARK: - Zoom

    @ViewBuilder
    private var zoomSection: some View {
        Section {
            Toggle("Follow-Cursor Zoom", isOn: $draftZoom.isEnabled)
            if draftZoom.isEnabled {
                HStack {
                    Text("Zoom")
                    Slider(value: $draftZoom.zoomFactor, in: 1.5 ... 4.0, step: 0.25)
                        .accessibilityLabel("Follow-cursor zoom for \(source.name)")
                        .accessibilityValue(draftZoom.zoomFactor.isFinite
                            ? String(format: "%.2g times", draftZoom.zoomFactor) : "Unavailable")
                    Text("\(draftZoom.zoomFactor, specifier: "%.2g")×")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                Toggle("Track the Cursor", isOn: $draftZoom.followsCursor)
                if draftZoom.followsCursor {
                    Toggle("Hold ⌃ to Freeze Panning", isOn: $draftZoom.pauseWithControlKey)
                }
            }
        } header: {
            Text("Screen Zoom")
        } footer: {
            Text("Zoom crops the captured area live — no capture restart per cursor move. Panning is smoothed and pauses when the cursor is still; with tracking off it holds a fixed centered zoom.")
        }
    }

    // MARK: - Active-app tracking

    /// Apps the tracking allow-list may add: running, not already allowed,
    /// not the studio itself (never followable), and not privacy-excluded
    /// (that combination fails closed at capture start, so the editor
    /// doesn't offer it).
    private var effectiveExcludedBundleIDs: Set<String> {
        Set(session.activeSettings.captureExcludedBundleIDs + payload.privacy.excludedBundleIDs)
    }

    @ViewBuilder
    private var trackingSection: some View {
        Section {
            Toggle("Follow the Frontmost App", isOn: $draftTracking.isEnabled)
            if draftTracking.isEnabled {
                ForEach(draftTracking.allowedBundleIDs, id: \.self) { bundleID in
                    HStack {
                        Label {
                            Text(RunningAppList.name(for: bundleID))
                                .lineLimit(1)
                        } icon: {
                            Image(systemName: "app.badge")
                        }
                        Spacer()
                        Button {
                            draftTracking.allowedBundleIDs.removeAll { $0 == bundleID }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Stop following this app")
                    }
                }
                Menu("Allow an App…") {
                    let candidates = RunningAppList.candidates(
                        excluding: effectiveExcludedBundleIDs.union(draftTracking.allowedBundleIDs))
                    if candidates.isEmpty {
                        Text("No other running apps")
                    } else {
                        ForEach(candidates, id: \.bundleID) { candidate in
                            Button(candidate.name) {
                                draftTracking.allowedBundleIDs.append(candidate.bundleID)
                            }
                        }
                    }
                }
                if draftTracking.allowedBundleIDs.isEmpty {
                    Text("Allow at least one app — with an empty list the region never moves.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("App Tracking")
        } footer: {
            Text("When an allowed app becomes frontmost, the region moves to its main window on this display. Stream itself can never be followed — switching back to the studio leaves the region where it is. An allowed app excluded by privacy fails closed (black + error), never a silent re-point.")
        }
    }

    // MARK: - Loading and applying

    /// Loads the pinned display's live size and a thumbnail via
    /// SCScreenshotManager (macOS 14+). The thumbnail excludes the studio's
    /// own windows, exactly like the capture filter, so the region is drawn
    /// over what the source will actually capture.
    private func loadPreview() async {
        defer { updateNumericBasis() }
        guard payload.target == .display,
              let id = payload.targetIdentifier.flatMap({ UInt32($0) }) else { return }
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                previewNote = "The display is not connected. Region fields can use valid stored display dimensions; zoom and tracking can still be edited."
                return
            }
            displaySize = display.frame.size
            let studioApps = content.applications.filter {
                $0.bundleIdentifier == ScreenSourceCapture.studioBundleID
            }
            let filter = SCContentFilter(display: display,
                                         excludingApplications: studioApps,
                                         exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            let fullWidth = max(2, Int((filter.contentRect.width * scale).rounded()))
            let fullHeight = max(2, Int((filter.contentRect.height * scale).rounded()))
            let shrink = min(1, 960 / CGFloat(fullWidth))
            configuration.width = max(2, Int((CGFloat(fullWidth) * shrink).rounded()))
            configuration.height = max(2, Int((CGFloat(fullHeight) * shrink).rounded()))
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                   configuration: configuration)
            thumbnail = NSImage(cgImage: image, size: NSSize(width: configuration.width,
                                                             height: configuration.height))
        } catch {
            previewNote = "The display preview needs the Screen Recording permission. Enable it for StreamMac in System Settings > Privacy & Security > Screen Recording."
        }
    }

    /// Writes the edited options back through the registry. The payload is
    /// the capture key, so the pool stops the old capture and starts one
    /// with the new crop — deliberate application, no mid-frame crop swaps.
    private func apply() {
        guard isDirty, canApplyRegion else { return }
        var updated = source
        var payload = payload
        if draftRegion != nil {
            guard let geometry = numericRegion, let rect = geometry.rect else { return }
            payload.region = CaptureRegion(rect: rect, displaySize: geometry.displaySize)
        } else { payload.region = nil }
        payload.zoom = draftZoom
        payload.appTracking = draftTracking
        updated.payload = .screen(payload)
        sceneStore.updateSource(updated)
        dismiss()
    }
}
