import Foundation

/// Identifies a composed layout, independently of an encoder's output size.
public enum OutputCanvas: String, Codable, CaseIterable, Sendable {
    case program, secondary
}
