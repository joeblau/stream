import Foundation

/// Strings retain incomplete keyboard edits. Unchanged displayed fields retain
/// their original full precision instead of round-tripping formatted numbers.
struct LayerGeometryDraft: Equatable {
    enum Field: String, CaseIterable {
        case x, y, width, height, rotation
        var label: String {
            switch self {
            case .x: "Horizontal position (%)"
            case .y: "Vertical position (%)"
            case .width: "Width (%)"
            case .height: "Height (%)"
            case .rotation: "Rotation (degrees)"
            }
        }
        func value(in transform: LayerTransform) -> Double {
            switch self {
            case .x: transform.position.x
            case .y: transform.position.y
            case .width: transform.size.width
            case .height: transform.size.height
            case .rotation: transform.rotationDegrees
            }
        }
        func set(_ value: Double, in transform: inout LayerTransform) {
            switch self {
            case .x: transform.position.x = value
            case .y: transform.position.y = value
            case .width: transform.size.width = value
            case .height: transform.size.height = value
            case .rotation: transform.rotationDegrees = value
            }
        }
    }
    private let initial: [Field: String]
    var values: [Field: String]
    init(_ transform: LayerTransform) {
        let fields = Dictionary(uniqueKeysWithValues: Field.allCases.map { field in
            let value = field.value(in: transform) * (field == .rotation ? 1 : 100)
            return (field, value.isFinite ? String(format: "%.6f", value)
                .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) : "Unavailable")
        })
        initial = fields; values = fields
    }
    var isDirty: Bool { values != initial }
    func resolved(baseline: LayerTransform, current: LayerTransform, canvas: CGSize,
                  isCamera: Bool = false) -> Result<LayerTransform, GeometryError> {
        guard canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0 else {
            return .failure(.invalid("Canvas geometry is unavailable."))
        }
        var result = current
        for field in Field.allCases where values[field] != initial[field] {
            guard field.value(in: current) == field.value(in: baseline) else {
                return .failure(.invalid("\(field.label) changed while you were editing. Reload the current geometry before applying."))
            }
            guard let raw = values[field], let typed = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), typed.isFinite else {
                return .failure(.invalid("Enter a finite number for \(field.label). Use a decimal point for fractions."))
            }
            let value = typed / (field == .rotation ? 1 : 100)
            if field == .width || field == .height {
                let pixels = value * (field == .width ? canvas.width : canvas.height)
                guard pixels.isFinite, pixels >= 4 else {
                    return .failure(.invalid("Width and height must be at least four canvas pixels, matching the canvas resize handles."))
                }
            }
            field.set(value, in: &result)
        }
        if isCamera, result.size.width < 1 {
            if values[.width] != initial[.width], !(0.10...0.40).contains(result.size.width) {
                return .failure(.invalid("Camera PIP width must be 10–40%. Use at least 100% to edit an ordinary camera box; the existing renderer clamps smaller camera boxes to PIP width."))
            }
            if values[.height] != initial[.height] {
                return .failure(.invalid("Camera PIP height follows the source aspect ratio. Use width of at least 100% before editing its height."))
            }
        }
        // The existing model allows off-canvas positions and enlarged layers.
        // Reject invalid arithmetic, not an invented normalized 0...1 clamp.
        let width = result.size.width * canvas.width, height = result.size.height * canvas.height
        let x = result.position.x * canvas.width, y = result.position.y * canvas.height
        // Selection chrome rotates corners and adds pairs before dividing to
        // obtain midpoints. Keep those intermediate sums finite as well.
        let cornerBudgetX = abs(x) + 2 * width + 2 * height
        let cornerBudgetY = abs(y) + 2 * width + 2 * height
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width.rounded(.up) < Double(Int.max), height.rounded(.up) < Double(Int.max),
              x.isFinite, y.isFinite, (x - width).isFinite, (x + width).isFinite,
              (y - height).isFinite, (y + height).isFinite,
              (cornerBudgetX * 4).isFinite, (cornerBudgetY * 4).isFinite,
              result.rotationDegrees.isFinite, (result.rotationDegrees * .pi / 180).isFinite else {
            return .failure(.invalid("Geometry exceeds the finite canvas coordinates supported by the renderer."))
        }
        // The renderer accounts for raster bytes before its cache cap. Safe
        // individual Int dimensions do not imply a safe width*height*4 product.
        let pixelCount = Int(width.rounded(.up)).multipliedReportingOverflow(by: Int(height.rounded(.up)))
        let rasterBytes = pixelCount.partialValue.multipliedReportingOverflow(by: 4)
        guard !pixelCount.overflow, !rasterBytes.overflow,
              !rasterBytes.partialValue.addingReportingOverflow(SceneRenderer.generatedCacheByteLimit).overflow else {
            return .failure(.invalid("Geometry exceeds the raster accounting supported by the renderer."))
        }
        return .success(result)
    }
    func cameraPIPWidth(current: LayerTransform) -> Double? {
        guard let raw = values[.width], let number = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite else { return nil }
        return values[.width] == initial[.width] ? current.size.width : number / 100
    }
    enum GeometryError: Error, LocalizedError {
        case invalid(String)
        var errorDescription: String? { switch self { case .invalid(let message): message } }
    }
}
