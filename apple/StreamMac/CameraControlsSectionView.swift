import SwiftUI
import StreamCore

/// E05 (issue #109): the Sources inspector's per-camera hardware controls and
/// macOS reaction triggers.
///
/// INTEGRATION HOOK (for the orchestrator — MainWindowView is owned by the
/// E01 agent and intentionally untouched here): insert
///
///     CameraControlsSectionView()
///
/// into `MainWindowView.sourcesInspector`'s `Form` directly after
/// `CameraSourcesSectionView()` (apple/StreamMac/MainWindowView.swift, ~line
/// 490). The view needs only the already-injected `StudioCommandDispatcher`
/// environment object — it observes `dispatcher.cameraControls` itself — so
/// no other wiring is required.
///
/// Every control is capability-gated against the connected device's
/// DISCOVERED support (`CameraControlCapabilities`): a mode picker appears
/// only when the hardware honors both choices (a one-option picker would be
/// an inert control), and unavailable states are explicit text (no camera,
/// no adjustable controls, reactions disabled in Control Center). Controls
/// address the PHYSICAL device, and the capture pool runs one capture per
/// camera feeding both composition engines — a hardware change therefore
/// lands in preview AND program together, which the footer states honestly.
public struct CameraControlsSectionView: View {
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher

    public init() {}

    public var body: some View {
        // The dispatcher's nested center doesn't invalidate views through the
        // dispatcher's own @Published (the StreamMacApp environment comment),
        // so the content observes the center directly.
        CameraControlsSectionContent(center: dispatcher.cameraControls,
                                     dispatcher: dispatcher)
    }
}

private struct CameraControlsSectionContent: View {
    @ObservedObject var center: CameraControlCenter
    let dispatcher: StudioCommandDispatcher

    /// Live device state (modes, adjusting flags, reactions in progress)
    /// isn't KVO-bridged to SwiftUI; the section re-reads it on a slow tick
    /// while visible, so Control-Center-side changes show without a restart.
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Section("Camera Controls & Reactions") {
            if center.devices.isEmpty {
                Text("No camera connected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(ContinuitySetupGuidance.emptyStateHint)
            }
            ForEach(center.devices) { snapshot in
                CameraDeviceControlsView(snapshot: snapshot, dispatcher: dispatcher)
            }
            if center.devices.contains(where: { $0.capabilities.hasAdjustableControls }) {
                Text("Hardware controls change the camera feed itself — preview and program are affected together.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { center.rebuild() }
        .onReceive(timer) { _ in center.rebuild() }
    }
}

/// One connected camera: discovered mode pickers (never inert — hidden when
/// the hardware offers no choice) plus the reaction trigger grid or its
/// explicit unavailable reason.
private struct CameraDeviceControlsView: View {
    let snapshot: CameraDeviceSnapshot
    let dispatcher: StudioCommandDispatcher

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: snapshot.kind.iconName)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(snapshot.displayName)
                    .lineLimit(1)
                Spacer()
                if snapshot.isCapturing {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                        .help("Capturing — this camera is live in the composition")
                }
            }
            if !snapshot.capabilities.hasAdjustableControls,
               !snapshot.capabilities.reactionsAvailable {
                Text("No adjustable hardware controls on this camera.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            modePicker("Focus",
                       modes: snapshot.capabilities.focusModes,
                       live: snapshot.focusMode,
                       isAdjusting: snapshot.isAdjustingFocus) { mode in
                var controls = snapshot.persisted
                controls.focusMode = mode
                return controls
            }
            modePicker("Exposure",
                       modes: snapshot.capabilities.exposureModes,
                       live: snapshot.exposureMode,
                       isAdjusting: snapshot.isAdjustingExposure) { mode in
                var controls = snapshot.persisted
                controls.exposureMode = mode
                return controls
            }
            modePicker("White Balance",
                       modes: snapshot.capabilities.whiteBalanceModes,
                       live: snapshot.whiteBalanceMode,
                       isAdjusting: snapshot.isAdjustingWhiteBalance) { mode in
                var controls = snapshot.persisted
                controls.whiteBalanceMode = mode
                return controls
            }
            reactions
        }
        .padding(.vertical, 2)
    }

    /// A mode picker for one control, rendered ONLY when the device honors
    /// both modes (otherwise the picker would be inert). The selection reads
    /// the device's LIVE mode; a pick dispatches the whole updated per-device
    /// preference through the command layer (capability-revalidated there).
    @ViewBuilder
    private func modePicker(
        _ label: String,
        modes: [CameraDeviceControlSettings.Mode],
        live: CameraDeviceControlSettings.Mode?,
        isAdjusting: Bool,
        update: @escaping (CameraDeviceControlSettings.Mode) -> CameraDeviceControlSettings
    ) -> some View {
        if modes.count > 1 {
            Picker(label, selection: Binding<CameraDeviceControlSettings.Mode>(
                get: { live ?? .automatic },
                set: { mode in
                    dispatcher.execute(.setCameraControls(snapshot.uniqueID, update(mode)))
                })) {
                ForEach(modes, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            if isAdjusting {
                Text("\(label) is adjusting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var reactions: some View {
        if snapshot.capabilities.reactionsAvailable,
           !snapshot.capabilities.supportedReactions.isEmpty {
            Text("Reactions")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))], spacing: 6) {
                ForEach(snapshot.capabilities.supportedReactions, id: \.self) { reaction in
                    Button {
                        dispatcher.execute(.triggerCameraReaction(snapshot.uniqueID, reaction))
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: reaction.systemImageName)
                            Text(reaction.displayName)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .help("Trigger \(reaction.displayName) — rendered into \(snapshot.displayName)'s feed (preview and program)")
                }
            }
            if !snapshot.reactionsInProgress.isEmpty {
                Text("Playing: \(snapshot.reactionsInProgress.map(\.displayName).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let reason = snapshot.capabilities.reactionUnavailableReason {
            Label("Reactions unavailable — \(reason)", systemImage: "hand.thumbsup")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
