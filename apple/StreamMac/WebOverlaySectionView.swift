import SwiftUI
import StreamCore

/// G08 (issue #115): the browser-overlay inspector surface — widget URL /
/// local HTML asset, viewport and capture cadence, transparency note,
/// deliberate interaction opt-in, audio route, scene-entry refresh policy,
/// CSS overrides, and the live load/error state with runtime controls
/// (Reload, Replay Alert) — hosted in the Sources inspector for the single
/// selected WEB layer of the STAGED scene.
///
/// Every edit is a complete `WebSourcePayload` write through `.setLayerWeb`,
/// so the widget stages, Takes, reverts, and undoes like any layer edit
/// (undo-coalesced per layer), and the capture pool re-keys + reloads the
/// widget deliberately on each committed edit. Reads flow through the
/// `WebSourcePayload.browserOverlay` shim (WebOverlayIntegration.swift):
/// TODAY the persisted payload carries only the URL, so viewport/fps/CSS/
/// refresh-policy edits apply live but persist fully once orchestrator
/// hook 1 expands the payload.
///
/// ── ORCHESTRATOR HOOK: mounting ───────────────────────────────────────────
/// In `apple/StreamMac/MainWindowView.swift` (G01-owned), `sourcesInspector`,
/// after `TextLayerSectionView()` (≈ line 544):
///
/// ```swift
/// // G08 (issue #115): browser/local-HTML widget configuration for the
/// // selected web layer — URL, viewport, capture cadence, CSS overrides,
/// // interaction/audio policy, and live load/error state.
/// WebOverlaySectionView()
/// ```
///
/// Overlay-level editing (project overlays with web payloads) needs an
/// overlay-selection model the overlay panel doesn't have yet; when one
/// lands, the same section edits it via `.setOverlayWeb` (the command is
/// already dispatched and undo-classified).
struct WebOverlaySectionView: View {
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher
    @EnvironmentObject private var sceneStore: SceneStore
    @EnvironmentObject private var previewProgram: PreviewProgramModel
    @EnvironmentObject private var capturePool: CaptureSourcePool

    /// The single selected layer of the staged scene, when it is a web
    /// layer (the only layers these controls edit).
    private var selectedWebLayer: (layer: LayerNode, payload: WebSourcePayload)? {
        guard let scene = previewProgram.stagedScene,
              sceneStore.selectedLayerIDs.count == 1,
              let id = sceneStore.selectedLayerIDs.first,
              let layer = scene.layers.first(where: { $0.id == id }),
              case .web(let payload) = layer.payload
        else { return nil }
        return (layer, payload)
    }

    var body: some View {
        if let (layer, payload) = selectedWebLayer {
            sourceSection(layer: layer, payload: payload)
            captureSection(layer: layer)
            behaviorSection(layer: layer)
            cssSection(layer: layer)
            runtimeSection(payload: payload)
        }
    }

    // MARK: - Widget source (URL / local HTML / acceptance fixtures)

    private func sourceSection(layer: LayerNode, payload: WebSourcePayload) -> some View {
        Section("Browser Source — \(layer.name)") {
            let config = configBinding(for: layer)
            TextField("Widget URL (https://…)", text: urlStringBinding(for: layer))
            if let urlString = config.wrappedValue.urlString,
               !BrowserOverlayConfiguration.isSupportedWidgetURLString(urlString) {
                Text("Unsupported or malformed URL — the widget stays off until the URL is valid (http, https, or file).")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Picker("Local HTML Asset", selection: config.localHTMLAssetIdentifier) {
                Text("None (use URL)").tag(String?.none)
                // P03: HTML assets register in the Asset Library. The store
                // mounts with the asset panel (see BrowserOverlayAssetResolver
                // for the runtime wiring hook); until then this lists nothing
                // and the caption below explains the path.
            }
            Text("Local HTML assets come from the Asset Library (P03): import an .html file there, then pick it here — the library's sandbox bookmark is the widget's file-access grant.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                ForEach(BrowserOverlayHost.acceptanceFixtures, id: \.self) { name in
                    Button(fixtureLabel(name)) { applyFixture(name, to: layer) }
                        .buttonStyle(.borderless)
                }
            }
            .font(.caption)
            Text("Bundled test widgets (follow/glow alerts, ticker, audio) — the G07 acceptance fixtures.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Viewport and capture cadence

    private func captureSection(layer: LayerNode) -> some View {
        Section("Viewport & Capture") {
            let config = configBinding(for: layer)
            HStack {
                TextField("Width", value: config.pixelWidth, format: .number)
                TextField("Height", value: config.pixelHeight, format: .number)
            }
            Stepper("Capture: \(config.wrappedValue.targetFPS) fps",
                    value: config.targetFPS,
                    in: BrowserOverlayConfiguration.targetFPSRange)
            if config.wrappedValue.targetFPS == BrowserOverlayConfiguration.targetFPSRange.upperBound {
                Text("60 fps is the measured ceiling for DOM-light widgets only — snapshot read-back cost scales linearly with cadence (G07).")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("The page background is always transparent: widget pixels composite with their alpha; everything else shows the layers below.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Interaction / audio / scene-entry policy

    private func behaviorSection(layer: LayerNode) -> some View {
        Section("Behavior") {
            let config = configBinding(for: layer)
            Toggle("Deliberate Interaction Mode", isOn: config.allowsInteraction)
            if config.wrappedValue.allowsInteraction {
                Text("The widget surfaces as a floating panel that accepts clicks. Off (default), it is click-through and driven programmatically (Reload / Replay Alert).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker("Audio", selection: config.audioRoute) {
                Text("Muted (default)").tag(BrowserWidgetAudioRoute.muted)
                Text("System Mix").tag(BrowserWidgetAudioRoute.systemMix)
                Text("Helper App (independent channel)").tag(BrowserWidgetAudioRoute.helperApp)
            }
            if config.wrappedValue.audioRoute == .helperApp {
                Text("Independent gain needs the StreamWidgetHelper target — a G08 follow-up. Until it ships, the widget plays through the system mix.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if config.wrappedValue.audioRoute == .systemMix {
                Text("Widget audio reaches the program mix only when an A06 system-mix audio source is added; there is no per-widget gain on this route.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker("On Scene Entry", selection: config.sceneEntryRefresh) {
                ForEach(BrowserOverlaySceneEntryRefresh.allCases, id: \.self) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            if config.wrappedValue.sceneEntryRefresh == .reload {
                Text("The widget reloads when a scene containing it enters program — alert state restarts; the capture itself never restarts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - CSS overrides

    private func cssSection(layer: LayerNode) -> some View {
        Section("CSS Overrides") {
            TextEditor(text: configBinding(for: layer).cssOverrides)
                .frame(minHeight: 48, maxHeight: 120)
                .font(.system(.caption, design: .monospaced))
            Text("Injected as a `<style>` element at the end of every page load (max \(BrowserOverlayConfiguration.cssOverridesLimit / 1024) KB).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Runtime state and controls

    private func runtimeSection(payload: WebSourcePayload) -> some View {
        Section("Widget Runtime") {
            let key = CaptureSourceKey.web(payload)
            let state = capturePool.webStates[key] ?? .idle
            LabeledContent("State", value: state.badge)
            if let message = state.failureMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let host = capturePool.webHost(for: key) {
                WebHostStatusView(host: host)
                HStack {
                    Button("Reload") { host.reload() }
                    Button("Replay Alert") {
                        Task { _ = await host.replayAlertAnimation() }
                    }
                }
                .buttonStyle(.borderless)
                .disabled(state != .ready)
                if host.isOccluded {
                    Text("The hidden widget window is occluded — WebKit is throttling it. Bring a screen to the front or restart the widget.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let warning = host.routeWarning {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("The widget starts when this layer is visible in the staged or program scene and the pipeline is running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Bindings and writes

    /// The widget configuration the controls edit. Every set writes a
    /// complete payload through `.setLayerWeb` (undo-coalesced per layer).
    private func configBinding(for layer: LayerNode) -> Binding<BrowserOverlayConfiguration> {
        Binding(
            get: {
                if case .web(let payload) = layer.payload { return payload.browserOverlay }
                return BrowserOverlayConfiguration()
            },
            set: { config in
                guard case .web(var payload) = layer.payload else { return }
                payload.browserOverlay = config.normalized()
                dispatcher.execute(.setLayerWeb(layer.id, payload, in: nil))
            })
    }

    /// The URL text field: free typing stays local to the binding value;
    /// normalization (fail-closed scheme check) happens in the payload shim
    /// on write, so an in-progress edit never clears the field.
    private func urlStringBinding(for layer: LayerNode) -> Binding<String> {
        Binding(
            get: {
                if case .web(let payload) = layer.payload {
                    return payload.url?.absoluteString ?? ""
                }
                return ""
            },
            set: { raw in
                guard case .web(var payload) = layer.payload else { return }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                payload.url = trimmed.isEmpty ? nil : URL(string: trimmed)
                dispatcher.execute(.setLayerWeb(layer.id, payload, in: nil))
            })
    }

    /// Writes one bundled acceptance fixture onto the layer (a complete,
    /// normalized configuration — the fixture URL is the whole content
    /// change; the layer's other settings reset to the widget defaults).
    private func applyFixture(_ name: String, to layer: LayerNode) {
        guard case .web(var payload) = layer.payload,
              let config = BrowserOverlayHost.fixtureConfiguration(name: name)
        else { return }
        payload.browserOverlay = config
        dispatcher.execute(.setLayerWeb(layer.id, payload, in: nil))
    }

    private func fixtureLabel(_ name: String) -> String {
        switch name {
        case "alert-follow": return "Follow Alert"
        case "alert-glow": return "Glow Alert"
        case "ticker": return "Ticker"
        case "audio-widget": return "Audio Widget"
        default: return name
        }
    }
}

/// G08: the live counters of one running widget host — its own view so the
/// host's `@Published` metrics drive refresh without re-running the whole
/// section body on every snapshot completion.
private struct WebHostStatusView: View {
    @ObservedObject var host: BrowserOverlayHost

    var body: some View {
        LabeledContent("Capture",
                       value: String(format: "%.1f fps achieved · %d dropped",
                                     host.metrics.achievedFPS, host.metrics.dropped))
        .font(.caption)
    }
}
