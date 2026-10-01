import AppKit
import Combine
import CoreMedia
import ScreenCaptureKit
import StreamCore
import os

private let appAudioLog = Logger(subsystem: "com.joeblau.StreamMac", category: "app-audio-capture")

/// A06 (issue #118): audio-only capture of one application or the
/// whole-system mix, INDEPENDENT of any screen/video scene. An app-audio
/// source captures while it is registered and enabled — scene switches,
/// Takes, and layer visibility never start or stop it (demand is gated only
/// by the W02 pipeline, through `CaptureSourcePool`).
///
/// **Capture path.** ScreenCaptureKit, with an audio-only `SCStream` (a
/// minimal 2×2 @ 1 fps video configuration rides along so the stream
/// satisfies the video requirement on every macOS 14.x point release; the
/// output shim discards those frames). This is the verified path on the
/// macOS 14.0 deployment target for BOTH modes:
/// - per-app: an including-apps `SCContentFilter` pins the stream's audio to
///   exactly the target app — a per-app source can never pull another app's
///   audio (fail closed by construction), and the studio itself is rejected
///   as a target outright;
/// - system mix: an excluding-apps filter over the whole display, always
///   with `excludesCurrentProcessAudio = true` AND the studio app in the
///   exclusion list (belt and braces), plus every app carrying its own
///   enabled app-audio source and the user's global privacy exclusions, so
///   system + per-app (and privacy-excluded apps) never double up.
///
/// The issue's alternative — Core Audio process taps — is gated to macOS
/// 14.2+ and needs the separate audio-capture TCC grant; the ScreenCaptureKit
/// path is the explicit, supported fallback that already covers macOS
/// 14.0/14.1 (and later) under the existing Screen Recording permission, so
/// no second prompt or runtime fork is introduced. Permission state rides
/// the W06 surface: a `SCShareableContent` failure reports the Screen
/// Recording repair guidance here, and the pool's error hook re-probes
/// permission on mid-capture stops (same contract as screen sources).
///
/// **Lifecycle.** App quit/relaunch is the C10 pattern with
/// `RunningApplicationMonitor` as the hot-plug signal: the pool marks the
/// source MISSING on terminate (registry entry and enablement survive) and
/// restarts capture automatically when the same bundle ID relaunches.
@MainActor
final class AppAudioCapture: ObservableObject {
    @Published private(set) var isCapturing = false
    /// Human-readable description of the last failure (Screen Recording
    /// permission denial, unresolvable target, start failure, or a
    /// mid-capture stop).
    @Published private(set) var errorMessage: String?

    /// Real-time audio hand-off that fires DIRECTLY on the SCStream sample
    /// queue — no main-actor hop — so the A01 engine's format conversion
    /// never runs on the main thread (the `ScreenSourceCapture` contract).
    var onAudioSampleOffMain: (@Sendable (CMSampleBuffer) -> Void)?

    private var stream: SCStream?
    private var output: AppAudioOutputShim?
    /// Serial queue for all SCStream sample callbacks.
    private let sampleQueue = DispatchQueue(label: "com.joeblau.StreamMac.app-audio.samples",
                                            qos: .userInitiated)

    /// Starts (or restarts) capturing the payload's target. `excludingBundleIDs`
    /// applies to the SYSTEM mix only: apps that carry their own per-app
    /// source plus the global privacy exclusions (the studio is always
    /// excluded, on top). An unresolvable target sets `errorMessage` and
    /// captures NOTHING — never a substitution (fail closed, C02-style).
    func start(with payload: AppAudioSourcePayload,
               excludingBundleIDs: Set<String> = []) async {
        if stream != nil { await stop() }
        errorMessage = nil
        do {
            let content = try await SCShareableContent.current
            switch Self.filter(for: payload, excluding: excludingBundleIDs, in: content) {
            case .filter(let filter):
                await startStream(with: filter)
            case .failed(let reason):
                errorMessage = reason
                appAudioLog.error("App-audio target unresolvable: \(reason, privacy: .public)")
            }
        } catch {
            // Most commonly the Screen Recording permission is missing.
            errorMessage = "Screen Recording permission is required to capture app audio. Enable it for StreamMac in System Settings > Privacy & Security > Screen Recording. (\(error.localizedDescription))"
            appAudioLog.error("Shareable content unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() async {
        let stream = self.stream
        self.stream = nil
        self.output = nil
        isCapturing = false
        if let stream {
            try? await stream.stopCapture()
        }
        appAudioLog.info("App-audio stream stopped")
    }

    // MARK: - Filter resolution (fail closed)

    enum FilterResolution {
        case filter(SCContentFilter)
        case failed(String)
    }

    /// Maps a payload to a live `SCContentFilter`. Pure lookup — no fallback
    /// to other content, ever. `nonisolated` because it reads only its
    /// arguments (same contract as `ScreenSourceCapture.resolve`).
    nonisolated static func filter(for payload: AppAudioSourcePayload,
                                   excluding excludingBundleIDs: Set<String>,
                                   in content: SCShareableContent) -> FilterResolution {
        // The audio-only stream still anchors on a display for the (minimal)
        // video configuration ScreenCaptureKit requires.
        guard let display = content.displays.first else {
            return .failed("No display is connected to anchor the audio capture.")
        }
        switch payload.mode {
        case .application:
            guard let bundleID = payload.bundleID else {
                return .failed("This app-audio source has no application configured. Pick one from the Sources tab.")
            }
            // Fail closed: the studio can never be an app-audio target — its
            // own audio must never enter the program mix through a source.
            guard bundleID != ScreenSourceCapture.studioBundleID else {
                return .failed("StreamMac can't capture its own audio as an app source. Pick a different application.")
            }
            guard let application = content.applications
                .first(where: { $0.bundleIdentifier == bundleID }) else {
                return .failed("\(payload.displayTitle) is not running. Launch it — capture resumes automatically, or relink the source to another app.")
            }
            // The including-apps filter pins BOTH video and audio to exactly
            // this app: a per-app source can never pull another app's audio.
            return .filter(SCContentFilter(display: display,
                                           including: [application],
                                           exceptingWindows: []))
        case .system:
            // The system mix excludes the studio (the configuration's
            // `excludesCurrentProcessAudio` is the second line of defense)
            // plus every app carrying its own enabled app-audio source, so
            // system + per-app capture of the same app never doubles.
            let excludedIDs = excludingBundleIDs.union([ScreenSourceCapture.studioBundleID])
            let excludedApps = content.applications.filter {
                excludedIDs.contains($0.bundleIdentifier)
            }
            return .filter(SCContentFilter(display: display,
                                           excludingApplications: excludedApps,
                                           exceptingWindows: []))
        }
    }

    // MARK: - Stream lifecycle

    private func startStream(with filter: SCContentFilter) async {
        let configuration = SCStreamConfiguration()
        // Audio-only: the smallest legal video configuration, 2×2 at 1 fps.
        // The screen output is registered (some macOS 14 point releases
        // refuse a stream with no video output) and its frames are dropped
        // in the shim — a 2×2 frame once per second costs nothing.
        configuration.width = 2
        configuration.height = 2
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        configuration.capturesAudio = true
        // The studio's own audio NEVER enters an app-audio capture.
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.queueDepth = 4

        let offMainAudio = onAudioSampleOffMain
        let output = AppAudioOutputShim(
            onAudioSample: { sample in
                offMainAudio?(sample.value)
            },
            onStopped: { [weak self] error in
                Task { @MainActor in self?.captureDidStop(error.value) }
            }
        )

        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleQueue)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
            self.stream = stream
            self.output = output
            try await stream.startCapture()
            isCapturing = true
            appAudioLog.info("App-audio stream started")
        } catch {
            self.stream = nil
            self.output = nil
            isCapturing = false
            let nsError = error as NSError
            errorMessage = "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
            appAudioLog.error("App-audio stream start failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) message=\(nsError.localizedDescription, privacy: .public)")
        }
    }

    private func captureDidStop(_ error: NSError) {
        isCapturing = false
        stream = nil
        output = nil
        appAudioLog.error("App-audio capture stopped: domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public) message=\(error.localizedDescription, privacy: .public)")
        if error.code != SCStreamError.Code.userStopped.rawValue {
            errorMessage = "\(error.localizedDescription) (\(error.domain) \(error.code))"
        }
    }
}

/// Boxes ScreenCaptureKit callback values across the MainActor hop (the
/// framework's reference types aren't Sendable) — the same shim pattern
/// `ScreenSourceCapture` uses.
private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// Receives SCStream sample buffers on the serial sample queue. Audio buffers
/// forward (boxed) to the off-main hand-off; the minimal video frames an
/// audio-only stream still emits are dropped on the floor.
private final class AppAudioOutputShim: NSObject, SCStreamOutput, SCStreamDelegate,
                                        @unchecked Sendable {
    private let onAudioSample: @Sendable (UncheckedSendableBox<CMSampleBuffer>) -> Void
    private let onStopped: @Sendable (UncheckedSendableBox<NSError>) -> Void

    init(onAudioSample: @escaping @Sendable (UncheckedSendableBox<CMSampleBuffer>) -> Void,
         onStopped: @escaping @Sendable (UncheckedSendableBox<NSError>) -> Void) {
        self.onAudioSample = onAudioSample
        self.onStopped = onStopped
    }

    nonisolated func stream(_ stream: SCStream,
                            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .audio,
              sampleBuffer.isValid, sampleBuffer.dataReadiness == .ready else { return }
        onAudioSample(UncheckedSendableBox(sampleBuffer))
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStopped(UncheckedSendableBox(error as NSError))
    }
}

/// A06: the running-app directory — both the app picker list in the Sources
/// tab and the C10-style hot-plug signal for app-audio sources (an app
/// quitting marks its source MISSING; the same bundle ID relaunching
/// restarts capture automatically). No TCC permission is needed to list
/// running applications, so this check works even before Screen Recording
/// is granted.
@MainActor
final class RunningApplicationMonitor: ObservableObject {
    /// One capturable app (a regular UI application with a bundle ID, minus
    /// the studio itself).
    struct AudioApp: Identifiable, Hashable, Sendable {
        var bundleID: String
        var name: String
        var id: String { bundleID }
    }

    /// Bundle IDs of every regular UI application currently running.
    @Published private(set) var runningBundleIDs: Set<String> = []
    /// The picker's app list, sorted by display name.
    @Published private(set) var audioApps: [AudioApp] = []

    /// `nonisolated(unsafe)` so `deinit` can unregister them (the monitor
    /// lives for the app's lifetime; belt-and-braces, the SceneStore pattern).
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    deinit {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func refresh() {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
        runningBundleIDs = Set(apps.compactMap(\.bundleIdentifier))
        audioApps = apps.compactMap { app in
            guard let bundleID = app.bundleIdentifier,
                  bundleID != ScreenSourceCapture.studioBundleID else { return nil }
            return AudioApp(bundleID: bundleID,
                            name: app.localizedName ?? bundleID)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
