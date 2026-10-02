import Foundation
import StreamCore

/// An independent geometry snapshot over the same stable layer/source IDs.
/// Missing placements explicitly follow Program geometry. Payload, media,
/// timer, guest and PDF identity remain shared; this never creates playback.
struct SecondaryCanvasLayout: Hashable, Codable, Sendable {
    var size: GraphSize
    var placements: [LayerID: Placement]
    var safeZone: SafeZone

    struct Placement: Hashable, Codable, Sendable {
        var transform: LayerTransform
        var isVisible: Bool
    }
    struct SafeZone: Hashable, Codable, Sendable {
        var top = 0.08
        var bottom = 0.20
        var left = 0.05
        var right = 0.16
        var isValid: Bool {
            [top, bottom, left, right].allSatisfy { $0.isFinite && (0...0.4).contains($0) }
        }
    }
    init(size: GraphSize = GraphSize(width: 720, height: 1280), placements: [LayerID: Placement] = [:], safeZone: SafeZone = .init()) {
        self.size = size; self.placements = placements; self.safeZone = safeZone
    }
    var isValid: Bool {
        size.width.isFinite && size.height.isFinite && size.width >= 2 && size.height >= 2 &&
        size.width <= 1920 && size.height <= 1920 && size.width.rounded() == size.width &&
        size.height.rounded() == size.height && Int(size.width) % 2 == 0 && Int(size.height) % 2 == 0 &&
        safeZone.isValid && placements.count <= 256 && placements.values.allSatisfy { placement in
            let t = placement.transform
            return [t.position.x, t.position.y, t.size.width, t.size.height, t.rotationDegrees].allSatisfy(\.isFinite)
                && t.size.width > 0 && t.size.height > 0
        }
    }
    func profile(frameRate: Int) -> OutputProfile {
        OutputProfile(canvasWidth: Int(size.width), canvasHeight: Int(size.height), frameRate: frameRate)
    }
    static func duplicated(from scene: Scene) -> Self {
        .init(placements: Dictionary(uniqueKeysWithValues: scene.layers.map { ($0.id, .init(transform: $0.transform, isVisible: $0.isVisible)) }))
    }
    func applying(to scene: Scene) -> Scene {
        var resolved = scene
        resolved.secondaryCanvas = nil
        resolved.canvas.referenceSize = size
        resolved.layers = scene.layers.map { layer in
            guard let placement = placements[layer.id] else { return layer }
            var layer = layer; layer.transform = placement.transform; layer.isVisible = placement.isVisible
            return layer
        }
        return resolved
    }
}

extension Scene {
    func composition(for canvas: OutputCanvas) -> Scene {
        guard canvas == .secondary else { return self }
        // Scenes without a configured second layout give deterministic black,
        // never a silently stretched copy of the other outgoing layout.
        guard let layout = secondaryCanvas, layout.isValid else {
            var black = self; black.layers = []; black.secondaryCanvas = nil
            black.background = .solid(colorHex: "#000000")
            return black
        }
        return layout.applying(to: self)
    }
}
