import Foundation

// S06 (issue #96) standalone assertion harness.
//
// The scene model types live in the StreamMac APP target, which has no test
// bundle — so, like S12, this harness compiles the real sources (LayerGraph,
// plus the StreamCore files that define PIPCorner) as one module via
// run_scene_s06_harness.zsh and asserts the S06 model behaviors directly:
//   - SceneGraph.flattenedVisibleLayers (nested expansion, visibility
//     filtering, cycle guard, depth cap) — the S05 capture-demand seam, and
//   - SceneGraph.wouldCreateCycle / subtreeDepth / ancestorDepth — the
//     edit-time validation the dispatcher rejects with, and
//   - `.scene` payload persistence round-trip.
//
// Prints PASS/FAIL per assertion and exits non-zero on any failure.

var failures = 0
@MainActor
func check(_ condition: Bool, _ name: String) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}

// MARK: - Fixtures

func cameraLayer(visible: Bool = true, name: String = "Camera") -> LayerNode {
    LayerNode(name: name, payload: .camera(CameraSourcePayload()),
              transform: .fullscreen, isVisible: visible)
}

func textLayer(visible: Bool = true, name: String = "Text") -> LayerNode {
    LayerNode(name: name, payload: .text(TextSourcePayload(text: "lower third")),
              transform: .fullscreen, isVisible: visible)
}

func sceneLayer(_ id: SceneID, visible: Bool = true) -> LayerNode {
    LayerNode(name: "Nested", payload: .scene(SceneReferencePayload(sceneID: id)),
              transform: .fullscreen, isVisible: visible)
}

func makeScene(_ name: String, layers: [LayerNode]) -> Scene {
    Scene(name: name, layers: layers)
}

// A camera-only child scene, nested into a container.
let child = makeScene("Child", layers: [cameraLayer(), textLayer()])
let container = makeScene("Container", layers: [sceneLayer(child.id)])
var index = SceneGraph.index([child, container])

// MARK: - Flattening (the S05 capture-demand seam)

let flattened = SceneGraph.flattenedVisibleLayers(of: container, in: index)
check(flattened.count == 2, "flatten: visible reference expands into the child's visible layers")
check(flattened.contains(where: { $0.payload.isCamera }),
      "flatten: a camera used only inside a nested scene reaches the demand computation")
check(!flattened.contains(where: { $0.payload.isScene }),
      "flatten: the reference layer itself contributes nothing")

// An invisible reference layer does not expand.
let hiddenRefContainer = makeScene("HiddenRef", layers: [sceneLayer(child.id, visible: false)])
index = SceneGraph.index([child, hiddenRefContainer])
check(SceneGraph.flattenedVisibleLayers(of: hiddenRefContainer, in: index).isEmpty,
      "flatten: an invisible reference layer does not expand")

// An invisible layer INSIDE the nested scene is excluded.
let hiddenCameraChild = makeScene("HiddenCam", layers: [cameraLayer(visible: false), textLayer()])
let container2 = makeScene("Container2", layers: [sceneLayer(hiddenCameraChild.id)])
index = SceneGraph.index([child, hiddenCameraChild, container2])
let flattened2 = SceneGraph.flattenedVisibleLayers(of: container2, in: index)
check(flattened2.count == 1 && flattened2[0].payload.isText,
      "flatten: invisible layers inside the nested scene are excluded")

// A dangling reference (the referenced scene was deleted) expands to nothing
// instead of crashing — the defined deletion fallback.
let dangling = makeScene("Dangling", layers: [sceneLayer(SceneID())])
index = SceneGraph.index([dangling])
check(SceneGraph.flattenedVisibleLayers(of: dangling, in: index).isEmpty,
      "flatten: a dangling reference expands to nothing (deletion fallback, no crash)")

// A hand-made cycle (documents can only contain one by corruption — edit-time
// validation rejects them) terminates instead of recursing forever.
var cycA = makeScene("CycA", layers: [])
var cycB = makeScene("CycB", layers: [])
cycA.layers = [sceneLayer(cycB.id), textLayer(name: "A text")]
cycB.layers = [sceneLayer(cycA.id), cameraLayer()]
index = SceneGraph.index([cycA, cycB])
let cyclicFlattened = SceneGraph.flattenedVisibleLayers(of: cycA, in: index)
check(cyclicFlattened.count == 2,
      "flatten: a corrupt reference loop terminates (visited guard) with bounded output")

// A diamond reference (two layers nesting the SAME child) expands twice —
// diamonds are reuse, not cycles.
let diamond = makeScene("Diamond", layers: [sceneLayer(child.id), sceneLayer(child.id)])
index = SceneGraph.index([child, diamond])
check(SceneGraph.flattenedVisibleLayers(of: diamond, in: index).count == 4,
      "flatten: a diamond reference expands once per reference layer")

// MARK: - Cycle detection (edit-time validation)

index = SceneGraph.index([child, container])
check(SceneGraph.wouldCreateCycle(container: child.id, referencing: child.id, in: index),
      "cycle: self-reference is rejected")
check(SceneGraph.wouldCreateCycle(container: child.id, referencing: container.id, in: index),
      "cycle: A→B exists, so B into A (A↛… child→container→child) is rejected")
let unrelated = makeScene("Unrelated", layers: [textLayer()])
index = SceneGraph.index([child, container, unrelated])
check(!SceneGraph.wouldCreateCycle(container: unrelated.id, referencing: container.id, in: index),
      "cycle: an unrelated container may reference any scene")
check(!SceneGraph.wouldCreateCycle(container: container.id, referencing: child.id, in: index),
      "cycle: re-validating the existing acyclic edge passes")

// Indirect cycle: A→B→C exists, so C→A closes a loop.
let indA = makeScene("A", layers: [])
let indB = makeScene("B", layers: [sceneLayer(indA.id)])
let indC = makeScene("C", layers: [sceneLayer(indB.id)])
index = SceneGraph.index([indA, indB, indC])
check(SceneGraph.wouldCreateCycle(container: indA.id, referencing: indC.id, in: index),
      "cycle: A←B←C exists, so nesting C into A is rejected")
check(!SceneGraph.wouldCreateCycle(container: indC.id, referencing: indA.id, in: index),
      "cycle: nesting A into C just extends the chain (no loop)")

// MARK: - Depth accounting (nesting-complexity cap)

check(SceneGraph.subtreeDepth(of: indC.id, in: index) == 3,
      "depth: C→B→A has subtree depth 3")
check(SceneGraph.subtreeDepth(of: indA.id, in: index) == 1,
      "depth: a leaf scene has subtree depth 1")
check(SceneGraph.ancestorDepth(of: indA.id, in: index) == 2,
      "depth: A is nested two levels deep (B and C reference it)")
check(SceneGraph.ancestorDepth(of: indC.id, in: index) == 0,
      "depth: nothing references C")

// The dispatcher's rejection formula: ancestorDepth(container) +
// subtreeDepth(target) must stay within the cap. Chain maxNestingDepth
// scenes, then verify the NEXT nesting would exceed it.
var chain: [Scene] = [makeScene("chain-0", layers: [textLayer()])]
for i in 1...(SceneGraph.maxNestingDepth + 2) {
    chain.append(makeScene("chain-\(i)", layers: [sceneLayer(chain[i - 1].id)]))
}
index = SceneGraph.index(chain)
let chainTip = chain[0].id
let chainEnd = chain[SceneGraph.maxNestingDepth - 1]   // depth maxNestingDepth from the tip
let chainBeyond = chain[SceneGraph.maxNestingDepth]
check(SceneGraph.subtreeDepth(of: chainEnd.id, in: index) == SceneGraph.maxNestingDepth,
      "depth: the walker measures a max-depth chain exactly")
check(SceneGraph.ancestorDepth(of: chainTip, in: index) == SceneGraph.maxNestingDepth,
      "depth: ancestor chains are measured (and capped) defensively")
let wouldExceed = SceneGraph.ancestorDepth(of: chainBeyond.id, in: index)
    + SceneGraph.subtreeDepth(of: chainBeyond.id, in: index)
check(wouldExceed > SceneGraph.maxNestingDepth,
      "depth: chains beyond the cap read as over-limit, so validation rejects them")
// And the flatten walker stays bounded on the over-deep chain.
let deepFlattened = SceneGraph.flattenedVisibleLayers(of: chainBeyond, in: index)
check(deepFlattened.count <= 1,
      "flatten: over-deep chains expand only within the depth cap")

// MARK: - Persistence

let encoder = JSONEncoder()
let decoder = JSONDecoder()
let referencePayload = LayerPayload.scene(SceneReferencePayload(sceneID: child.id))
if let data = try? encoder.encode(referencePayload),
   let decoded = try? decoder.decode(LayerPayload.self, from: data),
   case .scene(let decodedReference) = decoded {
    check(decodedReference.sceneID == child.id,
          "persistence: a .scene payload round-trips its referenced scene ID")
    check(decoded.kind == "scene" && decoded.isRenderable,
          "persistence: the decoded payload keeps the scene kind and is renderable")
} else {
    check(false, "persistence: a .scene payload round-trips its referenced scene ID")
}

// A v2 document containing a nested-scene layer round-trips whole.
let document = SceneDocument(sources: [],
                             scenes: [child, container],
                             selectedID: container.id)
if let data = try? encoder.encode(document),
   let decoded = try? decoder.decode(SceneDocument.self, from: data) {
    let decodedContainer = decoded.scenes.first(where: { $0.id == container.id })
    check(decodedContainer?.layers.first?.payload.isScene == true,
          "persistence: a document with a nested-scene layer round-trips")
} else {
    check(false, "persistence: a document with a nested-scene layer round-trips")
}

print(failures == 0 ? "\nAll S06 harness assertions passed." : "\n\(failures) assertion(s) FAILED.")
exit(failures == 0 ? 0 : 1)
