import Foundation
import StreamCore

@main struct LayerMotionHarness {
    static func main() throws {
        let source = SourceDefinitionID()
        var old = LayerNode.fullscreenCamera(sourceID: source)
        old.style.mask.shape = .rectangle
        old.style.mask.cornerRadius = 10
        old.style.border.width = 2
        old.transform.rotationDegrees = 350
        var fromFX = SourceEffects()
        fromFX.zoom = 1
        old.effectOverrides = fromFX
        var new = old
        new.id = LayerID()
        new.transform = LayerTransform(position: GraphPoint(x: 0.9, y: 0.9),
            size: GraphSize(width: 0.2, height: 0.2), anchor: .bottomRight, rotationDegrees: 10)
        new.style.mask.cornerRadius = 30
        new.style.border.width = 6
        var toFX = fromFX
        toFX.zoom = 3
        toFX.panX = 1
        new.effectOverrides = toFX
        let from = Scene(name: "Full", layers: [old])
        let to = Scene(name: "PIP", layers: [new])
        let plan = LayerMotionPlan(from: from, to: to, easing: .linear, fallback: .dissolve)
        precondition(plan.matchedLayerCount == 1)
        precondition(plan.scene(at: 0) == from)
        precondition(plan.scene(at: 1) == to)
        let midpoint = plan.scene(at: 0.5).layers[0]
        precondition(abs(midpoint.transform.size.width - 0.6) < 0.00001)
        precondition(abs(midpoint.transform.position.x - 0.95) < 0.00001)
        precondition(midpoint.transform.rotationDegrees == 360, "Use the shortest rotation arc")
        precondition(midpoint.style.mask.cornerRadius == 20)
        precondition(midpoint.style.border.width == 4)
        precondition(midpoint.effectOverrides?.zoom == 2)
        precondition(midpoint.effectOverrides?.panX == 0.5)
        precondition(midpoint.sourceID == source && midpoint.audio == new.audio)

        let decoded = try JSONDecoder().decode(LayerNode.self, from: JSONEncoder().encode(new))
        precondition(decoded.motionID == old.motionID, "Persist and duplicate explicit identities")
        var duplicate = new
        duplicate.id = LayerID()
        let ambiguous = LayerMotionPlan(from: from, to: Scene(name: "Ambiguous", layers: [new, duplicate]),
                                        easing: .linear, fallback: .dissolve)
        precondition(ambiguous.matchedLayerCount == 0)
        precondition(ambiguous.scene(at: 0.5).layers.count == 3)
        var incompatible = new
        incompatible.style.mask.shape = .circle
        let mismatch = LayerMotionPlan(from: from, to: Scene(name: "Circle", layers: [incompatible]),
                                       easing: .linear, fallback: .cut)
        precondition(mismatch.matchedLayerCount == 0)
        precondition(mismatch.scene(at: 0.5).layers.count == 1)
        var differentSource = new
        differentSource.sourceID = SourceDefinitionID()
        let replaced = LayerMotionPlan(from: from, to: Scene(name: "Other camera", layers: [differentSource]),
                                       easing: .linear, fallback: .dissolve)
        precondition(replaced.matchedLayerCount == 0)
        for index in 1...20 {
            var target = to
            target.layers[0].transform.position.x = Double(index) / 20
            let take = LayerMotionPlan(from: plan.scene(at: 0.5), to: target,
                                       easing: .easeInOut, fallback: .dissolve)
            precondition(take.scene(at: 1) == target, "Repeated Takes must end at the latest intended value")
        }
        let a = plan.scene(at: 0.25), b = plan.scene(at: 0.75)
        precondition(a.layers[0].transform.size.width > b.layers[0].transform.size.width)
        let invalid = SceneTransition(style: .layerMotion, durationSeconds: .nan)
        precondition(invalid.validationError != nil)
        print("PASS: explicit/ambiguous identity, anchors, scale/rotation/crop/mask/border interpolation, fallback, serialization, repeated final targets, unchanged source/audio identity")
    }
}
