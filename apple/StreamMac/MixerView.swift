import SwiftUI
import StreamCore

/// A04 (issue #83): the embedded mixer — the inspector's Mixer tab, one
/// channel strip per active audio source plus the program/monitor masters,
/// with no floating window.
///
/// **Where strip state lives.** Every control routes through the W05
/// dispatcher; the strips read `dispatcher.state.mixer` (the persisted A04
/// mixer document) and `dispatcher.state.micVolume`. Two channel families:
///
/// - **Non-capture channels** (the mic today; media/application/guest as
///   those surfaces land): fader/mute are mixer session state —
///   `.setChannelVolume` / `.setChannelMuted` — persisted in the mixer
///   document and applied live (ramped) to the engine.
/// - **Capture channels** (screen-source audio): program level and mute are
///   scene content — the S05 `AudioBinding`s. The strip's fader edits the
///   STAGED scene's binding (`.setLayerAudio`), so the W03 rules hold
///   untouched: staged edits reach program via Take, and the program scene
///   drives the actual mix. Solo and aux send are routing/mixer state, so
///   capture channels take those directly.
///
/// **Solo is monitor-only** (the issue's criterion): while any channel is
/// soloed the MONITOR bus carries only the soloed channels' post-fader
/// signal; the PROGRAM bus — what the stream and recording emit — is never
/// affected. A07 owns attaching a monitor output device; the solo surface
/// and the independent monitor master gain are ready for it here.
///
/// **Metering** (polled from the engine at ~20 Hz while the tab is visible):
/// channel meters are PRE-FADER (post-insert) so a muted or binding-ducked
/// source still shows its live signal; bus meters are POST-FADER, POST-GAIN,
/// PRE-CLAMP so the master meter shows exactly the mixed signal and its clip
/// latch means the engine's safety clamp engaged.
///
/// **State honesty:** strips never vanish mid-stream. A channel the engine
/// stops reporting (its capture left demand) stays in the strip order,
/// dimmed and marked inactive, and resumes when the source returns.
struct MixerPanelView: View {
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher
    @EnvironmentObject private var controller: StreamController
    @EnvironmentObject private var sceneStore: SceneStore
    @EnvironmentObject private var previewProgram: PreviewProgramModel

    /// The latest engine meter snapshot (polled while the tab is visible).
    @State private var levels = AudioEngineLevels()
    /// Every channel the mixer has shown this session, in stable strip order:
    /// the mic first, then capture channels in source-registry order, then
    /// anything else the engine reports (media/app/guest as they land).
    @State private var channelOrder: [AudioChannelID] = [Self.micID]
    /// A08 (issue #120): the channel whose FX rack sheet is open, if any.
    @State private var fxRack: FXRackTarget?

    private static let micID = AudioChannelID.microphone(deviceUID: nil)
    /// Vertical fader travel in points.
    private static let faderTravel: CGFloat = 120

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(channelOrder, id: \.self) { id in
                    channelStrip(for: id)
                }
                Divider()
                    .frame(height: Self.faderTravel + 44)
                busStrip(title: "Program", bus: .program)
                busStrip(title: "Monitor", bus: .monitor)
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await pollLevels() }
        .sheet(item: $fxRack) { target in
            ChannelFXRackView(channel: target.channel, title: name(for: target.channel))
        }
        .onAppear {
            mergeExpectedCaptureChannels()
            mergeExpectedMicChannels()
        }
        .onChange(of: sceneStore.sources) { _, _ in mergeExpectedCaptureChannels() }
    }

    // MARK: - Level polling (~20 Hz while the tab is visible)

    private func pollLevels() async {
        while !Task.isCancelled {
            let snapshot = await controller.mixerLevels()
            levels = snapshot
            mergeSeenChannels(snapshot.channels.keys)
            mergeExpectedMicChannels()
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// A05 (issue #84): enabled additional input devices get a strip even
    /// before their first audio buffer lands — and keep it while unplugged
    /// (inactive, with relink controls), so hot-plug never reshuffles the
    /// board. Read from the audio input layer's armed selections.
    private func mergeExpectedMicChannels() {
        for selection in controller.audio.additionalInputs {
            let id = AudioChannelID.microphone(deviceUID: selection.deviceUID)
            if !channelOrder.contains(id) { channelOrder.append(id) }
        }
    }

    /// Screen sources the registry knows about get a strip even before their
    /// first audio buffer lands (inactive until the engine reports them).
    private func mergeExpectedCaptureChannels() {
        for source in sceneStore.sources {
            guard case .screen(let screen) = source.payload else { continue }
            let id = AudioChannelID.capture(.screen(screen))
            if !channelOrder.contains(id) { channelOrder.append(id) }
        }
    }

    /// Channels the engine reports that nothing else predicted (media,
    /// application, guest) append in stable label order.
    private func mergeSeenChannels(_ ids: some Sequence<AudioChannelID>) {
        for id in ids.sorted(by: { $0.label < $1.label }) where !channelOrder.contains(id) {
            channelOrder.append(id)
        }
    }

    // MARK: - Channel strips

    @ViewBuilder
    private func channelStrip(for id: AudioChannelID) -> some View {
        let mixer = dispatcher.state.mixer
        let meterLevels = levels.channels[id]
        let isSoloed = mixer.soloedChannels.contains(id.label)
        let auxOn = (mixer.channelAuxSends[id.label] ?? 0) > 0
        switch id {
        case .microphone(let uid):
            if let uid {
                // A05 (issue #84): an additional (UID-pinned) input device.
                // Its fader reads the mixer document (micVolume is the
                // DEFAULT mic's fader), and while the device is unplugged the
                // strip shows honestly inactive with a relink control (C10:
                // never silently substitute another input).
                let missing = controller.audio.missingAdditionalDeviceUIDs.contains(uid)
                VStack(spacing: 2) {
                    strip(title: controller.audio.deviceNamesByUID[uid] ?? "Input",
                          meterLevels: missing ? nil : meterLevels,
                          volume: mixer.channelVolumes[id.label] ?? 1, range: 0...2,
                          isMuted: mixer.channelMutes[id.label] ?? false,
                          isSoloed: isSoloed, auxOn: auxOn,
                          controlsEnabled: !missing,
                          onVolume: { dispatcher.execute(.setChannelVolume(id, $0)) },
                          onMute: { dispatcher.execute(.setChannelMuted(id, $0)) },
                          onSolo: { dispatcher.execute(.setChannelSolo(id, $0)) },
                          onAux: { dispatcher.execute(.setChannelAuxSend(id, $0 ? 1 : 0)) })
                    fxButton(for: id)
                    if missing { relinkMenu(for: uid) }
                }
            } else {
                VStack(spacing: 2) {
                    strip(title: "Microphone",
                          meterLevels: meterLevels,
                          volume: dispatcher.state.micVolume, range: 0...2,
                          isMuted: mixer.channelMutes[id.label] ?? false,
                          isSoloed: isSoloed, auxOn: auxOn, controlsEnabled: true,
                          onVolume: { dispatcher.execute(.setChannelVolume(id, $0)) },
                          onMute: { dispatcher.execute(.setChannelMuted(id, $0)) },
                          onSolo: { dispatcher.execute(.setChannelSolo(id, $0)) },
                          onAux: { dispatcher.execute(.setChannelAuxSend(id, $0 ? 1 : 0)) })
                    fxButton(for: id)
                }
            }
        case .capture(let key):
            let binding = captureBinding(for: key)
            strip(title: name(for: id),
                  meterLevels: meterLevels,
                  volume: binding?.audio.volume ?? 0, range: 0...1,
                  isMuted: binding?.audio.isMuted ?? false,
                  isSoloed: isSoloed, auxOn: auxOn,
                  controlsEnabled: binding != nil,
                  onVolume: { volume in
                      guard let binding else { return }
                      var audio = binding.audio
                      audio.volume = volume
                      dispatcher.execute(.setLayerAudio(binding.layerID, audio, in: nil))
                  },
                  onMute: { muted in
                      guard let binding else { return }
                      var audio = binding.audio
                      audio.isMuted = muted
                      dispatcher.execute(.setLayerAudio(binding.layerID, audio, in: nil))
                  },
                  onSolo: { dispatcher.execute(.setChannelSolo(id, $0)) },
                  onAux: { dispatcher.execute(.setChannelAuxSend(id, $0 ? 1 : 0)) })
        case .media, .application, .guest:
            strip(title: name(for: id),
                  meterLevels: meterLevels,
                  volume: mixer.channelVolumes[id.label] ?? 1, range: 0...2,
                  isMuted: mixer.channelMutes[id.label] ?? false,
                  isSoloed: isSoloed, auxOn: auxOn, controlsEnabled: true,
                  onVolume: { dispatcher.execute(.setChannelVolume(id, $0)) },
                  onMute: { dispatcher.execute(.setChannelMuted(id, $0)) },
                  onSolo: { dispatcher.execute(.setChannelSolo(id, $0)) },
                  onAux: { dispatcher.execute(.setChannelAuxSend(id, $0 ? 1 : 0)) })
        }
    }

    /// The first VISIBLE staged-scene layer bound to this capture key — the
    /// same resolution order the controller uses to push program gains (first
    /// visible binding wins), so the strip shows and edits exactly the binding
    /// that will drive the mix on Take.
    private func captureBinding(for key: CaptureSourceKey) -> (layerID: LayerID, audio: AudioBinding)? {
        guard let staged = previewProgram.stagedScene else { return nil }
        let registry = SceneGraph.index(sceneStore.scenes)
        for layer in SceneGraph.flattenedVisibleLayers(of: staged, in: registry) {
            let payload = layer.sourceID
                .flatMap { id in sceneStore.sources.first(where: { $0.id == id }) }?.payload
                ?? layer.payload
            guard case .screen(let screen) = payload, CaptureSourceKey.screen(screen) == key
            else { continue }
            return (layer.id, layer.audio)
        }
        return nil
    }

    /// A08 (issue #120): opens the channel's FX rack sheet (preset, per-
    /// section bypass/reset, live parameters, A11 hosted Audio Units).
    /// Tinted while any section is active so the strip shows processing at
    /// a glance. Mic channels only — capture/media/app/guest channels have
    /// no insert chain yet.
    private func fxButton(for id: AudioChannelID) -> some View {
        let active = dispatcher.state.fxChain(forLabel: id.label).isActive
        return Button("FX") { fxRack = FXRackTarget(channel: id) }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .tint(active ? .purple : nil)
            .help("Per-channel effects: high-pass, noise gate, EQ, compressor, Audio Units, limiter — applied live")
    }

    /// A05: the explicit relink path for an unplugged input device — pick a
    /// currently-connected device; the input's enable/mapping carry over
    /// (the same uniqueID returning would have resumed automatically).
    private func relinkMenu(for uid: String) -> some View {
        let candidates = controller.deviceMonitor.audioDevices.filter { device in
            device.uniqueID != uid && !controller.audio.additionalInputs.contains {
                $0.deviceUID == device.uniqueID && $0.isEnabled
            }
        }
        return Menu("Relink…") {
            if candidates.isEmpty {
                Text("No other inputs connected")
            } else {
                ForEach(candidates, id: \.uniqueID) { device in
                    Button(device.localizedName) {
                        dispatcher.execute(.relinkAudioInput(from: uid, to: device.uniqueID))
                    }
                }
            }
        }
        .font(.caption2)
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Bus (master) strips

    private func busStrip(title: String, bus: AudioBus) -> some View {
        let mixer = dispatcher.state.mixer
        let gain = mixer.busGains[bus.rawValue] ?? 1
        let muted = mixer.mutedBuses.contains(bus.rawValue)
        let soloActive = bus == .monitor && !mixer.soloedChannels.isEmpty
        return strip(title: title,
                     meterLevels: levels.buses[bus],
                     volume: gain, range: 0...2,
                     isMuted: muted,
                     isSoloed: false, auxOn: false, controlsEnabled: true,
                     showSolo: false, showAux: false,
                     badge: soloActive ? "SOLO" : nil,
                     onVolume: { dispatcher.execute(.setBusGain(bus, $0)) },
                     onMute: { dispatcher.execute(.setBusMuted(bus, $0)) },
                     onSolo: { _ in }, onAux: { _ in })
    }

    // MARK: - The shared strip layout

    private func strip(title: String,
                       meterLevels: AudioLevels?,
                       volume: Double, range: ClosedRange<Double>,
                       isMuted: Bool, isSoloed: Bool, auxOn: Bool,
                       controlsEnabled: Bool,
                       showSolo: Bool = true, showAux: Bool = true,
                       badge: String? = nil,
                       onVolume: @escaping (Double) -> Void,
                       onMute: @escaping (Bool) -> Void,
                       onSolo: @escaping (Bool) -> Void,
                       onAux: @escaping (Bool) -> Void) -> some View {
        let isActive = meterLevels != nil
        return VStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 5) {
                // macOS SwiftUI has no vertical slider: lay out horizontal,
                // then rotate and re-frame so the layout box matches.
                Slider(value: Binding(get: { volume }, set: onVolume), in: range)
                    .frame(width: Self.faderTravel)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 24, height: Self.faderTravel)
                    .disabled(!controlsEnabled)
                MeterBar(levels: meterLevels ?? AudioLevels())
                    .frame(width: 10, height: Self.faderTravel)
            }
            Text(Self.gainLabel(volume))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                stripButton("M", active: isMuted, tint: .orange) { onMute(!isMuted) }
                    .disabled(!controlsEnabled)
                    .help(isMuted ? "Unmute" : "Mute")
                if showSolo {
                    stripButton("S", active: isSoloed, tint: .yellow) { onSolo(!isSoloed) }
                        .help(isSoloed
                              ? "Clear solo"
                              : "Monitor-only solo — the program output is unaffected")
                }
                if showAux {
                    stripButton("AUX", active: auxOn, tint: .blue) { onAux(!auxOn) }
                        .help(auxOn ? "Remove from the aux/guest-return bus"
                                    : "Route to the aux/guest-return bus at unity")
                }
            }
            Group {
                if let badge {
                    Text(badge)
                        .foregroundStyle(.yellow)
                } else if !isActive {
                    Text("inactive")
                        .foregroundStyle(.secondary)
                } else {
                    Text(" ")
                }
            }
            .font(.caption2.weight(.semibold))
        }
        .frame(width: 76)
        .opacity(isActive ? 1 : 0.45)
    }

    private func stripButton(_ title: String, active: Bool, tint: Color,
                             action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .tint(active ? tint : nil)
    }

    // MARK: - Names and readouts

    private func name(for id: AudioChannelID) -> String {
        switch id {
        case .microphone(let uid):
            guard let uid else { return "Microphone" }
            return controller.audio.deviceNamesByUID[uid] ?? "Microphone"
        case .capture(let key):
            if case .screen(let screen) = key,
               let source = sceneStore.sources.first(where: { $0.payload == .screen(screen) }) {
                return source.name
            }
            return "Screen"
        case .media: return "Media"
        case .application(let bundleID):
            // A06 (issue #118): resolve the registry source's name so the
            // strip reads "Spotify"/"System Audio", not a bundle-ID fragment.
            for source in sceneStore.sources {
                if case .appAudio(let payload) = source.payload,
                   payload.channelBundleID == bundleID {
                    return source.name
                }
            }
            return bundleID.components(separatedBy: ".").last ?? bundleID
        case .guest(let id): return "Guest \(id.prefix(4))"
        }
    }

    /// A fader position as a dB readout (unity = +0.0 dB, 0 = −∞).
    private static func gainLabel(_ volume: Double) -> String {
        volume <= 0.0009 ? "−∞" : String(format: "%+.1f dB", 20 * log10(volume))
    }
}

/// A04: one vertical meter bar — peak fill (green→yellow→red over a 60 dB
/// window), a white RMS marker line, and a red clip segment at the top that
/// stays lit while the engine's clip latch holds.
private struct MeterBar: View {
    let levels: AudioLevels

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.primary.opacity(0.12))
                LinearGradient(colors: [.green, .green, .yellow, .red],
                               startPoint: .bottom, endPoint: .top)
                    .mask(alignment: .bottom) {
                        Rectangle()
                            .frame(height: height * Self.fraction(levels.peak))
                            .frame(maxWidth: .infinity)
                    }
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.white.opacity(0.85))
                    .frame(height: 1.5)
                    .padding(.bottom, max(0, height * Self.fraction(levels.rms) - 1.5))
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(levels.isClipping ? Color.red : Color.primary.opacity(0.25))
                    .frame(height: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }

    /// Linear level → 0…1 over a −60…0 dBFS window (values above full scale
    /// pin at the top, where the clip segment takes over the story).
    static func fraction(_ linear: Float) -> CGFloat {
        guard linear > 0 else { return 0 }
        let decibels = 20 * log10(linear)
        return CGFloat(min(1, max(0, (decibels + 60) / 60)))
    }
}
