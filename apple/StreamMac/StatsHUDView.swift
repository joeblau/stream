import SwiftUI
import StreamCore

/// Compact live-stats strip for the macOS main window: uplink health pill,
/// bitrate, measured fps, and (only when non-zero) dropped frames. Polls
/// `StreamController.statsSnapshot()` at ~1 Hz while a streaming session is
/// active and idles empty otherwise. Before the first acknowledged publish
/// (and during reconnects) the pill shows the session state — connecting,
/// reconnecting — instead of stale metrics. All formatting and health
/// classification reuse StreamCore's `LiveStats` helpers, so the HUD matches
/// the iOS stats card.
struct StatsHUDView: View {
    @ObservedObject var stream: StreamController

    @State private var stats: LiveStats?

    var body: some View {
        HStack(spacing: 14) {
            healthPill
            metric("Bitrate", value: stats?.bitRateLabel ?? "—")
            metric("FPS", value: stats.map { "\($0.displayFrameRate)" } ?? "—")
            if let stats, stats.droppedFrames > 0 {
                metric("Dropped", value: stats.droppedLabel, tint: .orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .task(id: stream.streamState) {
            guard stream.streamState.isActive else {
                stats = nil
                return
            }
            while !Task.isCancelled {
                stats = await stream.statsSnapshot()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var healthPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(healthTint)
                .frame(width: 8, height: 8)
            Text(stats?.linkHealth.label ?? sessionLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(healthTint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Uplink health")
        .accessibilityValue(stats?.linkHealth.label ?? sessionLabel)
    }

    /// Shown while the publisher has no metrics yet (pre-ack / mid-reconnect),
    /// so the strip reports the real session state rather than "Offline".
    private var sessionLabel: String {
        switch stream.streamState {
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .stopping: return "Stopping…"
        case .failed: return "Failed"
        case .idle, .live: return "Offline"
        }
    }

    private var healthTint: Color {
        if stats == nil {
            switch stream.streamState {
            case .connecting: return .yellow
            case .reconnecting: return .orange
            case .failed: return .red
            case .idle, .live, .stopping: return .secondary
            }
        }
        switch stats?.linkHealth {
        case .good:      return .green
        case .fair:      return .yellow
        case .congested: return .red
        case .none:      return .secondary
        }
    }

    private func metric(_ label: String, value: String, tint: Color = .primary) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}
