import Foundation
import StreamCore

/// S10: pure geometry/style interpolation. Matching never changes capture
/// identities or media transport. All scene mutations remain staged values.
struct LayerMotionPlan {
    let from: Scene
    let to: Scene
    let easing: MotionEasing
    let fallback: MotionFallback
    private let matches: [LayerID: LayerNode]

    init(from: Scene, to: Scene, easing: MotionEasing, fallback: MotionFallback,
         sourceDefaults: [SourceDefinitionID: SourceEffects] = [:]) {
        self.from = from
        self.to = to
        self.easing = easing
        self.fallback = fallback
        let old = Dictionary(grouping: from.layers.filter(\.isVisible), by: \.motionID)
        let new = Dictionary(grouping: to.layers.filter(\.isVisible), by: \.motionID)
        var matches: [LayerID: LayerNode] = [:]
        for layer in to.layers where layer.isVisible {
            guard let originals = old[layer.motionID], originals.count == 1,
                  new[layer.motionID]?.count == 1, let original = originals.first,
                  Self.compatible(original, layer, sourceDefaults: sourceDefaults) else { continue }
            matches[layer.id] = original
        }
        self.matches = matches
    }

    var matchedLayerCount: Int { matches.count }
    func pair(for id: LayerID) -> (from: LayerNode, to: LayerNode)? {
        guard let old = matches[id], let new = to.layers.first(where: { $0.id == id }) else { return nil }
        return (old, new)
    }

    /// Background composition is handled separately by the renderer. Keeping
    /// the layer scene transparent prevents a second background crossfade.
    func scene(at progress: Double, sourceDefaults: [SourceDefinitionID: SourceEffects] = [:]) -> Scene {
        guard progress > 0 else { return from }
        guard progress < 1 else { return to }
        let t = easing.value(at: progress)
        var result = to
        result.background = .solid(colorHex: "#00000000")
        let matchedOldIDs = Set(matches.values.map(\.id))
        var outgoing = from.layers.filter { $0.isVisible && !matchedOldIDs.contains($0.id) }
        if fallback == .cut { outgoing = [] }
        else { for i in outgoing.indices { outgoing[i].style.opacity *= 1 - t } }
        result.layers = outgoing + to.layers.map { layer in
            if let old = matches[layer.id] {
                return Self.interpolate(old, layer, at: t, sourceDefaults: sourceDefaults)
            }
            var copy = layer
            if fallback == .dissolve { copy.style.opacity *= t }
            return copy
        }
        return result
    }

    private static func compatible(_ old: LayerNode, _ new: LayerNode,
                                   sourceDefaults: [SourceDefinitionID: SourceEffects]) -> Bool {
        guard old.sourceID == new.sourceID, old.payload == new.payload,
              old.style.mask.shape == new.style.mask.shape,
              old.style.mask.isInverted == new.style.mask.isInverted,
              old.style.mask.customAssetIdentifier == new.style.mask.customAssetIdentifier,
              compatibleEffects(old.effects, new.effects) else { return false }
        // Different masks, mirrors, or background modes cannot interpolate
        // without changing source content; they use the selected fallback.
        let a = old.effectiveSourceEffects(defaults: sourceDefaults) ?? .identity
        let b = new.effectiveSourceEffects(defaults: sourceDefaults) ?? .identity
        return a.isMirrored == b.isMirrored && a.isBypassed == b.isBypassed && a.background == b.background
    }

    private static func interpolate(_ old: LayerNode, _ new: LayerNode, at t: Double,
                                    sourceDefaults: [SourceDefinitionID: SourceEffects]) -> LayerNode {
        var layer = new
        // Interpolate equivalent top-left rectangles, then write in the
        // incoming anchor's coordinates. Anchor changes cannot cause a jump.
        let a = topLeft(old.transform), b = topLeft(new.transform)
        let width = mix(old.transform.size.width, new.transform.size.width, t)
        let height = mix(old.transform.size.height, new.transform.size.height, t)
        let x = mix(a.x, b.x, t), y = mix(a.y, b.y, t)
        layer.transform.size = GraphSize(width: width, height: height)
        layer.transform.position = anchored(topLeft: GraphPoint(x: x, y: y), width: width,
                                             height: height, anchor: new.transform.anchor)
        layer.transform.rotationDegrees = angle(old.transform.rotationDegrees, new.transform.rotationDegrees, t)
        layer.effects = zip(old.effects, new.effects).map { a, b in
            switch (a, b) {
            case (.opacity(let a), .opacity(let b)): return .opacity(mix(a, b, t))
            case (.cornerRadius(let a), .cornerRadius(let b)): return .cornerRadius(mix(a, b, t))
            default: return b
            }
        }
        layer.style.mask.cornerRadius = mix(old.style.mask.cornerRadius, new.style.mask.cornerRadius, t)
        layer.style.mask.feather = mix(old.style.mask.feather, new.style.mask.feather, t)
        layer.style.border.width = mix(old.style.border.width, new.style.border.width, t)
        layer.style.border.colorHex = color(old.style.border.colorHex, new.style.border.colorHex, t)
        layer.style.opacity = mix(old.style.opacity, new.style.opacity, t)
        layer.style.perspective.yawDegrees = mix(old.style.perspective.yawDegrees, new.style.perspective.yawDegrees, t)
        layer.style.perspective.pitchDegrees = mix(old.style.perspective.pitchDegrees, new.style.perspective.pitchDegrees, t)
        layer.style.shadow.offsetX = mix(old.style.shadow.offsetX, new.style.shadow.offsetX, t)
        layer.style.shadow.offsetY = mix(old.style.shadow.offsetY, new.style.shadow.offsetY, t)
        layer.style.shadow.radius = mix(old.style.shadow.radius, new.style.shadow.radius, t)
        layer.style.shadow.colorHex = color(old.style.shadow.colorHex, new.style.shadow.colorHex, t)
        let aFX = old.effectiveSourceEffects(defaults: sourceDefaults) ?? .identity
        let bFX = new.effectiveSourceEffects(defaults: sourceDefaults) ?? .identity
        if !aFX.isBypassed, !bFX.isBypassed, aFX.isMirrored == bFX.isMirrored, aFX.background == bFX.background {
            var fx = bFX
            fx.zoom = mix(aFX.zoom, bFX.zoom, t)
            fx.panX = mix(aFX.panX, bFX.panX, t)
            fx.panY = mix(aFX.panY, bFX.panY, t)
            fx.rotationDegrees = angle(aFX.rotationDegrees, bFX.rotationDegrees, t)
            fx.brightness = mix(aFX.brightness, bFX.brightness, t)
            fx.contrast = mix(aFX.contrast, bFX.contrast, t)
            fx.saturation = mix(aFX.saturation, bFX.saturation, t)
            fx.temperature = mix(aFX.temperature, bFX.temperature, t)
            fx.tint = mix(aFX.tint, bFX.tint, t)
            fx.gamma = mix(aFX.gamma, bFX.gamma, t)
            layer.effectOverrides = fx
        }
        return layer
    }

    private static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    private static func compatibleEffects(_ old: [LayerEffect], _ new: [LayerEffect]) -> Bool {
        guard old.count == new.count else { return false }
        return zip(old, new).allSatisfy { a, b in
            switch (a, b) {
            case (.opacity, .opacity), (.cornerRadius, .cornerRadius): return true
            default: return a == b
            }
        }
    }
    private static func angle(_ a: Double, _ b: Double, _ t: Double) -> Double {
        var delta = (b - a).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return a + delta * t
    }
    private static func color(_ a: String, _ b: String, _ t: Double) -> String {
        let a = HexColor.components(a), b = HexColor.components(b)
        return String(format: "#%02X%02X%02X%02X", Int((mix(a.red, b.red, t) * 255).rounded()),
                      Int((mix(a.green, b.green, t) * 255).rounded()),
                      Int((mix(a.blue, b.blue, t) * 255).rounded()),
                      Int((mix(a.alpha, b.alpha, t) * 255).rounded()))
    }
    private static func topLeft(_ transform: LayerTransform) -> GraphPoint {
        switch transform.anchor {
        case .topLeft: return transform.position
        case .topRight: return GraphPoint(x: transform.position.x - transform.size.width, y: transform.position.y)
        case .bottomLeft: return GraphPoint(x: transform.position.x, y: transform.position.y - transform.size.height)
        case .bottomRight: return GraphPoint(x: transform.position.x - transform.size.width, y: transform.position.y - transform.size.height)
        case .center: return GraphPoint(x: transform.position.x - transform.size.width / 2, y: transform.position.y - transform.size.height / 2)
        }
    }
    private static func anchored(topLeft: GraphPoint, width: Double, height: Double,
                                 anchor: LayerAnchor) -> GraphPoint {
        switch anchor {
        case .topLeft: return topLeft
        case .topRight: return GraphPoint(x: topLeft.x + width, y: topLeft.y)
        case .bottomLeft: return GraphPoint(x: topLeft.x, y: topLeft.y + height)
        case .bottomRight: return GraphPoint(x: topLeft.x + width, y: topLeft.y + height)
        case .center: return GraphPoint(x: topLeft.x + width / 2, y: topLeft.y + height / 2)
        }
    }
}
