import Combine
import CoreMedia
import ScreenCaptureKit
import os

private let screenSourceLog = Logger(subsystem: "com.joeblau.StreamMac", category: "screen-source-capture")

/// Owns the macOS ScreenCaptureKit capture flow: the system content-sharing
/// picker, the SCStream lifecycle, and forwarding of screen/app-audio/mic
/// sample buffers to the publisher layer.
///
/// `pickAndStart()` presents `SCContentSharingPicker` for the user to choose a
/// display, window, or application (the DEFAULT, unpinned source path).
/// `start(matching:)` silently resolves a registry `ScreenSourcePayload`'s
/// pinned display (`CGDirectDisplayID`), window (`CGWindowID`, with an
/// owning-app + title relink fallback — window IDs are volatile), or
/// application (bundle identifier) target. A pinned target that cannot be
/// resolved surfaces an error and captures NOTHING: it never falls back to
/// the first display or an arbitrary window, so a missing source can never
/// expose unrelated desktop content (C02, issue #77).
/// `start(with:)` accepts a filter directly for callers that already know what
/// to capture.
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

    private let picker = SCContentSharingPicker.shared
    private var pickerObserver: PickerObserverShim?
    private var pickerContinuation: CheckedContinuation<UncheckedSendableBox<SCContentFilter>?, Never>?
    private var pickerStartFailed = false
    /// The filter the user last picked (or a fallback resolved to), reused on
    /// restart so an unchanged source never re-presents the picker (S05).
    private var lastFilter: SCContentFilter?
    private var stream: SCStream?
    private var output: StreamOutputShim?
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
    func pickAndStart() async {
        guard stream == nil, pickerContinuation == nil else { return }
        errorMessage = nil
        if let lastFilter {
            await start(with: lastFilter)
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
            await start(with: selection.value)
        } else if pickerStartFailed {
            errorMessage = "The content-sharing picker could not be presented. Add a screen source from the Sources tab instead, or try again."
        }
    }

    /// Starts capturing the content described by `filter` — display, window, or
    /// application — with audio from the captured apps and the microphone.
    func start(with filter: SCContentFilter) async {
        if stream != nil { await stop() }
        errorMessage = nil
        lastFilter = filter

        let configuration = SCStreamConfiguration()
        // Native pixel size of the picked content; never hardcoded.
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = max(2, Int((filter.contentRect.width * scale).rounded()))
        configuration.height = max(2, Int((filter.contentRect.height * scale).rounded()))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.capturesAudio = true
        // Keep StreamMac's own audio out of the stream's app-audio track.
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // Minimal buffering: the consumer throttles, depth only adds latency.
        configuration.queueDepth = 4
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)

        let output = StreamOutputShim(
            onVideoSample: { [weak self] sample in
                Task { @MainActor in self?.onVideoSample?(sample.value) }
            },
            onAudioSample: { [weak self] sample in
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
            try await stream.startCapture()
            isCapturing = true
            screenSourceLog.info("ScreenCaptureKit stream started")
        } catch {
            self.stream = nil
            self.output = nil
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
    func start(matching payload: ScreenSourcePayload) async {
        guard stream == nil, pickerContinuation == nil else { return }
        errorMessage = nil
        do {
            let content = try await SCShareableContent.current
            switch Self.resolve(payload, in: content) {
            case .filter(let filter):
                await start(with: filter)
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
        isCapturing = false
        if let stream {
            try? await stream.stopCapture()
        }
        screenSourceLog.info("ScreenCaptureKit stream stopped")
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
    nonisolated static func resolve(_ payload: ScreenSourcePayload,
                                    in content: SCShareableContent) -> PinnedResolution {
        switch payload.target {
        case .display:
            if let id = payload.targetIdentifier.flatMap({ UInt32($0) }),
               let display = content.displays.first(where: { $0.displayID == id }) {
                return .filter(SCContentFilter(display: display, excludingWindows: []))
            }
            return .missing("The display this source captures is not connected. Reconnect it, or change the source's target from the Sources tab.")
        case .window:
            if let id = payload.targetIdentifier.flatMap({ UInt32($0) }),
               let window = content.windows.first(where: { $0.windowID == id }) {
                return .filter(SCContentFilter(desktopIndependentWindow: window))
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
                    return .filter(SCContentFilter(desktopIndependentWindow: relinked))
                }
            }
            return .missing("The window this source captures is no longer open. Reopen it, or change the source's target from the Sources tab.")
        case .application:
            guard let bundleID = payload.targetIdentifier ?? payload.applicationBundleID,
                  let application = content.applications.first(where: { $0.bundleIdentifier == bundleID })
            else {
                return .missing("The application this source captures is not running. Launch it, or change the source's target from the Sources tab.")
            }
            // ScreenCaptureKit has no app-only filter; capture the display
            // the app's windows sit on, filtered down to that app's windows.
            let windows = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == bundleID
            }
            guard let display = displayHosting(windows, in: content) else {
                return .missing("\(application.applicationName) has no open windows to capture. Open a window, or change the source's target.")
            }
            return .filter(SCContentFilter(display: display, including: [application], exceptingWindows: []))
        }
    }

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
