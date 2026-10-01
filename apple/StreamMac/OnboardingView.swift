import AppKit
import SwiftUI

/// The first-run setup guide (W06, issue #69): an attached sheet in the
/// studio window that walks a new broadcaster through camera, microphone, and
/// screen-capture permissions JUST IN TIME (each with its purpose copy shown
/// before the OS prompt), then builds a sample scene, runs the preview, and
/// guides a 5-second local test recording — all before any streaming account
/// or destination is required. Destination setup is offered last and is
/// skippable; choosing it jumps straight to the settings pane's Connection
/// section via `SettingsSession`.
///
/// The flow is presented by `MainWindowView` only while the persisted
/// first-run flag is incomplete, and every permission step is skippable:
/// anything denied here keeps a repair action in the settings pane's
/// Application section (and a just-in-time explainer when the matching
/// source is next used — see `JustInTimePermissionSheet`).
struct OnboardingView: View {
    @EnvironmentObject private var permissions: PermissionsManager
    @EnvironmentObject private var sceneStore: SceneStore
    @EnvironmentObject private var controller: StreamController
    @EnvironmentObject private var session: SettingsSession
    /// The shell's recorder, so the guided test recording uses the same
    /// pipeline state as the transport bar.
    @ObservedObject var recorder: RecordingController
    /// Marks first run complete (and closes the sheet).
    let onFinish: () -> Void

    @State private var step = Step.welcome
    /// Name of the sample scene this flow created, once created.
    @State private var sampleSceneName: String?

    private enum Step: Int, CaseIterable {
        case welcome, camera, microphone, screenCapture, sampleScene, testRecording, destination

        var title: String {
            switch self {
            case .welcome: return "Welcome to Stream"
            case .camera: return "Camera"
            case .microphone: return "Microphone"
            case .screenCapture: return "Screen Capture"
            case .sampleScene: return "Your First Scene"
            case .testRecording: return "Test Recording"
            case .destination: return "Destination (Optional)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)
            Divider()
            navigationBar
        }
        .frame(width: 560, height: 420)
    }

    private var header: some View {
        HStack {
            Text(step.title)
                .font(.headline)
            Spacer()
            Text("Step \(step.rawValue + 1) of \(Step.allCases.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    // MARK: - Steps

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            VStack(alignment: .leading, spacing: 12) {
                Text("Let's get your studio ready.")
                    .font(.title3.weight(.semibold))
                Text("Stream will ask for each capture permission only when you reach the feature that needs it, and explain why first. By the end of this guide you'll have a working scene, a live preview, and a 5-second local test recording — no streaming account needed.")
                    .foregroundStyle(.secondary)
                Text("You can skip any step; anything you skip stays fixable later in Settings > Application.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .camera:
            PermissionStatusCard(kind: .camera)
        case .microphone:
            PermissionStatusCard(kind: .microphone)
        case .screenCapture:
            PermissionStatusCard(kind: .screenCapture)
        case .sampleScene:
            sampleSceneStep
        case .testRecording:
            testRecordingStep
        case .destination:
            destinationStep
        }
    }

    private var sampleSceneStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create a sample scene from the sources you just enabled — a screen capture with a camera overlay when both are available, or a camera/screen solo scene otherwise. The preview starts right away.")
                .foregroundStyle(.secondary)
            if let sampleSceneName {
                Label("Created \"\(sampleSceneName)\" and selected it — the preview is running in the canvas behind this sheet.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Create Sample Scene", action: createSampleScene)
                    .buttonStyle(.borderedProminent)
            }
            if permissions.status(for: .screenCapture) == .granted {
                Text("macOS may show the content picker so you can choose which display or window to capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var testRecordingStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prove the whole pipeline end-to-end with a local recording — no destination, no account. Record about 5 seconds, then stop.")
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    recorder.toggle(stream: controller)
                } label: {
                    Label(recorder.state.isRecording ? "Stop Recording" : "Start Recording",
                          systemImage: recorder.state.isRecording ? "stop.circle.fill" : "record.circle")
                }
                .tint(recorder.state.isRecording ? .red : nil)
                .disabled(recorder.state == .stopping)

                if recorder.state.isRecording {
                    Label("Recording… stop after ~5 seconds.", systemImage: "record.circle")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            if let url = recorder.lastRecordingURL {
                Label("Saved: \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Reveal in Finder", systemImage: "film")
                }
            } else if let error = recorder.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            } else {
                Text("The finished clip lands in the app's shared Recordings folder; the diagnostics strip in the studio window links to it too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var destinationStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Everything so far works without an account. When you're ready to go live, add a destination (Restream, or any RTMP/SRT/WHIP endpoint) in the settings pane — it opens at the Connection section.")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Set Up Destination…") {
                    onFinish()
                    session.showSettings(section: .connection)
                }
                .buttonStyle(.borderedProminent)
                Button("Skip for Now", action: onFinish)
            }
            Text("You can reopen this anytime from Settings (⌘,).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Navigation

    private var navigationBar: some View {
        HStack {
            if step == .welcome {
                Button("Skip Setup", action: onFinish)
            } else {
                Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
            }
            Spacer()
            switch step {
            case .welcome, .camera, .microphone, .screenCapture:
                Button("Continue") { advance() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .sampleScene:
                Button("Continue") { advance() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(sampleSceneName == nil)
            case .testRecording:
                Button(recorder.lastRecordingURL == nil ? "Skip Recording" : "Continue") { advance() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(recorder.state.isRecording || recorder.state == .stopping)
            case .destination:
                EmptyView()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private func advance() {
        step = Step(rawValue: step.rawValue + 1) ?? step
    }

    // MARK: - Sample scene

    /// Builds the sample scene through the existing `Scene` factories (S01)
    /// and `SceneStore`, picking the layout the granted permissions can
    /// actually show. Selecting it routes the sources through the normal
    /// scene pipeline, so the preview starts capturing immediately.
    private func createSampleScene() {
        let cameraGranted = permissions.status(for: .camera) == .granted
        let screenGranted = permissions.status(for: .screenCapture) == .granted
        let scene: Scene
        switch (cameraGranted, screenGranted) {
        case (true, true):
            scene = .screenPlusCam(name: "Sample: Screen + Cam")
        case (true, false):
            scene = .cameraSolo(name: "Sample: Camera")
        case (false, true):
            scene = .screenSolo(name: "Sample: Screen")
        case (false, false):
            // Neither granted yet: still build the full sample so its repair
            // states are visible the moment permissions are fixed.
            scene = .screenPlusCam(name: "Sample: Screen + Cam")
        }
        sceneStore.addScene(scene)
        sampleSceneName = scene.name
        controller.startPreview()
    }
}

/// The shared permission explainer/repair card (W06): purpose copy, current
/// status, and the one right action — "Allow …" while the OS prompt can still
/// be shown, "Open System Settings…" once denied (the OS never re-prompts).
/// Used by the onboarding steps and the just-in-time permission sheet, and
/// reusable from any source panel's repair state.
struct PermissionStatusCard: View {
    @EnvironmentObject private var permissions: PermissionsManager
    let kind: PermissionsManager.Kind

    var body: some View {
        let status = permissions.status(for: kind)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: kind.symbolName)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text(kind.title)
                    .font(.title3.weight(.semibold))
                Spacer()
                statusBadge(status)
            }

            Text(permissions.repairAction(for: kind)?.message ?? kind.purpose)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                switch status {
                case .needsRequest:
                    Button("Allow \(kind.title)…") {
                        Task { await permissions.request(kind) }
                    }
                    .buttonStyle(.borderedProminent)
                case .denied:
                    Button("Open System Settings…") {
                        permissions.openSystemSettings(for: kind)
                    }
                    .buttonStyle(.borderedProminent)
                case .granted:
                    Label("You're all set.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private func statusBadge(_ status: PermissionsManager.Status) -> some View {
        let (text, color): (String, Color)
        switch status {
        case .granted: (text, color) = ("Granted", .green)
        case .needsRequest: (text, color) = ("Not Set Up", .secondary)
        case .denied: (text, color) = ("Denied", .orange)
        }
        return Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// The just-in-time permission explainer (W06): shown in the main window the
/// moment a source whose permission is missing is first used — e.g. selecting
/// a camera scene with camera access not yet granted. It explains the purpose
/// and offers the request, or — once denied — the System Settings repair
/// action, so a denial is never a silent black source.
struct JustInTimePermissionSheet: View {
    @EnvironmentObject private var permissions: PermissionsManager
    let kind: PermissionsManager.Kind
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(kind.title) Needed")
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            PermissionStatusCard(kind: kind)
                .padding(20)
            Divider()
            HStack {
                Spacer()
                Button(permissions.status(for: kind) == .granted ? "Done" : "Not Now",
                       action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 460)
        // Granting from the sheet closes it: the source it gated is usable now.
        .onChange(of: permissions.status(for: kind)) { _, status in
            if status == .granted { onClose() }
        }
    }
}
