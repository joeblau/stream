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
/// - REGION (display targets with a pinned display): drag a marquee over a
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
/// shows the stored region numerically.
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

    init(source: SourceDefinition, payload: ScreenSourcePayload) {
        self.source = source
        self.payload = payload
        _draftRegion = State(initialValue: payload.region)
        _draftZoom = State(initialValue: payload.zoom)
        _draftTracking = State(initialValue: payload.appTracking)
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
                    .disabled(!isDirty)
            }
            .padding()
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .task { await loadPreview() }
    }

    private var isDirty: Bool {
        draftRegion != payload.region
            || draftZoom != payload.zoom
            || draftTracking != payload.appTracking
    }

    // MARK: - Region

    @ViewBuilder
    private var regionSection: some View {
        Section {
            if let thumbnail, let displaySize {
                regionEditor(thumbnail: thumbnail, displaySize: displaySize)
            } else {
                if let note = previewNote {
                    Label(note, systemImage: "display.trianglebadge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let region = draftRegion {
                    LabeledContent("Stored Region") {
                        Text("\(Int(region.rect.width))×\(Int(region.rect.height)) at (\(Int(region.rect.minX)), \(Int(region.rect.minY)))")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if draftRegion != nil {
                Button("Reset to Full Display") {
                    draftRegion = nil
                    marquee = nil
                }
            }
        } header: {
            Text("Capture Region")
        } footer: {
            Text(draftRegion == nil
                 ? "The full display is captured. Drag across the preview to capture only part of it."
                 : "Only the marked area is captured. The region scales with the display's resolution; if it no longer fits, the source fails closed (black + error) instead of capturing the wrong area.")
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
        draftRegion = CaptureRegion(rect: rect, displaySize: displaySize)
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
        guard payload.target == .display,
              let id = payload.targetIdentifier.flatMap({ UInt32($0) }) else { return }
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                previewNote = "The display is not connected. Zoom and tracking can still be edited; the region shows its stored values."
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
        var updated = source
        var payload = payload
        payload.region = draftRegion
        payload.zoom = draftZoom
        payload.appTracking = draftTracking
        updated.payload = .screen(payload)
        sceneStore.updateSource(updated)
        dismiss()
    }
}
