import SwiftUI
import StreamCore

/// E06 (issue #165): the PTZ camera section for the Sources inspector —
/// network target configuration, a pan/tilt/zoom pad with speed controls,
/// recallable presets, and the explicit opt-in scene→preset recall links.
///
/// INTEGRATION HOOK (orchestrator): `MainWindowView.swift` is owned by the
/// E01 agent, so the one-line insertion is left to the merge owner:
/// add `PTZControlSectionView()` to the inspector `Form` next to
/// `SceneBehaviorSectionView()` (~line 532). The view reads the shared
/// `StudioCommandDispatcher` from the environment (already injected there)
/// and observes `dispatcher.ptzStore` / `dispatcher.ptz` directly — no other
/// wiring, no new environment objects required.
///
/// Focus-loss stop: movement buttons send their move on press and `.ptzStop`
/// on release, and the whole section sends `.ptzStopAll` on disappear — a
/// camera never drives unattended (the dispatcher/controller also stop on
/// disconnect).
struct PTZControlSectionView: View {
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher
    @State private var isAddingTarget = false

    var body: some View {
        Section("PTZ Cameras") {
            PTZTargetListContent(
                store: dispatcher.ptzStore,
                controller: dispatcher.ptz,
                stagedSceneID: dispatcher.state.stagedSceneID,
                dispatcher: dispatcher)
            Button("Add Network Camera…") { isAddingTarget = true }
        }
        .onDisappear {
            // The controls are gone — stop every camera with outstanding
            // motion (the issue's stop-on-focus-loss requirement).
            dispatcher.execute(.ptzStopAll)
        }
        .sheet(isPresented: $isAddingTarget) {
            PTZTargetEditorSheet { target in
                dispatcher.execute(.ptzAddTarget(target))
            }
        }
    }
}

/// The section's content, split out so `@ObservedObject` can subscribe to
/// the store/controller directly (the section view itself only observes the
/// dispatcher from the environment).
private struct PTZTargetListContent: View {
    @ObservedObject var store: PTZPresetStore
    @ObservedObject var controller: PTZController
    let stagedSceneID: SceneID?
    let dispatcher: StudioCommandDispatcher

    var body: some View {
        if store.targets.isEmpty {
            Text("No PTZ cameras configured. VISCA-over-IP targets only — UVC PTZ is unavailable in the sandboxed app (see the compatibility notes in StreamCore/PTZ.swift).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        ForEach(store.targets) { target in
            PTZTargetControlView(target: target,
                                 store: store,
                                 controller: controller,
                                 stagedSceneID: stagedSceneID,
                                 dispatcher: dispatcher)
        }
    }
}

/// One target: connection status, the movement pad, zoom, presets, and the
/// staged scene's recall link.
private struct PTZTargetControlView: View {
    let target: PTZTarget
    @ObservedObject var store: PTZPresetStore
    @ObservedObject var controller: PTZController
    let stagedSceneID: SceneID?
    let dispatcher: StudioCommandDispatcher

    @State private var panSpeed: Double = 12
    @State private var tiltSpeed: Double = 10
    @State private var zoomSpeed: Double = 4
    @State private var presetName = ""

    private var presets: [PTZPreset] { store.presets(forTargetID: target.id) }
    private var recallLink: PTZSceneRecallLink? {
        guard let stagedSceneID else { return nil }
        return store.recallLinks(forSceneID: stagedSceneID.rawValue)
            .first(where: { $0.targetID == target.id })
    }

    var body: some View {
        DisclosureGroup {
            connectionLine
            movementPad
            zoomRow
            speedSliders
            presetGrid
            sceneRecallRow
        } label: {
            HStack {
                Text(target.name)
                Spacer()
                Text(connectionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Connection

    private var connectionLabel: String {
        switch controller.connectionStates[target.id] ?? .disconnected {
        case .disconnected: return "Idle"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .failed: return "Unreachable"
        }
    }

    @ViewBuilder
    private var connectionLine: some View {
        Text("\(target.kind.displayName) · \(target.host):\(target.port) · VISCA address \(target.cameraAddress)")
            .font(.caption)
            .foregroundStyle(.secondary)
        if case .failed(let reason) = controller.connectionStates[target.id] {
            Text(reason)
                .font(.caption)
                .foregroundStyle(.orange)
        }
        Button("Remove Camera", role: .destructive) {
            dispatcher.execute(.ptzRemoveTarget(target.id))
        }
        .font(.caption)
    }

    // MARK: Movement pad (press to drive, release to stop)

    private var movementPad: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                moveButton(.upLeft, systemImage: "arrow.up.left")
                moveButton(.up, systemImage: "arrow.up")
                moveButton(.upRight, systemImage: "arrow.up.right")
            }
            GridRow {
                moveButton(.left, systemImage: "arrow.left")
                Button("Stop") { dispatcher.execute(.ptzStop(target.id)) }
                    .controlSize(.small)
                moveButton(.right, systemImage: "arrow.right")
            }
            GridRow {
                moveButton(.downLeft, systemImage: "arrow.down.left")
                moveButton(.down, systemImage: "arrow.down")
                moveButton(.downRight, systemImage: "arrow.down.right")
            }
        }
    }

    private func moveButton(_ direction: PTZMoveDirection, systemImage: String) -> some View {
        Image(systemName: systemImage)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        dispatcher.execute(.ptzMove(target.id,
                                                    direction: direction,
                                                    panSpeed: Int(panSpeed),
                                                    tiltSpeed: Int(tiltSpeed)))
                    }
                    .onEnded { _ in
                        dispatcher.execute(.ptzStop(target.id))
                    })
    }

    private var zoomRow: some View {
        HStack {
            zoomButton(.wide, title: "Zoom Out")
            zoomButton(.tele, title: "Zoom In")
        }
    }

    private func zoomButton(_ direction: PTZZoomDirection, title: String) -> some View {
        Button(title) {}
            .controlSize(.small)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        dispatcher.execute(.ptzZoom(target.id,
                                                    direction: direction,
                                                    speed: Int(zoomSpeed)))
                    }
                    .onEnded { _ in
                        dispatcher.execute(.ptzStop(target.id))
                    })
    }

    private var speedSliders: some View {
        VStack(alignment: .leading, spacing: 4) {
            Slider(value: $panSpeed, in: 1...Double(VISCAPacket.maxPanSpeed)) {
                Text("Pan Speed")
            }
            Slider(value: $tiltSpeed, in: 1...Double(VISCAPacket.maxTiltSpeed)) {
                Text("Tilt Speed")
            }
            Slider(value: $zoomSpeed, in: 0...Double(VISCAPacket.maxZoomSpeed)) {
                Text("Zoom Speed")
            }
        }
        .controlSize(.small)
    }

    // MARK: Presets

    private var presetGrid: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Presets")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 4) {
                ForEach(0..<8, id: \.self) { slot in
                    presetButton(UInt8(slot))
                }
            }
            HStack {
                TextField("Preset name", text: $presetName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }
        }
    }

    private func presetButton(_ number: UInt8) -> some View {
        let preset = store.preset(number: number, forTargetID: target.id)
        return Button(preset.map { "\($0.number): \($0.name)" } ?? "\(number)") {
            if preset != nil {
                dispatcher.execute(.ptzRecallPreset(target.id, number: number))
            } else {
                let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
                dispatcher.execute(.ptzStorePreset(target.id,
                                                   number: number,
                                                   name: name.isEmpty ? nil : name))
            }
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .tint(preset == nil ? nil : .accentColor)
        .help(preset == nil
              ? "Store the camera's current position into slot \(number)"
              : "Recall slot \(number)")
        .contextMenu {
            if preset != nil {
                Button("Remove Preset", role: .destructive) {
                    dispatcher.execute(.ptzRemovePreset(target.id, number: number))
                }
            }
        }
    }

    // MARK: Scene-linked recall (explicit opt-in, fires on Take to program)

    @ViewBuilder
    private var sceneRecallRow: some View {
        if let stagedSceneID, !presets.isEmpty {
            let link = recallLink
            Toggle("Recall Preset on Take to Program",
                   isOn: Binding(
                    get: { link?.recallOnProgramEntry ?? false },
                    set: { armed in
                        let preset = link?.presetNumber ?? presets[0].number
                        dispatcher.execute(.ptzSetSceneRecall(PTZSceneRecallLink(
                            id: link?.id ?? UUID(),
                            sceneID: stagedSceneID.rawValue,
                            targetID: target.id,
                            presetNumber: preset,
                            recallOnProgramEntry: armed)))
                    }))
            if let link {
                Picker("Preset", selection: Binding(
                    get: { link.presetNumber },
                    set: { number in
                        var updated = link
                        updated.presetNumber = number
                        dispatcher.execute(.ptzSetSceneRecall(updated))
                    })) {
                        ForEach(presets) { preset in
                            Text("\(preset.number): \(preset.name)").tag(preset.number)
                        }
                    }
                    .controlSize(.small)
                    .disabled(!link.recallOnProgramEntry)
                Text("Fires only when this scene becomes PROGRAM via Take — previewing never moves the camera.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Add-target sheet: host/port/protocol/address, with the protocol's default
/// port pre-filled (52381; PTZOptics/AViPAS use 1259 UDP / 5678 TCP — the
/// operator overrides the port when configuring those).
private struct PTZTargetEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (PTZTarget) -> Void

    @State private var name = ""
    @State private var host = ""
    @State private var portText = ""
    @State private var kind: PTZProtocolKind = .viscaOverUDP
    @State private var cameraAddress: Int = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Network PTZ Camera").font(.headline)
            TextField("Name (e.g. Stage Left)", text: $name)
            TextField("Host (IP or hostname)", text: $host)
            Picker("Protocol", selection: $kind) {
                ForEach(PTZProtocolKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            TextField("Port (default \(kind.defaultPort))", text: $portText)
            Stepper("VISCA Address: \(cameraAddress)", value: $cameraAddress, in: 1...7)
            Text("Raw serial-format VISCA frames, one command per datagram/write. Speeds clamp to pan 1–24, tilt 1–20; presets are VISCA slots 0–89.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    onSave(PTZTarget(
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                        port: UInt16(portText) ?? kind.defaultPort,
                        kind: kind,
                        cameraAddress: UInt8(cameraAddress)))
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 360)
    }
}
