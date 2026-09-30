import Foundation
import StreamCore

// MARK: - Stable identifiers
//
// Every entity in a scene document carries a UUID-backed identifier. IDs are
// persisted as plain UUID strings and never derived from display names, so
// renames never break references (layer → source definition, layer → group,
// nested scene → scene).

/// Phantom-typed UUID wrapper: one encoding, one implementation, distinct
/// types per entity so a `SceneID` can never be passed where a `LayerID`
/// belongs. Encodes as a bare UUID string for a stable, diff-friendly wire
/// format.
struct GraphID<Tag>: Hashable, Codable, Sendable, CustomStringConvertible {
    var rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var description: String { rawValue.uuidString }
}

enum ProjectTag {}
enum SceneTag {}
enum SourceDefinitionTag {}
enum LayerTag {}
enum GroupTag {}
enum CanvasTag {}

typealias ProjectID = GraphID<ProjectTag>
typealias SceneID = GraphID<SceneTag>
typealias SourceDefinitionID = GraphID<SourceDefinitionTag>
typealias LayerID = GraphID<LayerTag>
typealias GroupID = GraphID<GroupTag>
typealias CanvasID = GraphID<CanvasTag>

// MARK: - Geometry
//
// Transforms are normalized to the scene's canvas (0...1, origin top-left) so
// a graph renders identically at any encode resolution.

/// Normalized point in canvas space.
struct GraphPoint: Hashable, Codable, Sendable {
    var x: Double
    var y: Double
}

/// Normalized size as a fraction of the canvas.
struct GraphSize: Hashable, Codable, Sendable {
    var width: Double
    var height: Double
}

/// Which point of a layer `position` refers to.
enum LayerAnchor: String, Codable, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight, center
}

/// Placement of one layer on the canvas. For a camera PIP layer, `size.width`
/// is the classic PIP scale (fraction of frame width, 0.10...0.40); renderers
/// aspect-fit the source, so `size.height` is nominal there.
struct LayerTransform: Hashable, Codable, Sendable {
    var position: GraphPoint
    var size: GraphSize
    var anchor: LayerAnchor
    var rotationDegrees: Double

    init(position: GraphPoint,
         size: GraphSize,
         anchor: LayerAnchor,
         rotationDegrees: Double = 0) {
        self.position = position
        self.size = size
        self.anchor = anchor
        self.rotationDegrees = rotationDegrees
    }

    /// Covers the whole canvas.
    static let fullscreen = LayerTransform(
        position: GraphPoint(x: 0, y: 0),
        size: GraphSize(width: 1, height: 1),
        anchor: .topLeft)

    /// A PIP box anchored in the given corner (margin is applied by the
    /// renderer, matching the compositor's existing inset behavior).
    init(pipCorner: PIPCorner, scale: Double) {
        switch pipCorner {
        case .topLeft:
            anchor = .topLeft
            position = GraphPoint(x: 0, y: 0)
        case .topRight:
            anchor = .topRight
            position = GraphPoint(x: 1, y: 0)
        case .bottomLeft:
            anchor = .bottomLeft
            position = GraphPoint(x: 0, y: 1)
        case .bottomRight:
            anchor = .bottomRight
            position = GraphPoint(x: 1, y: 1)
        }
        size = GraphSize(width: scale, height: scale)
        rotationDegrees = 0
    }
}

extension PIPCorner {
    /// The canvas corner a layer anchor maps to (`.center` has no PIP
    /// equivalent and falls back to the default corner).
    init(anchor: LayerAnchor) {
        switch anchor {
        case .topLeft: self = .topLeft
        case .topRight: self = .topRight
        case .bottomLeft: self = .bottomLeft
        case .bottomRight, .center: self = .bottomRight
        }
    }
}

// MARK: - Effects

struct BorderEffectPayload: Hashable, Codable, Sendable {
    var width: Double
    var colorHex: String
}

struct ChromaKeyEffectPayload: Hashable, Codable, Sendable {
    var colorHex: String
    var tolerance: Double
}

/// Per-layer visual effects. Wire format is a `kind` discriminator plus a
/// typed payload, so new effects are additive and older documents keep
/// decoding. Renderers that don't know an effect simply ignore it.
enum LayerEffect: Hashable, Sendable {
    case opacity(Double)
    case cornerRadius(Double)
    case border(BorderEffectPayload)
    case chromaKey(ChromaKeyEffectPayload)
}

extension LayerEffect: Codable {
    private enum Kind: String, Codable {
        case opacity, cornerRadius, border, chromaKey
    }
    private enum CodingKeys: String, CodingKey {
        case kind, payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .opacity:
            self = .opacity(try container.decode(Double.self, forKey: .payload))
        case .cornerRadius:
            self = .cornerRadius(try container.decode(Double.self, forKey: .payload))
        case .border:
            self = .border(try container.decode(BorderEffectPayload.self, forKey: .payload))
        case .chromaKey:
            self = .chromaKey(try container.decode(ChromaKeyEffectPayload.self, forKey: .payload))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .opacity(let value):
            try container.encode(Kind.opacity, forKey: .kind)
            try container.encode(value, forKey: .payload)
        case .cornerRadius(let value):
            try container.encode(Kind.cornerRadius, forKey: .kind)
            try container.encode(value, forKey: .payload)
        case .border(let payload):
            try container.encode(Kind.border, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .chromaKey(let payload):
            try container.encode(Kind.chromaKey, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        }
    }
}

// MARK: - Audio binding

/// How a layer contributes to the outgoing audio mix.
struct AudioBinding: Hashable, Codable, Sendable {
    var isMuted: Bool
    /// Linear gain, 0...1.
    var volume: Double

    static let `default` = AudioBinding(isMuted: false, volume: 1)
}

// MARK: - Layer payloads
//
// One typed payload per layer kind. Only camera/screen render today (through
// the existing capture pipeline); the rest are model-only until the
// composition engine (W08) lands, but they persist and round-trip now.

struct CameraSourcePayload: Hashable, Codable, Sendable {
    /// Stable capture-device identifier; nil = system default camera.
    var deviceID: String? = nil
}

struct ScreenSourcePayload: Hashable, Codable, Sendable {
    enum Target: String, Codable, CaseIterable, Sendable {
        case display, window, application
    }
    var target: Target = .display
    /// Restorable identifier of the specific display/window/app;
    /// nil = ask through the system content picker on first use.
    var targetIdentifier: String? = nil
}

struct ImageSourcePayload: Hashable, Codable, Sendable {
    var assetIdentifier: String? = nil
}

struct TextSourcePayload: Hashable, Codable, Sendable {
    var text: String = ""
    var fontName: String? = nil
    var fontSize: Double = 48
    var colorHex: String = "#FFFFFF"
}

struct ShapeSourcePayload: Hashable, Codable, Sendable {
    enum ShapeKind: String, Codable, CaseIterable, Sendable {
        case rectangle, roundedRectangle, ellipse
    }
    var shape: ShapeKind = .rectangle
    var fillColorHex: String = "#FFFFFF"
}

struct MediaSourcePayload: Hashable, Codable, Sendable {
    var assetIdentifier: String? = nil
    var loops: Bool = true
}

struct PDFSourcePayload: Hashable, Codable, Sendable {
    var assetIdentifier: String? = nil
    var page: Int = 0
}

struct WebSourcePayload: Hashable, Codable, Sendable {
    var url: URL? = nil
}

struct GuestSourcePayload: Hashable, Codable, Sendable {
    /// Invite/session link identifier for a remote guest feed.
    var sessionIdentifier: String? = nil
}

struct SceneReferencePayload: Hashable, Codable, Sendable {
    /// The scene this layer nests (cycles are rejected at edit time).
    var sceneID: SceneID
}

/// The typed content of one layer. Encoded as a `kind` discriminator string
/// plus a per-kind payload object, decoupled from Swift case names, so the
/// format grows (new kinds) without breaking older persisted documents.
enum LayerPayload: Hashable, Sendable {
    case camera(CameraSourcePayload)
    case screen(ScreenSourcePayload)
    case image(ImageSourcePayload)
    case text(TextSourcePayload)
    case shape(ShapeSourcePayload)
    case media(MediaSourcePayload)
    case pdf(PDFSourcePayload)
    case web(WebSourcePayload)
    case guest(GuestSourcePayload)
    case scene(SceneReferencePayload)

    /// Stable discriminator used on the wire.
    var kind: String {
        switch self {
        case .camera: return "camera"
        case .screen: return "screen"
        case .image: return "image"
        case .text: return "text"
        case .shape: return "shape"
        case .media: return "media"
        case .pdf: return "pdf"
        case .web: return "web"
        case .guest: return "guest"
        case .scene: return "scene"
        }
    }

    var isCamera: Bool {
        if case .camera = self { return true }
        return false
    }

    var isScreen: Bool {
        if case .screen = self { return true }
        return false
    }
}

extension LayerPayload: Codable {
    private enum Kind: String, Codable {
        case camera, screen, image, text, shape, media, pdf, web, guest, scene
    }
    private enum CodingKeys: String, CodingKey {
        case kind, payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .camera:
            self = .camera(try container.decode(CameraSourcePayload.self, forKey: .payload))
        case .screen:
            self = .screen(try container.decode(ScreenSourcePayload.self, forKey: .payload))
        case .image:
            self = .image(try container.decode(ImageSourcePayload.self, forKey: .payload))
        case .text:
            self = .text(try container.decode(TextSourcePayload.self, forKey: .payload))
        case .shape:
            self = .shape(try container.decode(ShapeSourcePayload.self, forKey: .payload))
        case .media:
            self = .media(try container.decode(MediaSourcePayload.self, forKey: .payload))
        case .pdf:
            self = .pdf(try container.decode(PDFSourcePayload.self, forKey: .payload))
        case .web:
            self = .web(try container.decode(WebSourcePayload.self, forKey: .payload))
        case .guest:
            self = .guest(try container.decode(GuestSourcePayload.self, forKey: .payload))
        case .scene:
            self = .scene(try container.decode(SceneReferencePayload.self, forKey: .payload))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .camera(let payload):
            try container.encode(Kind.camera, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .screen(let payload):
            try container.encode(Kind.screen, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .image(let payload):
            try container.encode(Kind.image, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .text(let payload):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .shape(let payload):
            try container.encode(Kind.shape, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .media(let payload):
            try container.encode(Kind.media, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .pdf(let payload):
            try container.encode(Kind.pdf, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .web(let payload):
            try container.encode(Kind.web, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .guest(let payload):
            try container.encode(Kind.guest, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case .scene(let payload):
            try container.encode(Kind.scene, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        }
    }
}

// MARK: - Graph nodes

/// One source instance on a scene's canvas: a typed payload plus placement,
/// visibility, effects, and an audio binding. `sourceID` binds the layer to a
/// project-level `SourceDefinition` when it instantiates one; the inline
/// `payload` stays the render authority so a scene document is self-contained.
struct LayerNode: Identifiable, Hashable, Codable, Sendable {
    var id: LayerID
    var name: String
    var sourceID: SourceDefinitionID?
    var payload: LayerPayload
    var transform: LayerTransform
    var isVisible: Bool
    var effects: [LayerEffect]
    var audio: AudioBinding
    var groupID: GroupID?

    init(id: LayerID = LayerID(),
         name: String,
         sourceID: SourceDefinitionID? = nil,
         payload: LayerPayload,
         transform: LayerTransform,
         isVisible: Bool = true,
         effects: [LayerEffect] = [],
         audio: AudioBinding = .default,
         groupID: GroupID? = nil) {
        self.id = id
        self.name = name
        self.sourceID = sourceID
        self.payload = payload
        self.transform = transform
        self.isVisible = isVisible
        self.effects = effects
        self.audio = audio
        self.groupID = groupID
    }
}

extension LayerNode {
    /// A camera layer covering the whole canvas.
    static func fullscreenCamera(sourceID: SourceDefinitionID? = nil) -> LayerNode {
        LayerNode(name: "Camera",
                  sourceID: sourceID,
                  payload: .camera(CameraSourcePayload()),
                  transform: .fullscreen)
    }

    /// A screen layer covering the whole canvas.
    static func fullscreenScreen(sourceID: SourceDefinitionID? = nil) -> LayerNode {
        LayerNode(name: "Screen",
                  sourceID: sourceID,
                  payload: .screen(ScreenSourcePayload()),
                  transform: .fullscreen)
    }

    /// A camera PIP layer in the given corner; `scale` is the fraction of
    /// frame width (0.10...0.40), exactly the classic PIP scale.
    static func cameraPIP(corner: PIPCorner,
                          scale: Double,
                          sourceID: SourceDefinitionID? = nil) -> LayerNode {
        LayerNode(name: "Camera PIP",
                  sourceID: sourceID,
                  payload: .camera(CameraSourcePayload()),
                  transform: LayerTransform(pipCorner: corner, scale: scale))
    }
}

/// A named grouping of layers (folders in the layer list). Membership is a
/// `groupID` on each `LayerNode`, keeping the graph itself flat and ordered.
struct LayerGroup: Identifiable, Hashable, Codable, Sendable {
    var id: GroupID
    var name: String
    var isCollapsed: Bool

    init(id: GroupID = GroupID(), name: String, isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
    }
}

/// The output surface a scene composes onto. Transforms are normalized, so
/// `referenceSize` only fixes the aspect/intended resolution.
struct Canvas: Identifiable, Hashable, Codable, Sendable {
    var id: CanvasID
    var name: String
    var referenceSize: GraphSize

    init(id: CanvasID = CanvasID(),
         name: String = "1080p",
         referenceSize: GraphSize = GraphSize(width: 1920, height: 1080)) {
        self.id = id
        self.name = name
        self.referenceSize = referenceSize
    }
}

/// A reusable, project-level source (one camera, one display capture, ...)
/// that layers across scenes can instantiate by `sourceID`.
struct SourceDefinition: Identifiable, Hashable, Codable, Sendable {
    var id: SourceDefinitionID
    var name: String
    var payload: LayerPayload

    init(id: SourceDefinitionID = SourceDefinitionID(), name: String, payload: LayerPayload) {
        self.id = id
        self.name = name
        self.payload = payload
    }
}

// MARK: - Scene

/// One switchable scene: an ordered layer graph on a canvas. `layers` is
/// back-to-front — index 0 paints first, the last layer is on top.
struct Scene: Identifiable, Hashable, Codable, Sendable {
    var id: SceneID
    var name: String
    var canvas: Canvas
    var groups: [LayerGroup]
    var layers: [LayerNode]

    init(id: SceneID = SceneID(),
         name: String,
         canvas: Canvas = Canvas(),
         groups: [LayerGroup] = [],
         layers: [LayerNode]) {
        self.id = id
        self.name = name
        self.canvas = canvas
        self.groups = groups
        self.layers = layers
    }
}

extension Scene {
    /// Camera solo: one fullscreen camera layer.
    static func cameraSolo(name: String,
                           id: SceneID = SceneID(),
                           cameraSourceID: SourceDefinitionID? = nil) -> Scene {
        Scene(id: id, name: name,
              layers: [.fullscreenCamera(sourceID: cameraSourceID)])
    }

    /// Screen solo: one fullscreen screen layer.
    static func screenSolo(name: String,
                           id: SceneID = SceneID(),
                           screenSourceID: SourceDefinitionID? = nil) -> Scene {
        Scene(id: id, name: name,
              layers: [.fullscreenScreen(sourceID: screenSourceID)])
    }

    /// Screen with a camera PIP: fullscreen screen at the back, camera PIP
    /// on top preserving corner and scale.
    static func screenPlusCam(name: String,
                              id: SceneID = SceneID(),
                              corner: PIPCorner = .bottomRight,
                              scale: Double = 0.28,
                              screenSourceID: SourceDefinitionID? = nil,
                              cameraSourceID: SourceDefinitionID? = nil) -> Scene {
        Scene(id: id, name: name,
              layers: [.fullscreenScreen(sourceID: screenSourceID),
                       .cameraPIP(corner: corner, scale: scale, sourceID: cameraSourceID)])
    }
}

// MARK: - Document

/// The versioned, persisted scene document (v2): the project, its reusable
/// source registry, every scene's layer graph, and the current selection.
/// `version` drives migration; `SceneDocument.currentVersion` is what
/// `SceneStore` writes.
struct SceneDocument: Hashable, Codable, Sendable {
    static let currentVersion = 2

    var version: Int
    var projectID: ProjectID
    var projectName: String
    var sources: [SourceDefinition]
    var scenes: [Scene]
    var selectedID: SceneID

    init(version: Int = SceneDocument.currentVersion,
         projectID: ProjectID = ProjectID(),
         projectName: String = "Stream Project",
         sources: [SourceDefinition],
         scenes: [Scene],
         selectedID: SceneID) {
        self.version = version
        self.projectID = projectID
        self.projectName = projectName
        self.sources = sources
        self.scenes = scenes
        self.selectedID = selectedID
    }
}
