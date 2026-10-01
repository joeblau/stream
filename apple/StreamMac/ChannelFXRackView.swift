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
/// "visible effect order" criterion), and the latency line reports the
/// chain's added latency — zero, by construction (the processor renders
/// exactly the input frame count per buffer).
struct ChannelFXRackView: View {
    let channel: AudioChannelID
    let title: String

    @EnvironmentObject private var dispatcher: StudioCommandDispatcher
    @Environment(\.dismiss) private var dismiss

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
            Text("Added latency: 0 ms — sections render in place, so toggling an effect never changes the channel's timing or channel count.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    highPassSection
                    noiseGateSection
                    equalizerSection
                    compressorSection
                    limiterSection
                }
            }
        }
        .padding(14)
        .frame(width: 400, height: 560)
    }

    // MARK: - Visible effect order

    /// The fixed processing order as a flow of chips; enabled sections are
    /// filled, bypassed ones hollow, so the strip's signal path is legible
    /// at a glance.
    private var orderFlow: some View {
        let enabled: [Bool] = [
            chain.highPass.isEnabled,
            chain.noiseGate.isEnabled,
            chain.equalizer.isEnabled,
            chain.compressor.isEnabled,
            chain.limiter.isEnabled
        ]
        return HStack(spacing: 4) {
            ForEach(Array(zip(ChannelFXChain.effectOrder, enabled).enumerated()),
                    id: \.offset) { index, pair in
                if index > 0 {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(pair.0)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(pair.1 ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08),
                                in: Capsule())
                    .foregroundStyle(pair.1 ? .primary : .secondary)
            }
        }
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
            Text("Native gate is a downward expander; broadband denoise needs an Audio Unit (not yet hosted — A11).")
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
