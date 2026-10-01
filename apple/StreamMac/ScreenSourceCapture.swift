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
/// display, window, or application; when the picker cannot present or report a
/// selection (e.g. headless runs) it falls back to capturing the first display.
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
    /// picker only appears when no selection exists yet. Falls back to the
    /// first display when the picker fails to start; a user cancel simply
    /// leaves capture off.
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
            await startWithFirstDisplay()
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
    /// pins, WITHOUT presenting the picker (S05): displays resolve by
    /// `CGDirectDisplayID`, windows by `CGWindowID`. An unresolvable target —
    /// the display/window is gone, or an application target, which has no
    /// stable restorable identifier yet — falls back to the remembered
    /// selection or the picker so the user can re-point the source.
    func start(matching payload: ScreenSourcePayload) async {
        guard stream == nil, pickerContinuation == nil else { return }
        do {
            let content = try await SCShareableContent.current
            switch payload.target {
            case .display:
                if let id = payload.targetIdentifier.flatMap({ UInt32($0) }),
                   let display = content.displays.first(where: { $0.displayID == id }) {
                    await start(with: SCContentFilter(display: display, excludingWindows: []))
                    return
                }
            case .window:
                if let id = payload.targetIdentifier.flatMap({ UInt32($0) }),
                   let window = content.windows.first(where: { $0.windowID == id }) {
                    await start(with: SCContentFilter(desktopIndependentWindow: window))
                    return
                }
            case .application:
                break
            }
        } catch {
            // Most commonly the Screen Recording permission is missing.
            errorMessage = "Screen Recording permission is required. Enable it for StreamMac in System Settings > Privacy & Security > Screen Recording. (\(error.localizedDescription))"
            screenSourceLog.error("Shareable content unavailable: \(error.localizedDescription, privacy: .public)")
            return
        }
        await pickAndStart()
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

    // MARK: - Picker

    private func startWithFirstDisplay() async {
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else {
                errorMessage = "No display is available to capture."
                return
            }
            await start(with: SCContentFilter(display: display, excludingWindows: []))
        } catch {
            // Most commonly the Screen Recording permission is missing.
            errorMessage = "Screen Recording permission is required. Enable it for StreamMac in System Settings > Privacy & Security > Screen Recording. (\(error.localizedDescription))"
            screenSourceLog.error("Shareable content unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

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
