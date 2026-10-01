import AVFoundation
import CoreImage
import SwiftUI

/// C01 (issue #76): the camera source UI — a thumbnail switcher strip plus
/// the camera-source registry section for the Sources inspector, mirroring
/// C02's screen-source surfaces.
///
/// `CameraSwitcherView` is a horizontal strip embedded in the studio window
/// (above the canvas monitors): one tile per registered camera source,
/// showing the LIVE frame while its capture runs and the device icon
/// otherwise, plus one tile per connected-but-unregistered device so a
/// hot-plugged camera appears immediately (DeviceMonitor publishes it).
/// Clicking a tile assigns that camera to the selected camera layer — a
/// rebind that keeps the layer's transform, so framing is preserved — or,
/// with no camera layer selected, adds a new camera layer bound to the
/// source (fullscreen when the scene has no camera yet, PIP otherwise).
/// Every assignment routes through the dispatcher's `.updateScene`, so it is
/// undoable and lands on the staged scene like any other layer edit.
///
/// `CameraSourcesSectionView` manages the registry entries themselves
/// (add/rename/retarget/remove) with the pool's per-source capture status
/// (capturing / idle / error, keyed by payload identity — the same key
/// capture demand uses).
struct CameraSwitcherView: View {
    @EnvironmentObject private var sceneStore: SceneStore
    @EnvironmentObject private var previewProgram: PreviewProgramModel
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher
    @EnvironmentObject private var capturePool: CaptureSourcePool
    @EnvironmentObject private var deviceMonitor: DeviceMonitor

    private var cameraSources: [SourceDefinition] {
        sceneStore.sources.filter { $0.payload.isCamera }
    }

    /// Connected devices no registry camera source pins — hot-plugged
    /// cameras the user can register straight from the strip.
    private var unregisteredDevices: [AVCaptureDevice] {
        let pinned = Set(cameraSources.compactMap { source -> String? in
            guard case .camera(let payload) = source.payload else { return nil }
            return payload.deviceID
        })
        return deviceMonitor.videoDevices.filter { !pinned.contains($0.uniqueID) }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(cameraSources) { source in
                    CameraSourceTile(source: source) {
                        assign(source)
                    }
                }
                ForEach(unregisteredDevices, id: \.uniqueID) { device in
                    UnregisteredDeviceTile(device: device) {
                        let source = sceneStore.addSource(SourceDefinition(
                            name: device.localizedName,
                            payload: .camera(CameraSourcePayload(deviceID: device.uniqueID))))
                        assign(source)
                    }
                }
                if cameraSources.isEmpty, unregisteredDevices.isEmpty {
                    Label("No camera connected", systemImage: "video.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(ContinuitySetupGuidance.emptyStateHint)
                        .frame(height: 72)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity)
    }

    /// The switcher's selection semantics: a selected camera layer takes the
    /// new source in place (sourceID + payload swap; transform untouched, so
    /// framing survives the camera change); otherwise a new camera layer
    /// bound to the source lands at the front and becomes the selection.
    private func assign(_ source: SourceDefinition) {
        guard var scene = previewProgram.stagedScene else { return }
        if let index = scene.layers.firstIndex(where: {
            sceneStore.selectedLayerIDs.contains($0.id) && $0.payload.isCamera
        }) {
            scene.layers[index].sourceID = source.id
            scene.layers[index].payload = source.payload
        } else {
            var layer = scene.layers.contains(where: { $0.payload.isCamera })
                ? LayerNode.cameraPIP(corner: .bottomRight, scale: 0.28, sourceID: source.id)
                : LayerNode.fullscreenCamera(sourceID: source.id)
            layer.name = source.name
            layer.payload = source.payload
            scene.layers.append(layer)
            sceneStore.selectedLayerIDs = [layer.id]
        }
        dispatcher.execute(.updateScene(scene))
    }
}

/// One camera-source tile in the switcher: live thumbnail while capturing,
/// device icon otherwise, with the C10 per-source health badge (capturing /
/// idle / error) the capture pool publishes for the source's payload key.
/// C05: iPhone/iPad devices carry their connection badge (Continuity / Desk
/// View / USB), a suspended feed shows a paused overlay, and Continuity
/// devices get the capability-gated effects menu.
private struct CameraSourceTile: View {
    let source: SourceDefinition
    let onSelect: () -> Void

    @EnvironmentObject private var capturePool: CaptureSourcePool
    @EnvironmentObject private var deviceMonitor: DeviceMonitor

    private var key: CaptureSourceKey? {
        guard case .camera(let payload) = source.payload else { return nil }
        return .camera(payload)
    }

    /// The physical device this source pins (nil for the system default).
    private var device: AVCaptureDevice? {
        guard case .camera(let payload) = source.payload,
              let deviceID = payload.deviceID else { return nil }
        return AVCaptureDevice(uniqueID: deviceID)
    }

    private var problem: String? {
        key.flatMap { capturePool.problem(for: $0) }
    }

    private var isCapturing: Bool {
        key.map { capturePool.activeSources.contains($0) } ?? false
    }

    /// C05: the pinned device's feed is suspended (iPhone locked / paused).
    private var isSuspended: Bool {
        guard case .camera(let payload) = source.payload,
              let deviceID = payload.deviceID else { return false }
        return deviceMonitor.suspendedCameraIDs.contains(deviceID)
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 4) {
                ZStack(alignment: .bottomTrailing) {
                    thumbnail
                    statusBadge
                        .padding(4)
                }
                Text(source.name)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(maxWidth: 96)
                if let badge = device?.streamCameraKind.badge {
                    Text(badge)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .help(problem ?? (isCapturing ? "Capturing — click to use \(source.name)"
                                      : "Click to use \(source.name)"))
        .contextMenu {
            // Capability gate: effects only exist for Continuity-family
            // devices (Center Stage / Portrait / Studio Light).
            if let device, device.streamCameraKind.isAppleMobileDevice {
                ContinuityEffectsMenuContent(device: device)
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let key, isCapturing {
            LiveCameraThumbnail(key: key)
        } else {
            ZStack {
                Image(systemName: device?.streamCameraKind.iconName ?? "video.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                if isSuspended {
                    Image(systemName: "pause.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                }
            }
            .frame(width: 96, height: 54)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if problem != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.small)
        } else if isCapturing {
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
        }
    }
}

/// A tile for a connected camera with no registry source yet: one click
/// registers it (named after the device) and assigns it like any other tile.
/// C05: iPhone/iPad devices show the phone icon and their connection badge.
private struct UnregisteredDeviceTile: View {
    let device: AVCaptureDevice
    let onAdd: () -> Void

    var body: some View {
        Button(action: onAdd) {
            VStack(spacing: 4) {
                ZStack(alignment: .bottomTrailing) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                            .foregroundStyle(.secondary)
                        Image(systemName: device.streamCameraKind.iconName)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "plus.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
                .frame(width: 96, height: 54)
                Text(device.localizedName)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(maxWidth: 96)
                if let badge = device.streamCameraKind.badge {
                    Text(badge)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Add \(device.streamSourceDisplayName) as a camera source — \(device.streamFormatSummary)")
    }
}

/// The switcher's live tile content: pulls the source's OWN latest frame
/// from the pool's keyed providers a few times a second (never another
/// source's pixels — an unkeyed read would show the wrong camera) and
/// mirrors it like the compositor does. Falls back to the device icon
/// whenever the capture has no fresh frame.
private struct LiveCameraThumbnail: View {
    let key: CaptureSourceKey

    @State private var image: CGImage?
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    private static let ciContext = CIContext()

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "video.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 96, height: 54)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onReceive(timer) { _ in refresh() }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        guard let frame = SourceFrameProviders.shared.cameraFrame(for: key) else {
            image = nil
            return
        }
        let orientation: CGImagePropertyOrientation =
            frame.position == .front ? .upMirrored : .up
        let ciImage = CIImage(cvPixelBuffer: frame.buffer).oriented(orientation)
        image = Self.ciContext.createCGImage(ciImage, from: ciImage.extent)
    }
}

/// C01 (issue #76): the camera-source registry management section, embedded
/// in the Sources inspector alongside C02's screen sources. Add offers the
/// system default camera and every connected device (built-in, USB, and
/// virtual cameras — everything `DeviceMonitor.videoDevices` exposes, with
/// each device's resolution/frame-rate summary in the subtitle); rows carry
/// the pool's live capture status and offer rename, retarget (relink to a
/// different camera through the S05 registry path, so every bound layer
/// follows), and remove.
///
/// C05 (issue #105): the Add picker groups iPhone/iPad devices (Continuity,
/// Desk View, wired USB) under their own section with an explicit connection
/// badge, shows setup guidance when none is connected, rows describe a
/// suspended Continuity feed honestly, and Continuity devices carry the
/// capability-gated effects menu (Center Stage toggle; Portrait/Studio Light
/// state pointing at Control Center).
struct CameraSourcesSectionView: View {
    @EnvironmentObject private var sceneStore: SceneStore
    @EnvironmentObject private var controller: StreamController
    @EnvironmentObject private var deviceMonitor: DeviceMonitor

    @State private var renameTarget: SourceDefinition?
    @State private var draftName = ""

    private var cameraSources: [SourceDefinition] {
        sceneStore.sources.filter { $0.payload.isCamera }
    }

    /// C05: connected iPhone/iPad-sourced devices (Continuity, Desk View,
    /// USB) — the "iPhone & iPad" picker group.
    private var mobileDevices: [AVCaptureDevice] {
        deviceMonitor.videoDevices.filter { $0.streamCameraKind.isAppleMobileDevice }
    }

    private var otherDevices: [AVCaptureDevice] {
        deviceMonitor.videoDevices.filter { !$0.streamCameraKind.isAppleMobileDevice }
    }

    private func addSource(for device: AVCaptureDevice) {
        sceneStore.addSource(SourceDefinition(
            name: device.localizedName,
            payload: .camera(CameraSourcePayload(deviceID: device.uniqueID))))
    }

    var body: some View {
        Section {
            if cameraSources.isEmpty {
                Text("No camera sources yet. Add one to capture a specific camera as a reusable source.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(cameraSources) { source in
                sourceRow(source)
            }
            Menu {
                Button("System Default Camera") {
                    sceneStore.addSource(SourceDefinition(
                        name: "Camera", payload: .camera(CameraSourcePayload())))
                }
                // C05 (issue #105): iPhone/iPad devices group first with their
                // connection badge; when none are connected the section says
                // HOW to add one instead of vanishing.
                Section("iPhone & iPad") {
                    if mobileDevices.isEmpty {
                        Text(ContinuitySetupGuidance.noDeviceDetected)
                    } else {
                        ForEach(mobileDevices, id: \.uniqueID) { device in
                            Button(device.streamSourceDisplayName) {
                                addSource(for: device)
                            }
                        }
                    }
                }
                Section("Cameras") {
                    ForEach(otherDevices, id: \.uniqueID) { device in
                        Button(device.localizedName) {
                            addSource(for: device)
                        }
                    }
                }
            } label: {
                Label("Add Camera Source", systemImage: "plus")
            }
        } header: {
            Text("Camera Sources")
        }
        .alert("Rename Source", isPresented: renamePresented) {
            TextField("Name", text: $draftName)
            Button("Rename") {
                if let renameTarget {
                    let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        sceneStore.renameSource(renameTarget.id, to: trimmed)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Rows

    private func sourceRow(_ source: SourceDefinition) -> some View {
        HStack(spacing: 6) {
            Image(systemName: device(for: source)?.streamCameraKind.iconName ?? "video.fill")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name)
                    .lineLimit(1)
                Text(deviceDescription(for: source))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            statusBadge(for: source)
        }
        .contextMenu {
            Button("Rename…") {
                draftName = source.name
                renameTarget = source
            }
            Menu("Change Camera") {
                Button("System Default Camera") {
                    sceneStore.relinkSource(source.id, to: .camera(CameraSourcePayload()))
                }
                ForEach(deviceMonitor.videoDevices, id: \.uniqueID) { device in
                    Button(device.streamSourceDisplayName) {
                        sceneStore.relinkSource(
                            source.id, to: .camera(CameraSourcePayload(deviceID: device.uniqueID)))
                    }
                }
            }
            .help("Point \"\(source.name)\" at a different camera — every layer using it follows")
            // C05: Continuity-family devices expose the capability-gated
            // effects (Center Stage toggle; Portrait/Studio Light state).
            if let device = device(for: source), device.streamCameraKind.isAppleMobileDevice {
                Divider()
                ContinuityEffectsMenuContent(device: device)
            }
            Divider()
            Button("Remove Source", role: .destructive) {
                sceneStore.removeSource(source.id)
            }
        }
    }

    // MARK: - Status

    private enum SourceStatus {
        case capturing, idle, error(String)
    }

    /// The pool's live view of this source, keyed by its payload identity —
    /// the same key capture demand uses, so a status here always matches what
    /// the pool is actually doing.
    private func status(for source: SourceDefinition) -> SourceStatus {
        guard case .camera(let payload) = source.payload else { return .idle }
        let key = CaptureSourceKey.camera(payload)
        if controller.capturePool.activeSources.contains(key) {
            return .capturing
        }
        if let message = controller.capturePool.sourceErrors[key] {
            return .error(message)
        }
        return .idle
    }

    @ViewBuilder
    private func statusBadge(for source: SourceDefinition) -> some View {
        switch status(for: source) {
        case .capturing:
            Label("Capturing", systemImage: "circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
                .help("Capturing")
        case .idle:
            Label("Idle", systemImage: "circle")
                .labelStyle(.iconOnly)
                .foregroundStyle(.tertiary)
                .help("Idle — capture starts when a visible layer uses this source")
        case .error(let message):
            Label("Error", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.orange)
                .help(message)
        }
    }

    // MARK: - Descriptions

    /// The physical device a source pins (nil for the system default or a
    /// device that no longer resolves).
    private func device(for source: SourceDefinition) -> AVCaptureDevice? {
        guard case .camera(let payload) = source.payload,
              let deviceID = payload.deviceID else { return nil }
        return AVCaptureDevice(uniqueID: deviceID)
    }

    private func deviceDescription(for source: SourceDefinition) -> String {
        guard case .camera(let payload) = source.payload else { return "" }
        guard let deviceID = payload.deviceID else {
            return "System default camera"
        }
        guard let device = AVCaptureDevice(uniqueID: deviceID) else {
            return "Camera not connected"
        }
        // C05: explicit identity (badge), and an honest paused state for a
        // suspended Continuity feed (iPhone locked / paused in Control Center).
        let identity = device.streamSourceDisplayName
        if device.isSuspended {
            return "\(identity) — feed paused (unlock the iPhone to resume)"
        }
        return "\(identity) — \(device.streamFormatSummary)"
    }

    // MARK: - Rename alert

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })
    }
}

extension AVCaptureDevice {
    /// C01: the device's highest-resolution format and its peak frame rate,
    /// plus whether the device carries muxed (embedded) audio — the format
    /// exposure issue #76 asks the source UI to show.
    var streamFormatSummary: String {
        guard let best = formats.max(by: { Self.streamPixelArea(of: $0) < Self.streamPixelArea(of: $1) })
        else { return "Video device" }
        let dimensions = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
        let maxFPS = best.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        var summary = "\(dimensions.width)×\(dimensions.height) · up to \(Int(maxFPS.rounded())) fps"
        let hasMuxedAudio = formats.contains {
            CMFormatDescriptionGetMediaType($0.formatDescription) == kCMMediaType_Muxed
        }
        if hasMuxedAudio {
            summary += " · embedded audio"
        }
        return summary
    }

    private static func streamPixelArea(of format: AVCaptureDevice.Format) -> Int {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return Int(dimensions.width) * Int(dimensions.height)
    }
}
