import AVFAudio
import SwiftUI
import StreamCore

/// A08 (issue #120): the identity wrapper for the mixer strip's FX sheet
/// (`sheet(item:)` needs `Identifiable`; `AudioChannelID` is the identity).
struct FXRackTarget: Identifiable {
    let channel: AudioChannelID
    var id: String { channel.label }
}

/// A08 (issue #120): one channel's effect rack — the per-strip sheet where
/// the chain's preset, per-section bypass/reset, and parameters are edited.
/// A11 (issue #123) adds the hosted Audio Unit section between the
/// compressor and the limiter: add up to `maxSlotsPerChannel` installed
/// 'aufx' components, reorder, bypass, remove, and edit each loaded unit's
/// parameters through a native GENERIC editor (its `AUParameterTree` as
/// sliders/pickers — the issue's "native generic parameter controls" path;
/// a plugin's custom Cocoa/editor view is NOT embedded this wave, see
/// `audioUnitsSection`).
///
/// Every control dispatches `.setChannelFXChain` through the W05 dispatcher
/// (the rack edits no view-local state), so a Stream Deck action and a
/// slider say exactly the same thing, and every edit lands as a parameter
/// update on the channel's RUNNING insert — no capture restart, no audio
/// gap. The rack reads the EFFECTIVE chain from the dispatcher's state
/// (persisted chain, else the legacy voice-polish mapping), so the control
/// positions always reflect what the channel is actually running.
///
/// The fixed effect order is shown as a visible flow row (the issue's
/// "visible effect order" criterion), with hosted slots between Compressor
/// and Limiter, and the latency line reports the chain's added latency —
/// zero for the native sections by construction, plus any latency the
/// loaded hosted units REPORT (not compensated; see `HostedAudioUnitHandle`).
struct ChannelFXRackView: View {
    let channel: AudioChannelID
    let title: String

    @EnvironmentObject private var dispatcher: StudioCommandDispatcher
    @Environment(\.dismiss) private var dismiss

    /// A11: installed effects for the "Add Audio Unit" picker (loaded once
    /// per rack open).
    @State private var pluginList: [AudioUnitPluginInfo] = []
    /// A11: the hosted units actually RUNNING in the channel's graph, polled
    /// while the rack is open — a persisted slot with no handle did not load
    /// (plugin missing, load failure, or the channel idle).
    @State private var handles: [UUID: HostedAudioUnitHandle] = [:]
    /// A11: the slot whose generic parameter editor sheet is open, if any.
    @State private var parameterEditor: ParameterEditorTarget?

    /// The chain the channel runs right now (see `StudioState.fxChain`).
    private var chain: ChannelFXChain {
        dispatcher.state.fxChain(forLabel: channel.label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(title) — Effects")
                    .font(.headline)
                Spacer()
                Picker("Preset", selection: Binding(
                    get: { chain.preset },
                    set: { preset in
                        dispatcher.execute(.setChannelFXChain(channel, .preset(preset)))
                    }
                )) {
                    ForEach(ChannelFXPreset.allCases.filter { $0 != .custom }, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                    if chain.preset == .custom {
                        Text(ChannelFXPreset.custom.displayName).tag(ChannelFXPreset.custom)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
                Button("Done") { dismiss() }
            }

            orderFlow
            latencyLine

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    highPassSection
                    noiseGateSection
                    equalizerSection
                    compressorSection
                    audioUnitsSection
                    limiterSection
                }
            }
        }
        .padding(14)
        .frame(width: 400, height: 620)
        .task {
            pluginList = AudioUnitPluginCatalog.installedEffects()
            // Handles appear only once the channel's graph is running with
            // the slots attached — poll while the rack is open so a slot
            // added mid-stream flips to "loaded" without reopening the rack.
            while !Task.isCancelled {
                handles = dispatcher.hostedAudioUnitHandles(forLabel: channel.label)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        .sheet(item: $parameterEditor) { target in
            parameterEditorSheet(for: target)
        }
    }

    // MARK: - Visible effect order

    /// The processing order as a flow of chips — the fixed native sections
    /// with the hosted Audio Units in their chain position (after the
    /// compressor, before the limiter); enabled chips are filled, bypassed
    /// ones hollow, so the strip's signal path is legible at a glance.
    private var orderFlow: some View {
        var chips: [(name: String, enabled: Bool)] = [
            ("High-Pass", chain.highPass.isEnabled),
            ("Noise Gate", chain.noiseGate.isEnabled),
            ("EQ", chain.equalizer.isEnabled),
            ("Compressor", chain.compressor.isEnabled)
        ]
        chips += chain.audioUnits.map { (Self.shortName($0.component.displayName), $0.isEnabled) }
        chips.append(("Limiter", chain.limiter.isEnabled))
        return HStack(spacing: 4) {
            ForEach(Array(chips.enumerated()), id: \.offset) { index, chip in
                if index > 0 {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(chip.name)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(chip.enabled ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08),
                                in: Capsule())
                    .foregroundStyle(chip.enabled ? .primary : .secondary)
            }
        }
    }

    /// Native sections add zero latency by construction (the processor
    /// renders exactly the input frame count); loaded hosted units may
    /// REPORT latency, surfaced here honestly (not compensated — the A10
    /// channel delay can counter it when it matters).
    private var latencyLine: some View {
        let hostedLatency = chain.audioUnits
            .compactMap { handles[$0.id]?.latencySeconds }
            .reduce(0, +)
        let text = hostedLatency > 0.0005
            ? String(format: "Added latency: %.1f ms reported by hosted Audio Units (not compensated). Native sections add 0 ms.", hostedLatency * 1_000)
            : "Added latency: 0 ms — sections render in place, so toggling an effect never changes the channel's timing or channel count."
        return Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    // MARK: - Sections (fixed order: high-pass → gate → EQ → comp → limiter)

    private var highPassSection: some View {
        section(title: "High-Pass", isOn: chain.highPass.isEnabled,
                onToggle: { on in update { $0.highPass.isEnabled = on } },
                onReset: { update { $0.highPass = ChannelFXChain.preset($0.preset).highPass } }) {
            sliderRow("Frequency", value: chain.highPass.frequency, range: 20...400,
                      step: 5, format: { "\(Int($0)) Hz" },
                      disabled: !chain.highPass.isEnabled) { value in
                update { $0.highPass.frequency = value }
            }
        }
    }

    private var noiseGateSection: some View {
        section(title: "Noise Gate", isOn: chain.noiseGate.isEnabled,
                onToggle: { on in update { $0.noiseGate.isEnabled = on } },
                onReset: { update { $0.noiseGate = ChannelFXChain.preset($0.preset).noiseGate } }) {
            sliderRow("Threshold", value: chain.noiseGate.threshold, range: -80 ... -20,
                      step: 1, format: { "\(Int($0)) dB" },
                      disabled: !chain.noiseGate.isEnabled) { value in
                update { $0.noiseGate.threshold = value }
            }
            Text("Native gate is a downward expander; for broadband denoise add an Audio Unit below (A11).")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var equalizerSection: some View {
        section(title: "EQ", isOn: chain.equalizer.isEnabled,
                onToggle: { on in update { $0.equalizer.isEnabled = on } },
                onReset: { update { $0.equalizer = ChannelFXChain.preset($0.preset).equalizer } }) {
            sliderRow("Low (250 Hz)", value: chain.equalizer.lowGain, range: -12...12,
                      step: 0.5, format: Self.decibels,
                      disabled: !chain.equalizer.isEnabled) { value in
                update { $0.equalizer.lowGain = value }
            }
            sliderRow("Mid Freq", value: chain.equalizer.midFrequency, range: 200...4_000,
                      step: 50, format: { "\(Int($0)) Hz" },
                      disabled: !chain.equalizer.isEnabled) { value in
                update { $0.equalizer.midFrequency = value }
            }
            sliderRow("Mid Gain", value: chain.equalizer.midGain, range: -12...12,
                      step: 0.5, format: Self.decibels,
                      disabled: !chain.equalizer.isEnabled) { value in
                update { $0.equalizer.midGain = value }
            }
            sliderRow("High (6 kHz)", value: chain.equalizer.highGain, range: -12...12,
                      step: 0.5, format: Self.decibels,
                      disabled: !chain.equalizer.isEnabled) { value in
                update { $0.equalizer.highGain = value }
            }
        }
    }

    private var compressorSection: some View {
        section(title: "Compressor", isOn: chain.compressor.isEnabled,
                onToggle: { on in update { $0.compressor.isEnabled = on } },
                onReset: { update { $0.compressor = ChannelFXChain.preset($0.preset).compressor } }) {
            sliderRow("Threshold", value: chain.compressor.threshold, range: -40...0,
                      step: 1, format: { "\(Int($0)) dB" },
                      disabled: !chain.compressor.isEnabled) { value in
                update { $0.compressor.threshold = value }
            }
            sliderRow("Ratio", value: chain.compressor.ratio, range: 1...10,
                      step: 0.5, format: { String(format: "%.1f:1", $0) },
                      disabled: !chain.compressor.isEnabled) { value in
                update { $0.compressor.ratio = value }
            }
            sliderRow("Attack", value: chain.compressor.attackMs, range: 1...200,
                      step: 1, format: { "\(Int($0)) ms" },
                      disabled: !chain.compressor.isEnabled) { value in
                update { $0.compressor.attackMs = value }
            }
            sliderRow("Release", value: chain.compressor.releaseMs, range: 20...2_000,
                      step: 10, format: { "\(Int($0)) ms" },
                      disabled: !chain.compressor.isEnabled) { value in
                update { $0.compressor.releaseMs = value }
            }
            sliderRow("Makeup", value: chain.compressor.makeupGain, range: 0...24,
                      step: 0.5, format: Self.decibels,
                      disabled: !chain.compressor.isEnabled) { value in
                update { $0.compressor.makeupGain = value }
            }
        }
    }

    // MARK: - A11 hosted Audio Units (compressor → [slots] → limiter)

    /// The hosted-AU rack: ordered slots with bypass, reorder, remove, an
    /// "Add Audio Unit" picker fed by the system component registry, and a
    /// per-slot generic parameter editor for loaded units.
    ///
    /// **Editor choice (documented for the issue):** parameters are edited
    /// through the unit's `AUParameterTree` as native sliders/pickers — the
    /// issue's "native generic parameter controls" alternative. A plugin's
    /// own Cocoa/editor view is deliberately NOT embedded: v2 custom views
    /// are in-process AppKit code with no failure isolation, and v3
    /// `requestViewController` coverage is spotty across the installed-base
    /// the rack must host. Every hosted unit exposes a parameter tree, so
    /// the generic editor covers all of them.
    private var audioUnitsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Audio Units")
                    .font(.callout.weight(.semibold))
                Spacer()
                Menu("Add…") {
                    if pluginList.isEmpty {
                        Text("No Audio Unit effects found")
                    }
                    ForEach(pluginList) { info in
                        Button("\(info.manufacturerName) — \(info.shortName)") {
                            addAudioUnit(info)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .controlSize(.mini)
                .fixedSize()
                .disabled(chain.audioUnits.count >= HostedAudioUnitSlot.maxSlotsPerChannel)
                .help("Add an installed Audio Unit effect (up to \(HostedAudioUnitSlot.maxSlotsPerChannel) per channel), inserted after the compressor")
            }

            if chain.audioUnits.isEmpty {
                Text("No hosted plugins. Added units run after the compressor, before the limiter.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(chain.audioUnits) { slot in
                audioUnitRow(slot)
            }
        }
    }

    /// One hosted slot: bypass toggle, reorder/remove, parameter editor, and
    /// an honest load-status line (loaded + latency / not installed /
    /// not loaded).
    private func audioUnitRow(_ slot: HostedAudioUnitSlot) -> some View {
        let index = chain.audioUnits.firstIndex(where: { $0.id == slot.id }) ?? 0
        let handle = handles[slot.id]
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Toggle(Self.shortName(slot.component.displayName), isOn: Binding(
                    get: { slot.isEnabled },
                    set: { on in updateAudioUnits { $0[index].isEnabled = on } }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
                Spacer()
                Button { parameterEditor = ParameterEditorTarget(slotID: slot.id) } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .disabled(handle == nil)
                .help(handle == nil ? "Parameters are available once the plugin is loaded" : "Edit plugin parameters")
                Button { moveAudioUnit(at: index, by: -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .disabled(index == 0)
                Button { moveAudioUnit(at: index, by: 1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .disabled(index == chain.audioUnits.count - 1)
                Button { updateAudioUnits { $0.remove(at: index) } } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .help("Remove from this channel's chain")
            }
            Text(statusLine(for: slot, handle: handle))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Honest per-slot status: which of loaded / missing / not-loaded the
    /// running graph reports. A missing plugin keeps its slot (settings,
    /// order, state blob) so reinstalling it restores the chain exactly.
    private func statusLine(for slot: HostedAudioUnitSlot,
                            handle: HostedAudioUnitHandle?) -> String {
        if let handle {
            if handle.latencySeconds > 0.0005 {
                return String(format: "Loaded — reports %.1f ms latency (not compensated)",
                              handle.latencySeconds * 1_000)
            }
            return "Loaded"
        }
        if !slot.component.isAvailable {
            return "Plugin not installed — slot kept, bypassed; the rest of the chain still runs"
        }
        return "Not loaded — the channel is idle or the plugin failed to load; the rest of the chain still runs"
    }

    // MARK: - A11 generic parameter editor

    /// The attached sheet with the unit's `AUParameterTree` as native
    /// controls. Writes go straight to the running unit (the parameter tree
    /// is the AU's thread-safe control surface); on dismiss the unit's
    /// `fullState` is captured into the persisted chain so the next launch
    /// (or graph rebuild) restores exactly these settings.
    @ViewBuilder
    private func parameterEditorSheet(for target: ParameterEditorTarget) -> some View {
        if let slot = chain.audioUnits.first(where: { $0.id == target.slotID }),
           let handle = handles[target.slotID] {
            HostedAUParameterEditorView(
                title: Self.shortName(slot.component.displayName),
                handle: handle,
                onSaveState: { state in saveSlotState(slotID: slot.id, state: state) }
            )
        } else {
            Text("This plugin is not loaded.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(24)
                .frame(width: 320)
        }
    }

    /// Captures the running unit's state into the persisted chain. Does NOT
    /// flip the preset marker — plugin state is orthogonal to the native
    /// section presets.
    private func saveSlotState(slotID: UUID, state: Data?) {
        var edited = chain
        guard let index = edited.audioUnits.firstIndex(where: { $0.id == slotID }) else { return }
        edited.audioUnits[index].state = state
        dispatcher.execute(.setChannelFXChain(channel, edited))
    }

    private func addAudioUnit(_ info: AudioUnitPluginInfo) {
        updateAudioUnits { $0.append(HostedAudioUnitSlot(component: info.component)) }
    }

    private func moveAudioUnit(at index: Int, by offset: Int) {
        updateAudioUnits { slots in
            let target = index + offset
            guard slots.indices.contains(index), slots.indices.contains(target) else { return }
            slots.swapAt(index, target)
        }
    }

    /// Routes a hosted-slot edit (add/remove/reorder/bypass) through the
    /// dispatcher WITHOUT flipping the preset marker — presets describe the
    /// native sections, slots are orthogonal. A structure change rebuilds
    /// the channel's graph in place (between buffers, no capture restart).
    private func updateAudioUnits(_ edit: (inout [HostedAudioUnitSlot]) -> Void) {
        var edited = chain
        edit(&edited.audioUnits)
        dispatcher.execute(.setChannelFXChain(channel, edited))
    }

    /// "Manufacturer: Name" → "Name" (the rack groups by nothing, so the
    /// manufacturer prefix is noise in the flow chips and slot rows).
    private static func shortName(_ displayName: String) -> String {
        guard let colon = displayName.firstIndex(of: ":") else { return displayName }
        return displayName[displayName.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }

    private var limiterSection: some View {
        section(title: "Limiter", isOn: chain.limiter.isEnabled,
                onToggle: { on in update { $0.limiter.isEnabled = on } },
                onReset: { update { $0.limiter = ChannelFXChain.preset($0.preset).limiter } }) {
            sliderRow("Ceiling", value: chain.limiter.ceiling, range: -12...0,
                      step: 0.5, format: Self.decibels,
                      disabled: !chain.limiter.isEnabled) { value in
                update { $0.limiter.ceiling = value }
            }
        }
    }

    // MARK: - Shared section/control chrome

    /// One rack section: enable toggle (bypass) + Reset (restore the current
    /// preset's defaults for this section) above the section's controls.
    private func section<Content: View>(title: String, isOn: Bool,
                                        onToggle: @escaping (Bool) -> Void,
                                        onReset: @escaping () -> Void,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(title, isOn: Binding(get: { isOn }, set: onToggle))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.callout.weight(.semibold))
                Spacer()
                Button("Reset", action: onReset)
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .foregroundStyle(.secondary)
                    .help("Restore this section's \(chain.preset == .custom ? "default" : "\(chain.preset.displayName) preset") values")
            }
            content()
        }
    }

    private func sliderRow(_ label: String, value: Double, range: ClosedRange<Double>,
                           step: Double, format: (Double) -> String,
                           disabled: Bool,
                           onChange: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .frame(width: 90, alignment: .leading)
            Slider(value: Binding(get: { value }, set: onChange), in: range, step: step)
            Text(format(value))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    private static func decibels(_ value: Double) -> String {
        String(format: "%+.1f dB", value)
    }

    /// Routes one chain edit through the dispatcher. Any manual tweak marks
    /// the chain `.custom` so the preset picker shows honestly that the
    /// values no longer match a named preset.
    private func update(_ edit: (inout ChannelFXChain) -> Void) {
        var edited = chain
        edit(&edited)
        edited.preset = .custom
        dispatcher.execute(.setChannelFXChain(channel, edited))
    }
}

/// A11 (issue #123): the slot whose generic parameter editor sheet is open
/// (`sheet(item:)` needs `Identifiable`; the slot ID is the identity).
private struct ParameterEditorTarget: Identifiable {
    let slotID: UUID
    var id: UUID { slotID }
}

/// A11 (issue #123): the native generic parameter editor for one loaded
/// hosted Audio Unit — the unit's `AUParameterTree` rendered as sliders
/// (continuous parameters) and pickers (indexed parameters), with the
/// AU-reported unit name on the value readout.
///
/// Writes go straight to the RUNNING unit via `setValue(_:originator:)` —
/// the parameter tree is the AU's thread-safe control surface, the same
/// in-place write path the processor uses for the native sections — so an
/// edit is audible immediately with no chain dispatch and no graph rebuild.
/// Persistence happens on Done: the unit's `fullState` is captured and
/// handed back for storage in the chain slot (documented on
/// `HostedAudioUnitSlot`). A plugin whose state is not plist-safe saves
/// nothing and reopens at its own defaults — said honestly in the footer.
private struct HostedAUParameterEditorView: View {
    let title: String
    let handle: HostedAudioUnitHandle
    let onSaveState: (Data?) -> Void

    @Environment(\.dismiss) private var dismiss
    /// Snapshot of the tree taken on appear (the tree itself is live; the
    /// LIST of parameters is stable for a loaded unit).
    @State private var parameters: [AUParameter] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(title) — Parameters")
                    .font(.headline)
                Spacer()
                Button("Done") { saveAndClose() }
            }
            if parameters.isEmpty {
                Text("This plugin exposes no parameters.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(parameters, id: \.address) { parameter in
                            parameterRow(parameter)
                        }
                    }
                }
            }
            Text("Edits are live. The plugin's settings are saved into the channel's chain when you close this panel; a plugin that cannot serialize its settings reopens at its defaults.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 420, height: 480)
        .onAppear {
            parameters = handle.audioUnit.parameterTree?.allParameters ?? []
        }
    }

    @ViewBuilder
    private func parameterRow(_ parameter: AUParameter) -> some View {
        HStack {
            Text(parameter.displayName)
                .font(.caption)
                .frame(width: 130, alignment: .leading)
                .lineLimit(1)
            if parameter.unit == .indexed, let valueStrings = parameter.valueStrings,
               !valueStrings.isEmpty {
                Picker(parameter.displayName, selection: Binding(
                    get: { parameter.value },
                    set: { parameter.setValue($0, originator: nil) }
                )) {
                    ForEach(Array(valueStrings.enumerated()), id: \.offset) { index, label in
                        Text(label).tag(Float(index))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            } else {
                Slider(value: Binding(
                    get: { Double(parameter.value) },
                    set: { parameter.setValue(Float($0), originator: nil) }
                ), in: Double(parameter.minValue)...Double(max(parameter.maxValue, parameter.minValue + 0.001)))
                Text(formattedValue(parameter))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 84, alignment: .trailing)
            }
        }
    }

    private func formattedValue(_ parameter: AUParameter) -> String {
        let value = String(format: "%.2f", parameter.value)
        guard let unitName = parameter.unitName, !unitName.isEmpty else { return value }
        return "\(value) \(unitName)"
    }

    /// Captures the unit's `fullState` (plist-safe subset only) and hands it
    /// back for persistence, then closes.
    private func saveAndClose() {
        onSaveState(HostedAudioUnitSlot.encodeState(handle.audioUnit.fullState))
        dismiss()
    }
}
