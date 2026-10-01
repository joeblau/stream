import Foundation

public enum OverlayTransportAction: String, Codable, CaseIterable, Sendable {
    case start, pause, reset
}

public enum TickerDirection: String, Codable, CaseIterable, Sendable {
    case left, right
}

/// Speed and gap use the same 1080p reference units as title styling.
/// A copied configuration shares its playback clock across scenes/canvases.
public struct TickerOverlayConfiguration: Hashable, Codable, Sendable {
    public var runtimeID: UUID = UUID()
    public var direction: TickerDirection = .left
    public var speed: Double = 100
    public var gap: Double = 120

    public init(runtimeID: UUID = UUID(), direction: TickerDirection = .left,
                speed: Double = 100, gap: Double = 120) {
        self.runtimeID = runtimeID
        self.direction = direction
        self.speed = speed
        self.gap = gap
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runtimeID = try c.decodeIfPresent(UUID.self, forKey: .runtimeID) ?? UUID()
        direction = try c.decodeIfPresent(TickerDirection.self, forKey: .direction) ?? .left
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 100
        gap = try c.decodeIfPresent(Double.self, forKey: .gap) ?? 120
    }

    public var validationError: String? {
        guard speed.isFinite, (1...1_000).contains(speed) else {
            return "Ticker speed must be between 1 and 1000 pixels per second."
        }
        guard gap.isFinite, (0...2_000).contains(gap) else {
            return "Ticker gap must be between 0 and 2000 pixels."
        }
        return nil
    }

    public func clamped() -> Self {
        var copy = self
        copy.speed = speed.isFinite ? min(1_000, max(1, speed)) : 100
        copy.gap = gap.isFinite ? min(2_000, max(0, gap)) : 120
        return copy
    }

    /// Bound both character count and encoded bytes before layout or rasterization.
    public static func textValidationError(_ text: String) -> String? {
        text.count <= 4_096 && text.utf8.count <= 32_768
            ? nil : "Ticker text must fit within 4096 characters and 32 KB."
    }

    /// The first visible copy starts immediately. Subsequent copies are separated
    /// by gap; elapsed is sampled from a shared monotonic transport clock.
    public func offset(elapsed: Double, textWidth: Double, viewportWidth: Double,
                       scale: Double = 1) -> Double {
        guard elapsed.isFinite, textWidth.isFinite, viewportWidth.isFinite,
              scale.isFinite, scale > 0 else { return 0 }
        let config = clamped()
        let cycle = max(1, max(0, textWidth) + config.gap * scale)
        let travel = (max(0, elapsed) * config.speed * scale).truncatingRemainder(dividingBy: cycle)
        return config.direction == .left ? -travel : viewportWidth - textWidth + travel
    }
}
