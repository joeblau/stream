import SwiftUI
import StreamCore

/// Embed beside the existing Program/Preview row in the same studio window.
struct SecondaryCanvasPanelView: View {
    @EnvironmentObject private var controller: StreamController
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher
    @EnvironmentObject private var previewProgram: PreviewProgramModel
    @EnvironmentObject private var scenes: SceneStore
    @State private var showGuides = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Secondary Canvas").font(.headline)
                Spacer()
                if previewProgram.stagedScene?.secondaryCanvas == nil {
                    Button("Copy Program Geometry") {
                        guard let scene = previewProgram.stagedScene else { return }
                        dispatcher.execute(.setSecondaryCanvas(.duplicated(from: scene), in: scene.id))
                    }
                } else {
                    Button("Link All Geometry") { edit { $0.placements = [:] } }
                    Button("Copy Program Geometry") {
                        guard let scene = previewProgram.stagedScene else { return }
                        edit { $0.placements = SecondaryCanvasLayout.duplicated(from: scene).placements }
                    }
                    Toggle("Guides", isOn: $showGuides).toggleStyle(.button)
                }
            }
            if let scene = previewProgram.stagedScene, let layout = scene.secondaryCanvas {
                Picker("Secondary size", selection: Binding(get: {
                    layout.size.width == 1080 ? 1080 : 720
                }, set: { width in edit { $0.size = GraphSize(width: Double(width), height: Double(width * 16 / 9)) } })) {
                    Text("720 × 1280").tag(720)
                    Text("1080 × 1920").tag(1080)
                }.disabled(controller.outputSessionActive)
                Text("Playback, timers and PDF pages are shared. Drag here to keep independent geometry; Follow Program restores linked geometry.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    PreviewView(image: controller.secondaryPreviewImage, label: "SECONDARY PREVIEW",
                        accent: dispatcher.state.hasPendingStagedEdits ? .yellow : .secondary,
                        isHighlighted: dispatcher.state.hasPendingStagedEdits,
                        placeholder: controller.isPreviewing ? "Waiting for secondary layout…" : "Preview off") { rect in
                        ZStack {
                            CanvasInteractionView(imageRect: rect, canvasSize: controller.secondaryStagedProfile.canvasSize, canvas: .secondary)
                            if showGuides { safeZone(layout.safeZone, rect: rect).allowsHitTesting(false) }
                        }
                    }
                    PreviewView(image: controller.secondaryProgramImage, label: "SECONDARY PROGRAM",
                        accent: dispatcher.state.stream.isLive ? .red : .secondary,
                        isHighlighted: dispatcher.state.stream.isLive,
                        placeholder: controller.isPreviewing ? "Take a secondary layout to Program" : "Preview off")
                }.frame(minHeight: 180)
                DisclosureGroup("Layer visibility and geometry links") {
                    ForEach(scene.layers) { layer in
                        HStack {
                            Toggle(layer.name, isOn: Binding(get: { layout.placements[layer.id]?.isVisible ?? layer.isVisible }, set: { visible in
                                edit { value in
                                    let transform = value.placements[layer.id]?.transform ?? layer.transform
                                    value.placements[layer.id] = .init(transform: transform, isVisible: visible)
                                }
                            })).disabled(scene.isEffectivelyLocked(layer))
                            Text(layout.placements[layer.id] == nil ? "Follows Program" : "Independent geometry").font(.caption).foregroundStyle(.secondary)
                            Button("Follow Program") { edit { $0.placements[layer.id] = nil } }
                                .disabled(layout.placements[layer.id] == nil || scene.isEffectivelyLocked(layer))
                        }
                    }
                }
                DisclosureGroup("Adjust platform safe zone") {
                    guideSlider("Top", value: layout.safeZone.top) { $0.safeZone.top = $1 }
                    guideSlider("Bottom", value: layout.safeZone.bottom) { $0.safeZone.bottom = $1 }
                    guideSlider("Left", value: layout.safeZone.left) { $0.safeZone.left = $1 }
                    guideSlider("Right", value: layout.safeZone.right) { $0.safeZone.right = $1 }
                }
                if controller.outputSessionActive {
                    Text("Output size stays fixed at \(controller.activeSecondaryProfile.canvasWidth) × \(controller.activeSecondaryProfile.canvasHeight) while outputs are active.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SecondaryCanvasRecordingView(recorder: controller.secondaryRecorder)
            }
        }
        .onAppear { controller.setSecondaryMonitorsEnabled(true) }
        .onDisappear { controller.setSecondaryMonitorsEnabled(false) }
    }
    private func edit(_ mutation: (inout SecondaryCanvasLayout) -> Void) {
        guard let scene = previewProgram.stagedScene, var layout = scene.secondaryCanvas else { return }
        mutation(&layout); dispatcher.execute(.setSecondaryCanvas(layout, in: scene.id))
    }
    private func guideSlider(_ title: String, value: Double, update: @escaping (inout SecondaryCanvasLayout, Double) -> Void) -> some View {
        HStack {
            Text(title).frame(width: 50, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { changed in edit { update(&$0, changed) } }), in: 0...0.4)
            Text("\(Int(value * 100))%").monospacedDigit().frame(width: 40)
        }
    }
    private func safeZone(_ zone: SecondaryCanvasLayout.SafeZone, rect: CGRect) -> some View {
        Path { path in
            path.addRect(CGRect(x: rect.minX + rect.width * zone.left, y: rect.minY + rect.height * zone.top,
                width: rect.width * (1-zone.left-zone.right), height: rect.height * (1-zone.top-zone.bottom)))
        }.stroke(.yellow.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
    }
}

private struct SecondaryCanvasRecordingView: View {
    @ObservedObject var recorder: RecordingController
    @EnvironmentObject private var controller: StreamController
    @EnvironmentObject private var programRecorder: RecordingController
    var body: some View {
        HStack {
            Button(recorder.canStop ? "Stop Secondary Recording" : "Record Secondary Canvas") {
                if recorder.canStop { recorder.stop() }
                else { recorder.context = programRecorder.context; recorder.start(stream: controller) }
            }.disabled(!recorder.canStop && recorder.state.isActive)
            RecordingOptionsView(recorder: recorder)
            if recorder.state == .recording { Text("Secondary recording").foregroundStyle(.red) }
            else if recorder.state == .preparing { Text("Preparing secondary recording…").foregroundStyle(.orange) }
            else if recorder.state == .stopping { Text("Finishing secondary recording…").foregroundStyle(.secondary) }
            if let error = recorder.lastError { Text(error).foregroundStyle(.orange).font(.caption) }
            if let url = recorder.lastRecordingURL {
                Button("Reveal Secondary File") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }
}
