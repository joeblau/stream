import Foundation

public enum MotionEasing: String, Codable, CaseIterable, Sendable {
    case linear, easeIn, easeOut, easeInOut

    public func value(at progress: Double) -> Double {
        let t = progress.isFinite ? min(1, max(0, progress)) : 0
        switch self {
        case .linear: return t
        case .easeIn: return t * t * t
        case .easeOut: return 1 - pow(1 - t, 3)
        case .easeInOut: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        }
    }
}

public enum MotionFallback: String, Codable, CaseIterable, Sendable {
    case cut, dissolve
}
