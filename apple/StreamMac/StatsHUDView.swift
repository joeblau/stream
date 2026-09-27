import SwiftUI
import StreamCore

/// Compact live-stats strip for the macOS main window: uplink health pill,
/// bitrate, measured fps, and (only when non-zero) dropped frames. Polls
/// `StreamController.statsSnapshot()` at ~1 Hz while the stream is live and
/// idles empty otherwise. All formatting and health classification reuse
/// StreamCore's `LiveStats` helpers, so the HUD matches the iOS stats card.
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
        .task(id: stream.isLive) {
            guard stream.isLive else {
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
            Text(stats?.linkHealth.label ?? "Offline")
                .font(.caption.weight(.semibold))
                .foregroundStyle(healthTint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Uplink health")
        .accessibilityValue(stats?.linkHealth.label ?? "Offline")
    }

    private var healthTint: Color {
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
