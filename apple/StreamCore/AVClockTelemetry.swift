import Foundation
import os

/// Timestamp clocks observed at one named pipeline boundary. This measures
/// media-time advancement against the monotonic host observation clock, not
/// pictures/sound content, receiver playout, lip sync or the last track ends.
public struct AVClockSnapshot: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case unsupported, noAudio, noVideo, warming, staleAudio, staleVideo, unstable, stable, offset, drifting
    }
    public var state: State
    public var audioMinusVideoMilliseconds: Double?
    public var relativeRateMillisecondsPerSecond: Double?
    public var rateUncertaintyMillisecondsPerSecond: Double?
    public var audioAgeMilliseconds: Double?
    public var videoAgeMilliseconds: Double?
    public var windowSeconds: Double
    public var audioSamples: Int
    public var videoSamples: Int
    public var audioResidualMilliseconds: Double?
    public var videoResidualMilliseconds: Double?
    public var rejectedSamples: Int
    public var discontinuities: Int

    public static var unsupported: Self {
        .init(state: .unsupported, windowSeconds: 0, audioSamples: 0, videoSamples: 0,
              rejectedSamples: 0, discontinuities: 0)
    }
}

/// Bounded off-actor observation store. Call with the sample's actual PTS and
/// the host time at the actual boundary, before any instrumentation work.
/// Each track retains at most 256 points / 12 seconds, at up to 20 Hz.
/// Projection to a common observation instant distinguishes a fixed A/V
/// timestamp offset from differing advancement rates. Arrival jitter remains
/// visible as residual/uncertainty; it is never claimed as device clock error.
public final class AVClockTelemetry: @unchecked Sendable {
    public enum Track: Sendable { case audio, video }
    private struct Point: Sendable { let host: Double; let media: Double }
    private struct History: Sendable {
        var points: [Point] = []
        var last: Point?
        var rejected = 0
        var discontinuities = 0
        mutating func record(media: Double, host: Double) {
            guard media.isFinite, host.isFinite, host >= 0 else { rejected += 1; return }
            if let last {
                guard host >= last.host else { rejected += 1; return }
                if media <= last.media, media >= last.media - 0.15 { rejected += 1; return }
                // Resume/epoch changes invalidate the old regression. Drops
                // retain their real elapsed times instead of changing rate.
                if media < last.media || host - last.host > 2 || abs((media - last.media) - (host - last.host)) > 0.15 {
                    points.removeAll(keepingCapacity: true); discontinuities += 1
                }
            }
            last = Point(host: host, media: media)
            if let previous = points.last, host - previous.host < 0.05 { return }
            points.append(Point(host: host, media: media))
            points.removeAll { host - $0.host > 12 }
            if points.count > 256 { points.removeFirst(points.count - 256) }
        }
        func fit(at host: Double) -> Fit? {
            guard let first = points.first, let last else { return nil }
            let count = Double(points.count)
            let meanX = points.reduce(0) { $0 + ($1.host - first.host) } / count
            let meanY = points.reduce(0) { $0 + ($1.media - first.media) } / count
            var xx = 0.0, xy = 0.0
            for point in points {
                let x = point.host - first.host - meanX
                xx += x * x; xy += x * (point.media - first.media - meanY)
            }
            let rate = xx > 0 ? xy / xx : 1
            let residual = points.reduce(0.0) {
                let error = ($1.media - first.media) - (meanY + rate * ($1.host - first.host - meanX))
                return $0 + error * error
            }
            let variance = residual / max(1, count - 2)
            return Fit(projected: first.media + meanY + rate * (host - first.host - meanX), rate: rate,
                       uncertainty: xx > 0 ? sqrt(variance / xx) : .infinity,
                       residual: sqrt(variance), age: max(0, host - last.host),
                       span: max(0, (points.last?.host ?? first.host) - first.host), count: points.count)
        }
    }
    private struct Fit {
        let projected: Double; let rate: Double; let uncertainty: Double
        let residual: Double; let age: Double; let span: Double; let count: Int
    }
    private struct Storage: Sendable { var audio = History(); var video = History() }
    private let storage = OSAllocatedUnfairLock(initialState: Storage())
    public init() {}
    public func record(_ track: Track, presentationSeconds: Double, observedHostSeconds: Double = ProcessInfo.processInfo.systemUptime) {
        storage.withLock {
            switch track {
            case .audio: $0.audio.record(media: presentationSeconds, host: observedHostSeconds)
            case .video: $0.video.record(media: presentationSeconds, host: observedHostSeconds)
            }
        }
    }
    public func reset() { storage.withLock { $0 = Storage() } }
    public func snapshot(videoReference: AVClockTelemetry? = nil, at host: Double = ProcessInfo.processInfo.systemUptime) -> AVClockSnapshot {
        let value = storage.withLock { $0 }
        let videoHistory = videoReference.map { reference in reference.storage.withLock { $0.video } } ?? value.video
        return {
            let audio = value.audio.fit(at: host), video = videoHistory.fit(at: host)
            var result = AVClockSnapshot(state: audio == nil ? .noAudio : video == nil ? .noVideo : .warming,
                audioAgeMilliseconds: audio.map { $0.age * 1000 }, videoAgeMilliseconds: video.map { $0.age * 1000 },
                windowSeconds: min(audio?.span ?? 0, video?.span ?? 0),
                audioSamples: audio?.count ?? 0, videoSamples: video?.count ?? 0,
                audioResidualMilliseconds: audio.map { $0.residual * 1000 }, videoResidualMilliseconds: video.map { $0.residual * 1000 },
                rejectedSamples: value.audio.rejected + videoHistory.rejected,
                discontinuities: value.audio.discontinuities + videoHistory.discontinuities)
            guard host.isFinite, let audio, let video else { return result }
            guard audio.age <= 2 else { result.state = .staleAudio; return result }
            guard video.age <= 2 else { result.state = .staleVideo; return result }
            guard result.windowSeconds >= 2, audio.count >= 8, video.count >= 8 else { return result }
            let rate = (audio.rate - video.rate) * 1000
            let uncertainty = sqrt(audio.uncertainty * audio.uncertainty + video.uncertainty * video.uncertainty) * 1000
            guard rate.isFinite, uncertainty.isFinite, audio.residual < 0.005, video.residual < 0.005 else {
                result.state = .unstable; return result
            }
            let offset = (audio.projected - video.projected) * 1000
            result.audioMinusVideoMilliseconds = offset
            result.relativeRateMillisecondsPerSecond = rate
            result.rateUncertaintyMillisecondsPerSecond = uncertainty
            if abs(rate) > max(2, uncertainty * 3) { result.state = .drifting }
            else if abs(offset) > 80 { result.state = .offset }
            else { result.state = .stable }
            return result
        }()
    }
}
