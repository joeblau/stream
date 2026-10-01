import CoreGraphics
import Foundation

// MARK: - G03 (issue #106): layer styling — masks, borders, shadows, opacity, perspective
//
// One `LayerStyle` value describes the full STYLING stack for a rendered
// layer: the shape mask (rectangle/circle/custom), border, drop shadow,
// opacity, and perspective tilt. Styling is LAYER-level chrome — it reshapes
// and decorates the placed layer image — and is deliberately distinct from
// E01's `SourceEffects` (per-source framing and picture adjustments, which
// reframe/recolor the SOURCE before/after placement) and from the legacy
// `LayerEffect` list (which stays honored: its opacity multiplies with the
// style's, and its corner radius composes under the style mask).
//
// Scope, matching the layer transform/effects precedent: the style lives on
// `LayerNode` (`style`), so it is staged scene content for scene layers
// (edits stage, Take, revert, and undo like the transform) and project-level
// content for overlays (edited through the S07 overlay commands). A style
// NEVER destroys the original media: it renders as a non-destructive pass
// over the placed source image (mask via alpha blend, border via an overlaid
// stroke raster, shadow via a blurred silhouette composited underneath), and
// alpha is preserved end-to-end through the existing premultiplied CI path.
//
// GEOMETRY UNITS: all pixel values (corner radius, feather, border width,
// shadow offset/radius) are REFERENCE pixels on the 1080p canvas and scale
// with the actual render height (the text `fontSize` precedent), so a style
// renders identically at any encode resolution — the LayerGraph invariant.
//
// The render order inside the styling pass (documented so nested/group
// compositions stay predictable):
//   legacy corner-radius mask → STYLE MASK → BORDER → PERSPECTIVE →
//   layer rotation (S04) → OPACITY (legacy × style) → SHADOW.
// Nested scenes style through the exact same tail (`SceneRenderer.
// stylePlaced`), so a styled nested scene behaves like a styled text/shape
// layer; groups are organizational (S03) and carry no transform of their own.
//
// SEAM for follow-up work: E02's chroma-key is a per-layer pixel effect that
// belongs in this pass ahead of the mask (key the placed image, then style
// the keyed alpha); G02's rich text keeps its own payload and renders through
// the generated-content path, so it inherits masks/borders/shadows/perspective
// from this model unchanged. The custom mask's `customAssetIdentifier` is the
// P03 asset-library seam: until the render path can resolve asset identifiers
// it is a documented no-op (the layer renders unmasked).

/// The full styling stack for one rendered layer. Value semantics, additive
/// wire format (every field decodes with its default, so documents written
/// before G03 — or before any later field — keep loading). `.identity`
/// renders the layer untouched.
struct LayerStyle: Hashable, Codable, Sendable {
    /// The shape mask clipping the layer's alpha (none = full rect).
    var mask: LayerMask = LayerMask()
    /// The stroke drawn INSIDE the layer's edge (width 0 = off). The stroke
    /// path follows the mask shape (ellipse for a circle mask, rounded rect
    /// for a rectangle mask) and the plain rect otherwise.
    var border: LayerBorder = LayerBorder()
    /// The drop shadow composited UNDER the finished layer image.
    var shadow: LayerShadow = LayerShadow()
    /// Layer opacity, 0...1 (1 = unchanged). Multiplies with any legacy
    /// `LayerEffect.opacity` — the effects list stays the per-tick fade
    /// surface; this is the styled resting opacity.
    var opacity: Double = 1
    /// The perspective tilt applied to the placed layer (after masking and
    /// border, before rotation).
    var perspective: LayerPerspective = LayerPerspective()

    init() {}

    /// The untouched-layer value.
    static let identity = LayerStyle()

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mask = try container.decodeIfPresent(LayerMask.self, forKey: .mask) ?? LayerMask()
        border = try container.decodeIfPresent(LayerBorder.self, forKey: .border) ?? LayerBorder()
        shadow = try container.decodeIfPresent(LayerShadow.self, forKey: .shadow) ?? LayerShadow()
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        perspective = try container.decodeIfPresent(LayerPerspective.self, forKey: .perspective)
            ?? LayerPerspective()
    }

    var hasMask: Bool { mask.isActive }
    var hasBorder: Bool { border.isActive }
    var hasShadow: Bool { shadow.isActive }
    var hasPerspective: Bool { !perspective.isIdentity }

    /// True when rendering this value costs nothing.
    var isRenderNoOp: Bool {
        !hasMask && !hasBorder && !hasShadow && !hasPerspective && opacity >= 0.999
    }

    /// The value with every field clamped to its documented range (the
    /// dispatcher rejects out-of-range input via `validationError`; the UI
    /// clamps its sliders to the same ranges).
    func clamped() -> LayerStyle {
        var copy = self
        copy.mask = mask.clamped()
        copy.border = border.clamped()
        copy.shadow = shadow.clamped()
        copy.opacity = min(1, max(0, opacity))
        copy.perspective = perspective.clamped()
        return copy
    }

    /// The rejection reason for an out-of-range value, or nil (guards
    /// automation input, like `SourceEffects.validationError`).
    var validationError: String? {
        if !opacity.isFinite || !(0...1).contains(opacity) {
            return "Opacity must be between 0 and 1."
        }
        return mask.validationError
            ?? border.validationError
            ?? shadow.validationError
            ?? perspective.validationError
    }
}

// MARK: - Mask

/// G03 (issue #106): the shape mask clipping a layer's alpha. Rectangle with
/// a corner radius covers the classic rounded-PIP look; circle inscribes an
/// ellipse in the layer rect; custom is the P03 asset-library seam (an
/// unresolved asset identifier renders UNMASKED — the documented fallback,
/// never a black box).
struct LayerMask: Hashable, Codable, Sendable {
    enum Shape: String, Codable, CaseIterable, Sendable {
        case none, rectangle, circle, custom

        var displayName: String {
            switch self {
            case .none: return "None"
            case .rectangle: return "Rectangle"
            case .circle: return "Circle"
            case .custom: return "Custom (Asset)"
            }
        }
    }

    var shape: Shape = .none
    /// Corner radius in 1080p-reference pixels (rectangle shape only),
    /// 0...500.
    var cornerRadius: Double = 0
    /// Edge feather in reference pixels, 0...100 (blurs the mask edge).
    var feather: Double = 0
    /// Inverts the mask (the shape punches a hole; the layer shows AROUND it).
    var isInverted: Bool = false
    /// The P03 asset identifier backing a custom mask. Not resolvable by the
    /// render path yet — a custom mask with no resolvable asset is a no-op.
    var customAssetIdentifier: String? = nil

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shape = try container.decodeIfPresent(Shape.self, forKey: .shape) ?? .none
        cornerRadius = try container.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0
        feather = try container.decodeIfPresent(Double.self, forKey: .feather) ?? 0
        isInverted = try container.decodeIfPresent(Bool.self, forKey: .isInverted) ?? false
        customAssetIdentifier = try container.decodeIfPresent(String.self, forKey: .customAssetIdentifier)
    }

    /// True when the mask clips anything. A custom mask without an asset
    /// identifier is still "active" here (configuration state); the renderer
    /// treats it as the documented unmasked fallback.
    var isActive: Bool { shape != .none }

    func clamped() -> LayerMask {
        var copy = self
        copy.cornerRadius = min(500, max(0, cornerRadius))
        copy.feather = min(100, max(0, feather))
        return copy
    }

    var validationError: String? {
        guard cornerRadius.isFinite, feather.isFinite else {
            return "Mask values must be finite numbers."
        }
        if !(0...500).contains(cornerRadius) {
            return "Mask corner radius must be between 0 and 500."
        }
        if !(0...100).contains(feather) {
            return "Mask feather must be between 0 and 100."
        }
        if shape == .custom,
           let identifier = customAssetIdentifier,
           identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "A custom mask needs an asset identifier."
        }
        return nil
    }
}

// MARK: - Border

/// G03 (issue #106): a stroke drawn INSIDE the layer's edge, on top of the
/// masked content (an outset stroke would spill past the layer's transform
/// rect and break the selection-bounds contract).
struct LayerBorder: Hashable, Codable, Sendable {
    /// Stroke width in reference pixels, 0...200 (0 = off).
    var width: Double = 0
    /// `#RRGGBB` / `#RRGGBBAA` — the alpha half tints the stroke.
    var colorHex: String = "#FFFFFF"

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        width = try container.decodeIfPresent(Double.self, forKey: .width) ?? 0
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex) ?? "#FFFFFF"
    }

    var isActive: Bool { width > 0 }

    func clamped() -> LayerBorder {
        var copy = self
        copy.width = min(200, max(0, width))
        return copy
    }

    var validationError: String? {
        width.isFinite && (0...200).contains(width)
            ? nil : "Border width must be between 0 and 200."
    }
}

// MARK: - Shadow

/// G03 (issue #106): a drop shadow — the layer's alpha silhouette, tinted,
/// blurred, offset, and composited UNDER the layer image. The shadow follows
/// the styled (masked, perspectived, rotated) shape and dims with the layer's
/// opacity; it is decorative and deliberately EXCLUDED from the canvas
/// selection bounds.
struct LayerShadow: Hashable, Codable, Sendable {
    var isEnabled: Bool = false
    /// Offset in reference pixels: +x right, +y DOWN (top-left semantics,
    /// like `LayerTransform`).
    var offsetX: Double = 0
    var offsetY: Double = 8
    /// Blur radius in reference pixels, 0...200.
    var radius: Double = 12
    /// `#RRGGBB` / `#RRGGBBAA` (the default is 50%-alpha black).
    var colorHex: String = "#00000080"

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        offsetX = try container.decodeIfPresent(Double.self, forKey: .offsetX) ?? 0
        offsetY = try container.decodeIfPresent(Double.self, forKey: .offsetY) ?? 8
        radius = try container.decodeIfPresent(Double.self, forKey: .radius) ?? 12
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex) ?? "#00000080"
    }

    var isActive: Bool { isEnabled }

    func clamped() -> LayerShadow {
        var copy = self
        copy.offsetX = min(1000, max(-1000, offsetX))
        copy.offsetY = min(1000, max(-1000, offsetY))
        copy.radius = min(200, max(0, radius))
        return copy
    }

    var validationError: String? {
        guard offsetX.isFinite, offsetY.isFinite, radius.isFinite else {
            return "Shadow values must be finite numbers."
        }
        if !(-1000...1000).contains(offsetX) || !(-1000...1000).contains(offsetY) {
            return "Shadow offset must be between -1000 and 1000."
        }
        return (0...200).contains(radius)
            ? nil : "Shadow radius must be between 0 and 200."
    }
}

// MARK: - Perspective

/// G03 (issue #106): a perspective tilt of the placed layer — yaw around the
/// vertical axis and pitch around the horizontal axis through the layer
/// center, projected with a fixed focal length (1.5× the rect's long side,
/// deep enough that ±80° stays well clear of the projection singularity).
/// Positive yaw brings the RIGHT edge toward the viewer; positive pitch
/// brings the TOP edge toward the viewer. The 2D rotation
/// (`LayerTransform.rotationDegrees`) applies AFTER the tilt, so "rotate then
/// read the tilt" never surprises: tilt is always in the layer's own frame.
struct LayerPerspective: Hashable, Codable, Sendable {
    /// Degrees, -80...80 (0 = flat).
    var yawDegrees: Double = 0
    var pitchDegrees: Double = 0

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        yawDegrees = try container.decodeIfPresent(Double.self, forKey: .yawDegrees) ?? 0
        pitchDegrees = try container.decodeIfPresent(Double.self, forKey: .pitchDegrees) ?? 0
    }

    var isIdentity: Bool { yawDegrees == 0 && pitchDegrees == 0 }

    func clamped() -> LayerPerspective {
        var copy = self
        copy.yawDegrees = min(80, max(-80, yawDegrees))
        copy.pitchDegrees = min(80, max(-80, pitchDegrees))
        return copy
    }

    var validationError: String? {
        guard yawDegrees.isFinite, pitchDegrees.isFinite else {
            return "Perspective angles must be finite numbers."
        }
        return (-80...80).contains(yawDegrees) && (-80...80).contains(pitchDegrees)
            ? nil : "Perspective angles must be between -80° and 80°."
    }

    /// The focal length for a rect: 1.5× its long side (keeps the projection
    /// denominator strictly positive across the whole ±80° range).
    static func focalLength(for rect: CGRect) -> CGFloat {
        max(rect.width, rect.height, 1) * 1.5
    }

    /// Projects the rect's corners through the tilt, in Y-DOWN coordinates
    /// (the rect's min-Y edge is its visual top — the `LayerTransform` /
    /// `CanvasGeometry` space; the CI renderer flips into and out of this
    /// space at its boundary). Returns the corners in the same order the
    /// `CIPerspectiveTransform` filter takes them: topLeft, topRight,
    /// bottomRight, bottomLeft. An identity perspective returns the rect's
    /// own corners.
    func projectedCorners(of rect: CGRect)
        -> (topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        let tl = CGPoint(x: rect.minX, y: rect.minY)
        let tr = CGPoint(x: rect.maxX, y: rect.minY)
        let br = CGPoint(x: rect.maxX, y: rect.maxY)
        let bl = CGPoint(x: rect.minX, y: rect.maxY)
        guard !isIdentity else { return (tl, tr, br, bl) }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let focal = Self.focalLength(for: rect)
        let yaw = CGFloat(yawDegrees) * .pi / 180
        let pitch = CGFloat(pitchDegrees) * .pi / 180
        let cosYaw = cos(yaw), sinYaw = sin(yaw)
        let cosPitch = cos(pitch), sinPitch = sin(pitch)

        func project(_ point: CGPoint) -> CGPoint {
            let x = point.x - center.x
            let y = point.y - center.y
            // Yaw about the vertical axis (z points AWAY from the viewer):
            // positive yaw moves the right edge (x > 0) to negative z.
            let x1 = x * cosYaw
            let z1 = -x * sinYaw
            // Pitch about the horizontal axis (right-handed with x right,
            // y down, z away): positive pitch moves the top edge (y < 0 in
            // y-down space) to negative z — toward the viewer.
            let y2 = y * cosPitch - z1 * sinPitch
            let z2 = y * sinPitch + z1 * cosPitch
            // Perspective divide — z2 > -focal across the clamped range.
            let scale = focal / (focal + z2)
            return CGPoint(x: center.x + x1 * scale, y: center.y + y2 * scale)
        }
        return (project(tl), project(tr), project(br), project(bl))
    }
}

// MARK: - Reusable presets

/// G03 (issue #106): a named, reusable `LayerStyle` value. Presets are
/// PROJECT-level (persisted once in the scene document, the E01
/// `SourceEffectPreset` precedent) and hold a complete style: applying one
/// WRITES its value as the layer's style, so later preset edits never
/// re-point existing users. Reset is the inverse — writing `.identity`.
enum LayerStylePresetTag {}
typealias LayerStylePresetID = GraphID<LayerStylePresetTag>

struct LayerStylePreset: Identifiable, Hashable, Codable, Sendable {
    var id: LayerStylePresetID
    var name: String
    var style: LayerStyle

    init(id: LayerStylePresetID = LayerStylePresetID(), name: String, style: LayerStyle) {
        self.id = id
        self.name = name
        self.style = style
    }
}
