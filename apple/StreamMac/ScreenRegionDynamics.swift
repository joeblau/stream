import AppKit
import CoreGraphics
import ScreenCaptureKit
import os

private let regionDynamicsLog = Logger(subsystem: "com.joeblau.StreamMac", category: "screen-region-dynamics")

/// C04 (issue #104): the value snapshot `ScreenSourceCapture` hands the
/// dynamics controller at capture start. Everything the runtime needs is
/// resolved up front (display geometry, base region, zoom/tracking options,
/// the effective exclusion list) so the controller never re-reads settings.
struct ScreenRegionDynamicsInput: Sendable {
    var displayID: UInt32
    /// The captured display's frame in global top-left-origin points (the
    /// same space `CGEvent` cursor locations and `SCWindow.frame` use).
    var displayFrame: CGRect
    /// The display filter's content rect (== `displayFrame` for display
    /// filters); crops are clamped to it before hitting the stream.
    var contentRect: CGRect
    /// The filter's point-to-pixel scale, for output sizing.
    var pointScale: CGFloat
    /// The crop's resting rect in DISPLAY-RELATIVE points: the persisted
    /// region (rescaled to the live display size) or the full display.
    var baseRegion: CGRect
    var zoom: ScreenZoomOptions
    var tracking: ActiveAppTrackingOptions
    /// The effective exclusion list (global ∪ per-source, plus the studio's
    /// own bundle ID), for the tracking fail-closed check.
    var excludedBundleIDs: [String]

    /// Maps a display-relative crop into filter coordinates plus the output
    /// pixel size (at the filter's point-to-pixel scale).
    func filterCrop(for region: CGRect) -> (rect: CGRect, pixelSize: CGSize) {
        let global = region.offsetBy(dx: displayFrame.minX, dy: displayFrame.minY)
        let crop = global.intersection(contentRect)
        return (crop, CGSize(width: max(2, (crop.width * pointScale).rounded()),
                             height: max(2, (crop.height * pointScale).rounded())))
    }
}

/// C04 (issue #104): the live region/zoom/tracking runtime for one pinned
/// display capture. Owns two inputs and one output:
///
/// - ZOOM: a background-timer cursor poll (`CursorPollTimer`, ~30 Hz, off the
///   main thread — `CGEvent` location and `CGEventSource` flags are
///   thread-safe) feeding an exponentially-smoothed pan of the zoomed crop.
///   A still cursor converges and stops emitting updates (the "pause" case);
///   holding ⌃ freezes the pan outright when `pauseWithControlKey` is set.
/// - ACTIVE-APP TRACKING: `NSWorkspace.didActivateApplicationNotification`
///   moves the base region to the frontmost app's main window — only for
///   `allowedBundleIDs`, never for Stream itself (switching back to the
///   studio leaves the region put, so its controls can't be captured), and
///   fail-closed when the followed app sits on the privacy exclusion list.
/// - OUTPUT: `onCrop` delivers a crop rect in FILTER coordinates plus the
///   output pixel size; the capture applies it through
///   `SCStream.updateConfiguration`, so zoom/tracking never restart capture.
@MainActor
final class ScreenRegionDynamicsController {
    /// New crop in filter coordinates + output pixel size.
    var onCrop: (@Sendable (CGRect, CGSize) -> Void)?
    /// Fail-closed report: tracking followed a privacy-excluded app.
    var onFailClosed: (@Sendable (String) -> Void)?

    private var input: ScreenRegionDynamicsInput
    private var smoothed: CGRect?
    private var lastEmitted: CGRect?
    private var poller: CursorPollTimer?
    private var workspaceObserver: NSObjectProtocol?
    private var followTask: Task<Void, Never>?

    /// Cursor poll cadence (seconds) and the pan smoothing time constant.
    private static let pollInterval: TimeInterval = 1.0 / 30.0
    private static let smoothingTau: TimeInterval = 0.15

    init(input: ScreenRegionDynamicsInput) {
        self.input = input
    }

    /// The crop the capture should start with (the base region — the first
    /// cursor tick pans to the cursor from here when zoom follows it).
    var initialCrop: (rect: CGRect, pixelSize: CGSize) {
        input.filterCrop(for: input.baseRegion)
    }

    func start() {
        if input.zoom.isEnabled {
            let poller = CursorPollTimer(interval: Self.pollInterval) { [weak self] cursor, controlHeld in
                Task { @MainActor in self?.tick(cursor: cursor, controlHeld: controlHeld) }
            }
            self.poller = poller
            poller.start()
        }
        if input.tracking.isEnabled, !input.tracking.allowedBundleIDs.isEmpty {
            workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main
            ) { [weak self] note in
                let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey]
                                as? NSRunningApplication)?.bundleIdentifier
                Task { @MainActor in self?.frontmostActivated(bundleID) }
            }
        }
    }

    func stop() {
        poller?.cancel()
        poller = nil
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        followTask?.cancel()
        followTask = nil
        onCrop = nil
        onFailClosed = nil
    }

    // MARK: - Zoom (cursor-following pan)

    private func tick(cursor: CGPoint?, controlHeld: Bool) {
        guard input.zoom.isEnabled else { return }
        // The modifier pause: freeze the pan where it is while ⌃ is held.
        if controlHeld, input.zoom.pauseWithControlKey { return }
        // Global (top-left origin) → display-relative.
        let local = cursor.map {
            CGPoint(x: $0.x - input.displayFrame.minX, y: $0.y - input.displayFrame.minY)
        }
        let target = targetRegion(cursor: local)
        let blend = CGFloat(1 - exp(-Self.pollInterval / Self.smoothingTau))
        if let current = smoothed {
            smoothed = CGRect(
                x: current.minX + (target.minX - current.minX) * blend,
                y: current.minY + (target.minY - current.minY) * blend,
                width: current.width + (target.width - current.width) * blend,
                height: current.height + (target.height - current.height) * blend)
        } else {
            smoothed = target
        }
        emitIfChanged()
    }

    /// The crop the pan is heading for: the base region shrunk by the zoom
    /// factor, centered on the cursor (clamped inside the base region). No
    /// cursor — follow off or a nil poll — zooms the base region's center
    /// (a static zoom); a factor of 1 is the base region itself.
    private func targetRegion(cursor: CGPoint?) -> CGRect {
        let base = input.baseRegion
        let factor = input.zoom.isEnabled ? CGFloat(max(1.0, input.zoom.zoomFactor)) : 1
        guard factor > 1.0 else { return base }
        let size = CGSize(width: base.width / factor, height: base.height / factor)
        let center = input.zoom.followsCursor ? cursor : nil
        let aimed = center ?? CGPoint(x: base.midX, y: base.midY)
        let centerX = min(max(aimed.x, base.minX + size.width / 2),
                          base.maxX - size.width / 2)
        let centerY = min(max(aimed.y, base.minY + size.height / 2),
                          base.maxY - size.height / 2)
        return CGRect(x: centerX - size.width / 2, y: centerY - size.height / 2,
                      width: size.width, height: size.height)
    }

    // MARK: - Active-app tracking

    private func frontmostActivated(_ bundleID: String?) {
        guard let bundleID,
              input.tracking.allowedBundleIDs.contains(bundleID) else { return }
        // Stream itself is never followed (it can never be in the allowed
        // list either): switching back to the studio leaves the region where
        // it is, so the studio's controls can't be captured — display
        // filters exclude studio windows regardless.
        guard bundleID != ScreenSourceCapture.studioBundleID else { return }
        // Fail closed: a tracked app the privacy options exclude reports the
        // error state — the region NEVER silently re-points to it.
        if input.excludedBundleIDs.contains(bundleID) {
            let name = NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == bundleID }?.localizedName ?? bundleID
            regionDynamicsLog.error("Tracked app is privacy-excluded; failing closed: \(bundleID, privacy: .public)")
            onFailClosed?("App tracking followed \(name), which this source's privacy options exclude. Capture stopped rather than re-pointing — remove the exclusion or the tracking entry.")
            return
        }
        followTask?.cancel()
        followTask = Task { await followApp(bundleID) }
    }

    /// Moves the base region to the followed app's main window on the
    /// captured display (largest overlap). An app with no window on this
    /// display leaves the region where it is — same source, no re-point.
    private func followApp(_ bundleID: String) async {
        guard let content = try? await SCShareableContent.current,
              !Task.isCancelled else { return }
        var best: (rect: CGRect, area: CGFloat)?
        for window in content.windows
        where window.owningApplication?.bundleIdentifier == bundleID
                && window.isOnScreen && window.windowLayer == 0 {
            let overlap = window.frame.intersection(input.displayFrame)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
            let area = overlap.width * overlap.height
            if area > (best?.area ?? 0) { best = (overlap, area) }
        }
        guard let best, !Task.isCancelled else { return }
        input.baseRegion = best.rect.offsetBy(dx: -input.displayFrame.minX,
                                              dy: -input.displayFrame.minY)
        // A region jump is deliberate (the user switched apps), so snap —
        // the smoothed pan resumes from the new region.
        smoothed = nil
        lastEmitted = nil
        emitIfChanged()
    }

    // MARK: - Emission

    private func emitIfChanged() {
        let rect = smoothed ?? targetRegion(cursor: nil)
        if let lastEmitted,
           abs(lastEmitted.minX - rect.minX) < 0.75,
           abs(lastEmitted.minY - rect.minY) < 0.75,
           abs(lastEmitted.width - rect.width) < 0.75,
           abs(lastEmitted.height - rect.height) < 0.75 {
            return
        }
        lastEmitted = rect
        let crop = input.filterCrop(for: rect)
        onCrop?(crop.rect, crop.pixelSize)
    }
}

/// A repeating `DispatchSourceTimer` on a background queue polling the global
/// cursor location (`CGEvent`, thread-safe) and the ⌃ key state
/// (`CGEventSource.flagsState`, thread-safe), so zoom tracking stays off the
/// main thread. `cancel` is safe before or after `start`.
final class CursorPollTimer: @unchecked Sendable {
    private let timer: DispatchSourceTimer
    private var resumed = false

    init(interval: TimeInterval,
         handler: @escaping @Sendable (CGPoint?, Bool) -> Void) {
        timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "com.joeblau.StreamMac.cursor-poll",
                                 qos: .userInteractive))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler {
            let location = CGEvent(source: nil)?.location
            let controlHeld = CGEventSource.flagsState(.combinedSessionState).contains(.maskControl)
            handler(location, controlHeld)
        }
    }

    func start() {
        guard !resumed else { return }
        resumed = true
        timer.resume()
    }

    func cancel() {
        // A dispatch source must be resumed before release/cancel.
        if !resumed { timer.resume() }
        timer.cancel()
    }
}
