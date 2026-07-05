import Testing
import StreamCore

/// Unit tests for the pure live-telemetry logic surfaced in the stats HUD: the
/// uplink-health classification and the compact display formatting.
@Suite struct LiveStatsHealthTests {
    private func stats(queueBytes: Int = 0, zeroOutputSeconds: Int = 0) -> LiveStats {
        LiveStats(bitRate: 3_000_000, frameRate: 30, queueBytes: queueBytes, zeroOutputSeconds: zeroOutputSeconds)
    }

    @Test("An empty, flowing queue reads as Good")
    func goodWhenQueueEmpty() {
        #expect(stats(queueBytes: 0).linkHealth == .good)
        #expect(stats(queueBytes: 524_287).linkHealth == .good)   // just under the fair floor
    }

    @Test("A half-megabyte backlog crosses into Fair")
    func fairAtHalfMegabyte() {
        #expect(stats(queueBytes: 524_288).linkHealth == .fair)
        #expect(stats(queueBytes: 2_097_151).linkHealth == .fair) // just under congested
    }

    @Test("A 2 MB backlog is Congested")
    func congestedAtTwoMegabytes() {
        #expect(stats(queueBytes: 2_097_152).linkHealth == .congested)
    }

    @Test("Any sustained zero-output stall is Congested regardless of queue size")
    func zeroOutputStallIsCongested() {
        #expect(stats(queueBytes: 0, zeroOutputSeconds: 2).linkHealth == .congested)
        // A single zero-output tick with an empty queue is not yet congested.
        #expect(stats(queueBytes: 0, zeroOutputSeconds: 1).linkHealth == .good)
    }

    @Test("Every LinkHealth case has a display label")
    func everyCaseHasLabel() {
        for h in LiveStats.LinkHealth.allCases {
            #expect(!h.label.isEmpty)
        }
    }
}

@Suite struct LiveStatsFormattingTests {
    private func stats(bitRate: Int = 0, queueBytes: Int = 0) -> LiveStats {
        LiveStats(bitRate: bitRate, frameRate: 30, queueBytes: queueBytes, zeroOutputSeconds: 0)
    }

    @Test("Bitrate labels as Mbps at/above 1 Mbps and kbps below")
    func bitRateLabels() {
        #expect(stats(bitRate: 2_400_000).bitRateLabel == "2.4 Mbps")
        #expect(stats(bitRate: 1_000_000).bitRateLabel == "1.0 Mbps")
        #expect(stats(bitRate: 850_000).bitRateLabel == "850 kbps")
        #expect(stats(bitRate: 0).bitRateLabel == "0 kbps")
        #expect(stats(bitRate: -100).bitRateLabel == "0 kbps")   // clamps
    }

    @Test("Queue labels as KB below a megabyte and MB above")
    func queueLabels() {
        #expect(stats(queueBytes: 0).queueLabel == "0 KB")
        #expect(stats(queueBytes: 524_288).queueLabel == "512 KB")
        #expect(stats(queueBytes: 1_048_576).queueLabel == "1.0 MB")
        #expect(stats(queueBytes: 2_097_152).queueLabel == "2.0 MB")
    }

    @Test("Uptime is MM:SS under an hour and H:MM:SS past it")
    func uptimeLabels() {
        #expect(LiveStats.uptimeLabel(seconds: 0) == "00:00")
        #expect(LiveStats.uptimeLabel(seconds: 59) == "00:59")
        #expect(LiveStats.uptimeLabel(seconds: 65) == "01:05")
        #expect(LiveStats.uptimeLabel(seconds: 600) == "10:00")
        #expect(LiveStats.uptimeLabel(seconds: 3600) == "1:00:00")
        #expect(LiveStats.uptimeLabel(seconds: 3665) == "1:01:05")
    }

    @Test("Negative uptime clamps to zero")
    func negativeUptimeClamps() {
        #expect(LiveStats.uptimeLabel(seconds: -5) == "00:00")
    }
}

/// The M8 telemetry fields folded into the HUD snapshot: the measured achieved fps
/// (with its target fallback) and the compact dropped-frame count.
@Suite struct LiveStatsTelemetryTests {
    private func stats(frameRate: Int = 30, achieved: Int = 0, dropped: Int = 0) -> LiveStats {
        LiveStats(bitRate: 3_000_000, frameRate: frameRate, queueBytes: 0, zeroOutputSeconds: 0,
                  achievedFrameRate: achieved, droppedFrames: dropped)
    }

    @Test("displayFrameRate shows the measured rate, falling back to the target at zero")
    func displayFrameRateFallback() {
        // No measured rate yet (first second / an idle window) → show the target.
        #expect(stats(frameRate: 60, achieved: 0).displayFrameRate == 60)
        // A measured rate takes over once available — even when it differs from target.
        #expect(stats(frameRate: 60, achieved: 52).displayFrameRate == 52)
        #expect(stats(frameRate: 30, achieved: 30).displayFrameRate == 30)
    }

    @Test("droppedLabel is a bare count under 1000 and abbreviates above it")
    func droppedLabelFormatting() {
        #expect(stats(dropped: 0).droppedLabel == "0")
        #expect(stats(dropped: 42).droppedLabel == "42")
        #expect(stats(dropped: 999).droppedLabel == "999")
        #expect(stats(dropped: 1000).droppedLabel == "1.0k")
        #expect(stats(dropped: 1500).droppedLabel == "1.5k")
        #expect(stats(dropped: -5).droppedLabel == "0")   // clamps
    }

    @Test("The new telemetry fields participate in equality")
    func equalityIncludesTelemetry() {
        #expect(stats(achieved: 30, dropped: 0) != stats(achieved: 29, dropped: 0))
        #expect(stats(achieved: 30, dropped: 0) != stats(achieved: 30, dropped: 4))
        #expect(stats(achieved: 30, dropped: 4) == stats(achieved: 30, dropped: 4))
    }

    @Test("The telemetry fields default to zero for existing call sites")
    func defaultsAreZero() {
        let base = LiveStats(bitRate: 1_000_000, frameRate: 30, queueBytes: 0, zeroOutputSeconds: 0)
        #expect(base.achievedFrameRate == 0)
        #expect(base.droppedFrames == 0)
        #expect(base.displayFrameRate == 30)   // falls back to the target
    }
}
