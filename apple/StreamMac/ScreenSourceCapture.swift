import Combine
import CoreMedia
import ScreenCaptureKit
import StreamCore
import os

private let screenSourceLog = Logger(subsystem: "com.joeblau.StreamMac", category: "screen-source-capture")

/// Owns the macOS ScreenCaptureKit capture flow: the system content-sharing
/// picker, the SCStream lifecycle, and forwarding of screen/app-audio/mic
/// sample buffers to the publisher layer.
///
/// `pickAndStart(defaults:)` presents `SCContentSharingPicker` for the user
/// to choose a display, window, or application (the DEFAULT, unpinned source
/// path). `start(matching:defaults:)` silently resolves a registry
/// `ScreenSourcePayload`'s pinned display (`CGDirectDisplayID`), window
/// (`CGWindowID`, with an owning-app + title relink fallback — window IDs are
/// volatile), or application (bundle identifier) target. A pinned target that
/// cannot be resolved surfaces an error and captures NOTHING: it never falls
/// back to the first display or an arbitrary window, so a missing source can
/// never expose unrelated desktop content (C02, issue #77).
/// `start(with:)` accepts a filter directly for callers that already know
/// what to capture.
///
/// C03 (issue #78) privacy: every capture resolves an
/// `EffectiveCapturePrivacy` (per-source payload overrides over the global
/// settings defaults). Display filters ALWAYS exclude this app's own windows
/// (main window, sheets, panels — the app-exclusion filter tracks windows
/// created after capture start, so the studio can never capture itself, no
/// infinite mirror) plus the user's excluded apps/windows. Cursor and audio
/// flags hang off the SCStreamConfiguration built in `start(with:)`.
/// Over-exclusion fails CLOSED: a source whose privacy options hide its own
/// target reports an error and captures nothing — it never re-points.
/// OS limitation: the system content-sharing picker vends an opaque filter,
/// so the unpinned picker path can only apply cursor/audio options, not
/// app/window exclusions — pin the source from the Sources tab for those.
///
/// C04 (issue #104): pinned DISPLAY payloads can also carry a capture
/// `region`, follow-cursor `zoom`, and opt-in active-app tracking. The
/// region is persisted relative to the display's size at draw time and
/// rescaled against the live display, so its relative geometry survives
/// resolution/scale changes; a region that no longer fits fails closed
/// (error + black, the defined fallback — never a silent re-point). The
/// crop rides `SCStreamConfiguration.sourceRect`/width/height through the
/// same `start(with:privacy:)` path, and zoom/tracking pan it LIVE via
/// `SCStream.updateConfiguration` (no capture restarts per cursor move) —
/// see `ScreenRegionDynamicsController`. Tracking follows only the payload's
/// allowed apps, never Stream itself, and fails closed when the followed app
/// is privacy-excluded.
@MainActor
final class ScreenSourceCapture: ObservableObject {
    @Published private(set) var isCapturing = false
    /// Human-readable description of the last failure (Screen Recording
    /// permission denial, start failure, or a mid-capture stop). User
    /// cancellation is not an error and leaves this nil.
    @Published private(set) var errorMessage: String?

    /// Called with each screen sample buffer, hopped to the main actor. The
    /// consumer is expected to throttle; capture runs at the source's refresh.
    var onVideoSample: ((CMSampleBuffer) -> Void)?
    /// Called with each app-audio or microphone sample buffer, main actor.
    var onAudioSample: ((CMSampleBuffer) -> Void)?
    /// A01 (issue #82): real-time audio hand-off that fires DIRECTLY on the
    /// SCStream sample queue — no main-actor hop — so the audio engine's
    /// format conversion never runs on the main thread. Read once when the
    /// stream is configured (set it before `start`/`pickAndStart`).
    var onAudioSampleOffMain: (@Sendable (CMSampleBuffer) -> Void)?

    private let picker = SCContentSharingPicker.shared
    private var pickerObserver: PickerObserverShim?
    private var pickerContinuation: CheckedContinuation<UncheckedSendableBox<SCContentFilter>?, Never>?
    private var pickerStartFailed = false
    /// The filter the user last picked (or a fallback resolved to), reused on
    /// restart so an unchanged source never re-presents the picker (S05).
    private var lastFilter: SCContentFilter?
    /// C03: the privacy applied to the picker path's next start (the picker
    /// filter is opaque, so only the configuration flags can carry it).
    private var pickerPrivacy: EffectiveCapturePrivacy = .standard
    private var stream: SCStream?
    private var output: StreamOutputShim?
    /// C04: the configuration handed to the running stream, retained so the
    /// region dynamics can re-apply it (with a new `sourceRect`) through
    /// `updateConfiguration`. Nil whenever no stream runs.
    private var activeConfiguration: SCStreamConfiguration?
    /// C04: the live region/zoom/tracking runtime (pinned display captures
    /// with region dynamics only); torn down with the stream.
    private var regionDynamics: ScreenRegionDynamicsController?
    /// Serial queue for all SCStream sample callbacks.
    private let sampleQueue = DispatchQueue(label: "com.joeblau.StreamMac.screen-source.samples",
                                            qos: .userInitiated)

    init() {
        let observer = PickerObserverShim(
            onCancel: { [weak self] in
                Task { @MainActor in self?.pickerDidCancel() }
            },
            onFilter: { [weak self] filter in
                Task { @MainActor in self?.pickerDidSelect(filter.value) }
            },
            onFailure: { [weak self] error in
                Task { @MainActor in self?.pickerDidFail(error.value) }
            }
        )
        // Retained for the object's lifetime: SCContentSharingPicker does not
        // retain its observers.
        pickerObserver = observer
        picker.add(observer)
    }

    /// Presents the system content-sharing picker, then starts an SCStream for
    /// whatever the user selects. A restart of an unchanged source reuses the
    /// remembered selection instead of re-prompting (S05, issue #73); the
    /// picker only appears when no selection exists yet. A user cancel simply
    /// leaves capture off; a picker that fails to start surfaces an error —
    /// it NEVER silently captures the first display (C02, issue #77), so an
    /// unpinned source can't expose content the user didn't choose.
    ///
    /// C03: the global defaults' cursor/audio options apply to the picked
    /// stream; app/window exclusions can't — the picker filter is opaque (see
    /// the type doc).
    func pickAndStart(defaults: StreamSettings = .default) async {
        guard stream == nil, pickerContinuation == nil else { return }
        errorMessage = nil
        pickerPrivacy = EffectiveCapturePrivacy(
            showsCursor: defaults.captureShowsCursor,
            capturesAudio: defaults.captureIncludesAudio,
            excludedBundleIDs: defaults.captureExcludedBundleIDs,
            excludedWindows: [])
        if let lastFilter {
            await start(with: lastFilter, privacy: pickerPrivacy)
            return
        }
        pickerStartFailed = false
        picker.isActive = true
        let selection = await withCheckedContinuation { continuation in
            pickerContinuation = continuation
            picker.present()
        }
        picker.isActive = false
        if let selection {
            await start(with: selection.value, privacy: pickerPrivacy)
        } else if pickerStartFailed {
            errorMessage = "The content-sharing picker could not be presented. Add a screen source from the Sources tab instead, or try again."
        }
    }

    /// Starts capturing the content described by `filter` — display, window, or
    /// application — with audio from the captured apps and the microphone.
    /// C03: `privacy` sets the cursor and app-audio configuration flags.
    /// C04: `dynamics` (pinned display captures with a region, zoom, or app
    /// tracking) crops the stream to the region through
    /// `SCStreamConfiguration.sourceRect` and then pans the crop live via
    /// `ScreenRegionDynamicsController` + `updateConfiguration`.
    func start(with filter: SCContentFilter,
               privacy: EffectiveCapturePrivacy = .standard,
               dynamics: ScreenRegionDynamicsInput? = nil) async {
        if stream != nil { await stop() }
        errorMessage = nil
        lastFilter = filter

        let configuration = SCStreamConfiguration()
        // Native pixel size of the picked content; never hardcoded.
        let scale = CGFloat(filter.pointPixelScale)
        if let dynamics {
            let initial = dynamics.filterCrop(for: dynamics.baseRegion)
            configuration.sourceRect = initial.rect
            configuration.width = Int(initial.pixelSize.width)
            configuration.height = Int(initial.pixelSize.height)
        } else {
            configuration.width = max(2, Int((filter.contentRect.width * scale).rounded()))
            configuration.height = max(2, Int((filter.contentRect.height * scale).rounded()))
        }
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = privacy.showsCursor
        configuration.capturesAudio = privacy.capturesAudio
        // Keep StreamMac's own audio out of the stream's app-audio track.
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // Minimal buffering: the consumer throttles, depth only adds latency.
        configuration.queueDepth = 4
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)

        let offMainAudio = onAudioSampleOffMain
        let output = StreamOutputShim(
            onVideoSample: { [weak self] sample in
                Task { @MainActor in self?.onVideoSample?(sample.value) }
            },
            onAudioSample: { [weak self] sample in
                offMainAudio?(sample.value)
                Task { @MainActor in self?.onAudioSample?(sample.value) }
            },
            onStopped: { [weak self] error in
                Task { @MainActor in self?.captureDidStop(error.value) }
            }
        )

        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleQueue)
            if #available(macOS 15.0, *) {
                // Microphone capture through SCStream requires macOS 15; on 14
                // the mic path is MacAudioInput's AVCaptureSession instead.
                try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: sampleQueue)
            }
            self.stream = stream
            self.output = output
            self.activeConfiguration = dynamics != nil ? configuration : nil
            try await stream.startCapture()
            isCapturing = true
            if let dynamics {
                startRegionDynamics(dynamics)
            }
            screenSourceLog.info("ScreenCaptureKit stream started")
        } catch {
            self.stream = nil
            self.output = nil
            self.activeConfiguration = nil
            isCapturing = false
            let nsError = error as NSError
            errorMessage = "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
            screenSourceLog.error("Stream start failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) message=\(nsError.localizedDescription, privacy: .public)")
        }
    }

    /// Starts capturing the concrete target a registry `ScreenSourcePayload`
    /// pins, WITHOUT presenting the picker (S05/C02):
    /// - display: resolves by `CGDirectDisplayID`;
    /// - window: resolves by `CGWindowID`, falling back to a RELINK match on
    ///   the persisted owning-app bundle ID + window title (window IDs are
    ///   volatile — they change when the app relaunches or recreates the
    ///   window). The relinked ID is used for this run only; C10 owns
    ///   persisting relinked identities back to the document;
    /// - application: resolves by bundle identifier and captures the display
    ///   the app's windows sit on, filtered to that app's windows only.
    ///
    /// A pinned target that cannot be resolved sets `errorMessage` and
    /// captures NOTHING — never the first display, never the picker — so a
    /// disconnected display, closed window, or quit app can't silently expose
    /// unrelated desktop content (C02 acceptance).
    ///
    /// C03: `defaults` supplies the global privacy defaults the payload's
    /// per-source options resolve against; the resulting filter excludes the
    /// studio's own windows and the user's excluded apps/windows, and the
    /// configuration carries the effective cursor/audio flags.
    ///
    /// C04 (issue #104): display payloads may carry a region/zoom/tracking
    /// configuration (see the type doc). A stored region is rescaled against
    /// the LIVE display size (its relative geometry persists across
    /// resolution changes); a region that no longer fits the display fails
    /// closed, and so does app tracking whose allowed apps collide with the
    /// privacy exclusion list.
    func start(matching payload: ScreenSourcePayload,
               defaults: StreamSettings = .default) async {
        guard stream == nil, pickerContinuation == nil else { return }
        errorMessage = nil
        let privacy = payload.effectivePrivacy(defaults: defaults)
        do {
            let content = try await SCShareableContent.current
            switch Self.resolve(payload, privacy: privacy, in: content) {
            case .filter(let filter):
                if let conflict = Self.trackingConflict(payload, privacy: privacy) {
                    errorMessage = conflict
                    screenSourceLog.error("App tracking conflicts with privacy: \(conflict, privacy: .public)")
                    return
                }
                let dynamics = Self.regionDynamicsInput(for: payload, privacy: privacy,
                                                        filter: filter, in: content)
                if case .missing(let reason) = dynamics {
                    errorMessage = reason
                    screenSourceLog.error("Region unresolvable: \(reason, privacy: .public)")
                    return
                }
                await start(with: filter, privacy: privacy, dynamics: dynamics.input)
            case .missing(let reason):
                errorMessage = reason
                screenSourceLog.error("Pinned screen source unresolvable: \(reason, privacy: .public)")
            }
        } catch {
            // Most commonly the Screen Recording permission is missing.
            errorMessage = "Screen Recording permission is required. Enable it for StreamMac in System Settings > Privacy & Security > Screen Recording. (\(error.localizedDescription))"
            screenSourceLog.error("Shareable content unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The C04 dynamics input for a pinned display payload, or the fail-closed
    /// reason a stored region can't map onto the live display. Nil input =
    /// no region dynamics (window/app targets, unpinned or plain displays).
    nonisolated private static func regionDynamicsInput(
        for payload: ScreenSourcePayload,
        privacy: EffectiveCapturePrivacy,
        filter: SCContentFilter,
        in content: SCShareableContent) -> RegionDynamicsResolution {
        guard payload.target == .display, payload.hasRegionDynamics,
              let id = payload.targetIdentifier.flatMap({ UInt32($0) }),
              let display = content.displays.first(where: { $0.displayID == id }) else {
            return .input(nil)
        }
        let full = CGRect(origin: .zero, size: display.frame.size)
        var base = full
        if let region = payload.region {
            guard let resolved = resolvedRegion(region, displaySize: display.frame.size) else {
                return .missing("This source's region no longer fits the display (\(Int(display.frame.width))×\(Int(display.frame.height)) points). Edit the region from the Sources tab — capture fails closed rather than capturing the wrong area.")
            }
            base = resolved
        }
        return .input(ScreenRegionDynamicsInput(
            displayID: id,
            displayFrame: display.frame,
            contentRect: filter.contentRect,
            pointScale: CGFloat(filter.pointPixelScale),
            baseRegion: base,
            zoom: payload.zoom,
            tracking: payload.appTracking,
            excludedBundleIDs: privacy.excludedBundleIDs + [studioBundleID]))
    }

    enum RegionDynamicsResolution {
        case input(ScreenRegionDynamicsInput?)
        case missing(String)

        var input: ScreenRegionDynamicsInput? {
            guard case .input(let value) = self else { return nil }
            return value
        }
    }

    /// Rescales a stored region against the live display size (the region is
    /// persisted with the display size at draw time, so its RELATIVE
    /// geometry survives resolution/scale changes), clamped to the display.
    /// Nil when nothing meaningful remains — the defined fallback is
    /// fail-closed, never a re-point.
    nonisolated static func resolvedRegion(_ region: CaptureRegion,
                                           displaySize: CGSize) -> CGRect? {
        guard region.displaySize.width > 0, region.displaySize.height > 0 else { return nil }
        let scaleX = displaySize.width / region.displaySize.width
        let scaleY = displaySize.height / region.displaySize.height
        let rect = CGRect(x: region.rect.minX * scaleX,
                          y: region.rect.minY * scaleY,
                          width: region.rect.width * scaleX,
                          height: region.rect.height * scaleY)
            .intersection(CGRect(origin: .zero, size: displaySize))
        guard rect.width >= 32, rect.height >= 32 else { return nil }
        return rect
    }

    /// C04 fail-closed check: app tracking that follows an app the EFFECTIVE
    /// privacy options exclude can only mean "capture nothing" — error,
    /// never a silent re-point (the C03 contract applied to tracking).
    nonisolated static func trackingConflict(_ payload: ScreenSourcePayload,
                                             privacy: EffectiveCapturePrivacy) -> String? {
        guard payload.appTracking.isEnabled else { return nil }
        let excluded = Set(privacy.excludedBundleIDs)
        guard let conflict = payload.appTracking.allowedBundleIDs
            .first(where: { excluded.contains($0) }) else { return nil }
        return "This source's app tracking follows an app its privacy options exclude (\(conflict)). Remove the exclusion or the tracking entry — capture fails closed rather than re-pointing."
    }

    func stop() async {
        // Dismiss a picker still waiting on this capture (demand dropped
        // mid-presentation), so it can't resume a start nobody wants.
        if let continuation = pickerContinuation {
            pickerContinuation = nil
            picker.isActive = false
            continuation.resume(returning: nil)
        }
        let stream = self.stream
        self.stream = nil
        self.output = nil
        self.activeConfiguration = nil
        regionDynamics?.stop()
        regionDynamics = nil
        isCapturing = false
        if let stream {
            try? await stream.stopCapture()
        }
        screenSourceLog.info("ScreenCaptureKit stream stopped")
    }

    // MARK: - Region dynamics (C04, issue #104)

    /// Wires the region/zoom/tracking controller to the running stream. The
    /// controller pans the crop live; fail-closed tracking stops the capture
    /// with an error (black + error badge, never a silent re-point).
    private func startRegionDynamics(_ input: ScreenRegionDynamicsInput) {
        let controller = ScreenRegionDynamicsController(input: input)
        controller.onCrop = { [weak self] sourceRect, pixelSize in
            Task { @MainActor in self?.applyDynamicCrop(sourceRect, pixelSize: pixelSize) }
        }
        controller.onFailClosed = { [weak self] message in
            Task { @MainActor in self?.trackingDidFailClosed(message) }
        }
        regionDynamics = controller
        controller.start()
    }

    /// Applies a dynamics-computed crop to the running stream through
    /// `updateConfiguration` — zoom/tracking never restart the capture, so
    /// panning costs no flicker and no re-negotiated outputs.
    private func applyDynamicCrop(_ sourceRect: CGRect, pixelSize: CGSize) {
        guard let stream, let configuration = activeConfiguration else { return }
        configuration.sourceRect = sourceRect
        configuration.width = max(2, Int(pixelSize.width))
        configuration.height = max(2, Int(pixelSize.height))
        Task {
            do {
                try await stream.updateConfiguration(configuration)
            } catch {
                screenSourceLog.error("Region/zoom update failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Active-app tracking followed a privacy-excluded app: stop and surface
    /// the fail-closed error. `stop()` doesn't clear `errorMessage`, and the
    /// pool mirrors it into the per-source error badge.
    private func trackingDidFailClosed(_ message: String) {
        errorMessage = message
        screenSourceLog.error("App tracking failed closed: \(message, privacy: .public)")
        Task { await stop() }
    }

    // MARK: - Pinned target resolution (C02, issue #77)

    /// The outcome of pinning a payload to live shareable content: a filter
    /// to capture, or a plain-language reason the target is unavailable.
    enum PinnedResolution {
        case filter(SCContentFilter)
        case missing(String)
    }

    /// Maps a pinned payload to a live `SCContentFilter`. Pure lookup — no
    /// picker, no fallback to unrelated content. `nonisolated` because it
    /// reads only its arguments, so the picker UI can reuse it for previews.
    ///
    /// C03 (issue #78): `privacy` shapes the filter itself, not just the
    /// stream configuration:
    /// - DISPLAY filters always exclude this app's own windows (main window,
    ///   attached sheets, panels) via the app-exclusion filter, which tracks
    ///   windows created AFTER capture start — the studio can never capture
    ///   itself, so no infinite mirror. User-excluded apps ride the same
    ///   filter. Explicit window exclusions force the window-exclusion
    ///   filter instead (ScreenCaptureKit offers no filter combining app-
    ///   and window-level exclusion), with excluded apps resolved to their
    ///   CURRENT windows — a window an excluded app opens after capture
    ///   start is then captured, which the privacy UI documents;
    /// - WINDOW targets that the privacy options themselves exclude fail
    ///   CLOSED (`.missing`, black + error, never a re-point);
    /// - APPLICATION targets exclude the target's own excepted windows, and
    ///   excluding the target app itself likewise fails closed.
    nonisolated static func resolve(_ payload: ScreenSourcePayload,
                                    privacy: EffectiveCapturePrivacy,
                                    in content: SCShareableContent) -> PinnedResolution {
        switch payload.target {
        case .display:
            guard let id = payload.targetIdentifier.flatMap({ UInt32($0) }),
                  let display = content.displays.first(where: { $0.displayID == id }) else {
                return .missing("The display this source captures is not connected. Reconnect it, or change the source's target from the Sources tab.")
            }
            return .filter(displayFilter(for: display, privacy: privacy, in: content))
        case .window:
            if let id = payload.targetIdentifier.flatMap({ UInt32($0) }),
               let window = content.windows.first(where: { $0.windowID == id }) {
                return windowFilter(window, privacy: privacy)
            }
            // Relink: `CGWindowID` is volatile, so a stale ID falls back to
            // the persisted owning app + title. The match is intentionally
            // exact on title — a fuzzy match could capture the WRONG window.
            if let bundleID = payload.applicationBundleID {
                let candidates = content.windows.filter {
                    $0.owningApplication?.bundleIdentifier == bundleID
                }
                let relinked: SCWindow?
                if let title = payload.windowTitle, !title.isEmpty {
                    relinked = candidates.first(where: { $0.title == title })
                } else {
                    relinked = candidates.first
                }
                if let relinked {
                    screenSourceLog.info("Relinked window source by owning app + title (new windowID=\(relinked.windowID, privacy: .public))")
                    return windowFilter(relinked, privacy: privacy)
                }
            }
            return .missing("The window this source captures is no longer open. Reopen it, or change the source's target from the Sources tab.")
        case .application:
            guard let bundleID = payload.targetIdentifier ?? payload.applicationBundleID,
                  let application = content.applications.first(where: { $0.bundleIdentifier == bundleID })
            else {
                return .missing("The application this source captures is not running. Launch it, or change the source's target from the Sources tab.")
            }
            // C03 fail-closed: excluding the target app itself can only mean
            // "capture nothing" — error, never a re-point to other content.
            if privacy.excludedBundleIDs.contains(bundleID) {
                return .missing("This source's privacy options exclude \(application.applicationName), which is also its target. Remove the exclusion, or change the source's target.")
            }
            // ScreenCaptureKit has no app-only filter; capture the display
            // the app's windows sit on, filtered down to that app's windows.
            let windows = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == bundleID
            }
            guard let display = displayHosting(windows, in: content) else {
                return .missing("\(application.applicationName) has no open windows to capture. Open a window, or change the source's target.")
            }
            // C03: explicit window exclusions of the TARGET app become the
            // filter's excepted windows (exclusions of other apps are moot —
            // the filter only includes this app's windows in the first place).
            let excepted = resolveExcludedWindows(privacy.excludedWindows, in: content)
                .filter { $0.owningApplication?.bundleIdentifier == bundleID }
            return .filter(SCContentFilter(display: display, including: [application], exceptingWindows: excepted))
        }
    }

    /// The window-target filter, or a fail-closed `.missing` when the
    /// source's privacy options exclude the very window it pins (C03).
    nonisolated private static func windowFilter(_ window: SCWindow,
                                                 privacy: EffectiveCapturePrivacy) -> PinnedResolution {
        let owner = window.owningApplication?.bundleIdentifier
        if let owner, privacy.excludedBundleIDs.contains(owner) {
            return .missing("This source's privacy options exclude the app that owns its pinned window. Remove the exclusion, or change the source's target.")
        }
        let excludedIDs = Set(privacy.excludedWindows.compactMap { UInt32($0.windowID) })
        // Match by ID, or by the owning-app + title relink key — a window
        // recreated after the exclusion was stored has a new ID.
        let excludedByIdentity = excludedIDs.contains(window.windowID)
            || privacy.excludedWindows.contains { exclusion in
                exclusion.applicationBundleID == owner
                    && exclusion.windowTitle != nil
                    && exclusion.windowTitle == window.title
            }
        if excludedByIdentity {
            return .missing("This source's privacy options exclude its pinned window. Remove the exclusion, or change the source's target.")
        }
        return .filter(SCContentFilter(desktopIndependentWindow: window))
    }

    /// The C03 display filter. App-level exclusions (the studio's own app,
    /// ALWAYS, plus the user's excluded apps) use the app-exclusion filter,
    /// which keeps excluding windows those apps create AFTER capture start.
    /// Explicit window exclusions require the window-exclusion filter (no
    /// SCContentFilter combines both), so excluded apps are then resolved to
    /// their current windows — see the `resolve` doc for the tradeoff.
    nonisolated private static func displayFilter(for display: SCDisplay,
                                                  privacy: EffectiveCapturePrivacy,
                                                  in content: SCShareableContent) -> SCContentFilter {
        let excludedBundleIDs = Set(privacy.excludedBundleIDs + [studioBundleID])
        let excludedApps = content.applications.filter {
            excludedBundleIDs.contains($0.bundleIdentifier)
        }
        let explicitWindows = resolveExcludedWindows(privacy.excludedWindows, in: content)
        guard !explicitWindows.isEmpty else {
            return SCContentFilter(display: display,
                                   excludingApplications: excludedApps,
                                   exceptingWindows: [])
        }
        let excludedWindows = content.windows.filter { window in
            guard let owner = window.owningApplication?.bundleIdentifier else { return false }
            return excludedBundleIDs.contains(owner)
        } + explicitWindows
        return SCContentFilter(display: display, excludingWindows: excludedWindows)
    }

    /// Resolves persisted window exclusions against live shareable content:
    /// by window ID first, then by the owning-app + title relink key (window
    /// IDs are volatile, same as pinned window targets).
    nonisolated static func resolveExcludedWindows(
        _ exclusions: [CapturePrivacyOptions.ExcludedWindow],
        in content: SCShareableContent) -> [SCWindow] {
        exclusions.compactMap { exclusion in
            if let id = UInt32(exclusion.windowID),
               let window = content.windows.first(where: { $0.windowID == id }) {
                return window
            }
            guard let bundleID = exclusion.applicationBundleID else { return nil }
            let candidates = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == bundleID
            }
            if let title = exclusion.windowTitle, !title.isEmpty {
                return candidates.first(where: { $0.title == title })
            }
            return nil
        }
    }

    /// This app's own bundle identifier. Display filters always exclude it,
    /// so the studio's main window, sheets, and panels can never be captured
    /// by a display source (no infinite mirror). Resolved once from the main
    /// bundle, falling back to the identifier `project.yml` bakes in.
    nonisolated static let studioBundleID =
        Bundle.main.bundleIdentifier ?? "com.joeblau.StreamMac"

    /// The display with the largest overlap of any of `windows` — where the
    /// app visually "is". Nil when the app has no on-screen windows.
    nonisolated private static func displayHosting(_ windows: [SCWindow],
                                                   in content: SCShareableContent) -> SCDisplay? {
        var best: (display: SCDisplay, area: CGFloat)?
        for window in windows {
            for display in content.displays {
                let overlap = display.frame.intersection(window.frame)
                guard !overlap.isNull else { continue }
                let area = overlap.width * overlap.height
                if area > (best?.area ?? 0) {
                    best = (display, area)
                }
            }
        }
        return best?.display
    }

    // MARK: - Picker

    private func pickerDidCancel() {
        guard let continuation = pickerContinuation else { return }
        pickerContinuation = nil
        screenSourceLog.info("Content-sharing picker cancelled")
        continuation.resume(returning: nil)
    }

    private func pickerDidSelect(_ filter: SCContentFilter) {
        guard let continuation = pickerContinuation else { return }
        pickerContinuation = nil
        screenSourceLog.info("Picker selected content: rect=\(String(describing: filter.contentRect), privacy: .public) scale=\(filter.pointPixelScale, privacy: .public)")
        continuation.resume(returning: UncheckedSendableBox(filter))
    }

    private func pickerDidFail(_ error: NSError) {
        pickerStartFailed = true
        guard let continuation = pickerContinuation else { return }
        pickerContinuation = nil
        screenSourceLog.error("Picker failed: domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public) message=\(error.localizedDescription, privacy: .public)")
        continuation.resume(returning: nil)
    }

    // MARK: - Stream delegate

    private func captureDidStop(_ error: NSError) {
        isCapturing = false
        stream = nil
        output = nil
        activeConfiguration = nil
        regionDynamics?.stop()
        regionDynamics = nil
        screenSourceLog.error("Capture stopped: domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public) message=\(error.localizedDescription, privacy: .public)")
        if error.code != SCStreamError.Code.userStopped.rawValue {
            errorMessage = "\(error.localizedDescription) (\(error.domain) \(error.code))"
        }
    }
}

/// ScreenCaptureKit's observer/delegate callbacks arrive on framework queues
/// and its reference types aren't Sendable. The box transfers callback values
/// across the MainActor hop without actor-assuming thunks.
private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// Forwards `SCContentSharingPickerObserver` callbacks (arbitrary thread) into
/// MainActor closures.
private final class PickerObserverShim: NSObject, SCContentSharingPickerObserver,
                                        @unchecked Sendable {
    private let onCancel: @Sendable () -> Void
    private let onFilter: @Sendable (UncheckedSendableBox<SCContentFilter>) -> Void
    private let onFailure: @Sendable (UncheckedSendableBox<NSError>) -> Void

    init(onCancel: @escaping @Sendable () -> Void,
         onFilter: @escaping @Sendable (UncheckedSendableBox<SCContentFilter>) -> Void,
         onFailure: @escaping @Sendable (UncheckedSendableBox<NSError>) -> Void) {
        self.onCancel = onCancel
        self.onFilter = onFilter
        self.onFailure = onFailure
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
                                          didCancelFor stream: SCStream?) {
        onCancel()
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
                                          didUpdateWith filter: SCContentFilter,
                                          for stream: SCStream?) {
        onFilter(UncheckedSendableBox(filter))
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        onFailure(UncheckedSendableBox(error as NSError))
    }
}

/// Receives SCStream sample buffers on the serial sample queue and forwards
/// them (boxed) into MainActor closures.
private final class StreamOutputShim: NSObject, SCStreamOutput, SCStreamDelegate,
                                      @unchecked Sendable {
    private let onVideoSample: @Sendable (UncheckedSendableBox<CMSampleBuffer>) -> Void
    private let onAudioSample: @Sendable (UncheckedSendableBox<CMSampleBuffer>) -> Void
    private let onStopped: @Sendable (UncheckedSendableBox<NSError>) -> Void

    init(onVideoSample: @escaping @Sendable (UncheckedSendableBox<CMSampleBuffer>) -> Void,
         onAudioSample: @escaping @Sendable (UncheckedSendableBox<CMSampleBuffer>) -> Void,
         onStopped: @escaping @Sendable (UncheckedSendableBox<NSError>) -> Void) {
        self.onVideoSample = onVideoSample
        self.onAudioSample = onAudioSample
        self.onStopped = onStopped
    }

    nonisolated func stream(_ stream: SCStream,
                            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, sampleBuffer.dataReadiness == .ready else { return }
        switch type {
        case .screen:
            onVideoSample(UncheckedSendableBox(sampleBuffer))
        case .audio:
            onAudioSample(UncheckedSendableBox(sampleBuffer))
        default:
            // SCStreamOutputType.microphone is macOS 15+; matching it by name in
            // a case pattern would break the macOS 14 deployment target.
            if #available(macOS 15.0, *), type == .microphone {
                onAudioSample(UncheckedSendableBox(sampleBuffer))
            }
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStopped(UncheckedSendableBox(error as NSError))
    }
}
