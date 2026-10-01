import SwiftUI
import StreamCore

/// Hosted in the existing Sources inspector; configuration is staged and
/// undoable, while transport acts on the shared session clock immediately.
struct DynamicOverlaySectionView: View {
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher
    let layer: LayerNode
    let payload: TextSourcePayload

    var body: some View {
        Section("Dynamic Text") {
            Picker("Content", selection: mode) {
                Text("Text").tag(0)
                Text("Timer").tag(1)
                Text("Ticker").tag(2)
            }
            if let timer = payload.timer {
                timerControls(timer)
                if timer.kind.usesTransport { transport(id: timer.runtimeID, autoplay: false) }
                sharedPlayback(id: timer.runtimeID)
            }
            if let ticker = payload.ticker {
                Picker("Direction", selection: tickerBinding(\.direction)) {
                    Text("Scroll Left").tag(TickerDirection.left)
                    Text("Scroll Right").tag(TickerDirection.right)
                }
                Slider(value: tickerBinding(\.speed), in: 1...1_000) {
                    Text("Speed (\(Int(ticker.speed)) px/s)")
                }
                Slider(value: tickerBinding(\.gap), in: 0...2_000) {
                    Text("Gap (\(Int(ticker.gap)) px)")
                }
                Text("The layer box clips the ticker. Use Title Style for color, background and padding. Up to 4096 characters and 32 KB.")
                    .font(.caption).foregroundStyle(.secondary)
                transport(id: ticker.runtimeID, autoplay: true)
                sharedPlayback(id: ticker.runtimeID)
            }
        }
    }

    private var mode: Binding<Int> {
        Binding(get: { payload.timer != nil ? 1 : payload.ticker != nil ? 2 : 0 }, set: { mode in
            edit {
                $0.timer = mode == 1 ? TimerOverlayConfiguration() : nil
                $0.ticker = mode == 2 ? TickerOverlayConfiguration() : nil
            }
        })
    }

    @ViewBuilder private func timerControls(_ config: TimerOverlayConfiguration) -> some View {
        Picker("Timer", selection: timerBinding(\.kind)) {
            ForEach(TimerOverlayKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        if config.kind == .countdown {
            TextField("Duration (seconds)", value: timerBinding(\.durationSeconds), format: .number)
        }
        if config.kind == .scheduledStart {
            Stepper("Hour: \(config.targetHour)", value: timerBinding(\.targetHour), in: 0...23)
            Stepper("Minute: \(config.targetMinute)", value: timerBinding(\.targetMinute), in: 0...59)
        }
        if !config.kind.usesTransport {
            TextField("Time Zone (e.g. America/Los_Angeles)", text: timerBinding(\.timeZoneIdentifier))
            Text("An empty or unknown time zone uses this Mac's time zone. Scheduled times use today's date; Restart rolls to the next occurrence.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Picker("Format", selection: timerBinding(\.format)) {
            ForEach(TimerDisplayFormat.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        if config.kind == .countdown || config.kind == .scheduledStart {
            Picker("At Zero", selection: timerBinding(\.zeroBehavior)) {
                ForEach(TimerZeroBehavior.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            if config.zeroBehavior == .message {
                TextField("Message", text: timerBinding(\.zeroMessage))
            }
        }
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            Text(DynamicOverlayStore.shared.timer(config, at: DynamicOverlayStore.hostSeconds).text ?? "Hidden")
                .monospacedDigit().accessibilityLabel("Timer reading")
        }
    }

    private func transport(id: UUID, autoplay: Bool) -> some View {
        VStack(alignment: .leading) {
            TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                Text(DynamicOverlayStore.shared.state(for: id, autoplay: autoplay).phase.rawValue.capitalized)
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Start / Resume") { send(.start) }
                Button("Pause") { send(.pause) }
                Button("Reset") { send(.reset) }
            }.buttonStyle(.borderless)
            Text("Transport affects every layer sharing this playback ID, including program.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func sharedPlayback(id: UUID) -> some View {
        VStack(alignment: .leading) {
            TextField("Shared Playback ID", text: Binding(get: { id.uuidString }, set: { value in
                guard let newID = UUID(uuidString: value) else { return }
                edit { if $0.timer != nil { $0.timer?.runtimeID = newID }
                       else { $0.ticker?.runtimeID = newID } }
            }))
            Button("Make Playback Independent") {
                edit { if $0.timer != nil { $0.timer?.runtimeID = UUID() }
                       else { $0.ticker?.runtimeID = UUID() } }
            }.buttonStyle(.borderless)
            Text("Duplicated layers share playback. Paste the same ID into another timer or ticker to link it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func send(_ action: OverlayTransportAction) {
        dispatcher.execute(.setDynamicOverlayTransport(layer.id, action, in: nil))
    }

    private func edit(_ change: (inout TextSourcePayload) -> Void) {
        var copy = payload
        change(&copy)
        dispatcher.execute(.setLayerText(layer.id, copy, in: nil))
    }

    private func timerBinding<Value>(_ key: WritableKeyPath<TimerOverlayConfiguration, Value>) -> Binding<Value> {
        Binding(get: { (payload.timer ?? TimerOverlayConfiguration())[keyPath: key] },
                set: { value in edit { $0.timer?[keyPath: key] = value } })
    }

    private func tickerBinding<Value>(_ key: WritableKeyPath<TickerOverlayConfiguration, Value>) -> Binding<Value> {
        Binding(get: { (payload.ticker ?? TickerOverlayConfiguration())[keyPath: key] },
                set: { value in edit { $0.ticker?[keyPath: key] = value } })
    }
}
