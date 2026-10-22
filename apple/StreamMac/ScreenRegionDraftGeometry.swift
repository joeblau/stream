import Foundation
import CoreGraphics

/// Text remains a draft, including incomplete/invalid input. Geometry is never
/// clamped into a different crop; only a finite, bounded rect can be applied.
struct ScreenRegionDraftGeometry: Equatable {
    enum Field: CaseIterable, Hashable {
        case x, y, width, height
        var title: String {
            switch self {
            case .x: return "X"
            case .y: return "Y"
            case .width: return "Width"
            case .height: return "Height"
            }
        }
    }

    let displaySize: CGSize
    private var values: [Field: String]

    static func validDisplaySize(_ size: CGSize?) -> CGSize? {
        guard let size, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return size
    }

    init?(rect: CGRect? = nil, displaySize: CGSize) {
        guard Self.validDisplaySize(displaySize) != nil else { return nil }
        self.displaySize = displaySize
        let rect = rect ?? CGRect(origin: .zero, size: displaySize)
        values = [.x: Self.text(rect.origin.x), .y: Self.text(rect.origin.y),
                  .width: Self.text(rect.size.width), .height: Self.text(rect.size.height)]
    }

    subscript(field: Field) -> String {
        get { values[field] ?? "" }
        set { values[field] = newValue }
    }

    private func number(_ field: Field) -> CGFloat? {
        guard let value = Double(self[field].trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite else { return nil }
        return CGFloat(value)
    }

    var validationMessage: String? {
        guard let x = number(.x), let y = number(.y),
              let width = number(.width), let height = number(.height) else {
            return "Enter finite numbers for X, Y, Width, and Height."
        }
        guard x >= 0, y >= 0 else { return "X and Y must be zero or greater." }
        guard width >= 32, height >= 32 else { return "Width and Height must be at least 32 display points." }
        guard width <= displaySize.width, height <= displaySize.height,
              x <= displaySize.width - width, y <= displaySize.height - height else {
            return "The region must fit within the display's point dimensions."
        }
        return nil
    }

    var rect: CGRect? {
        guard validationMessage == nil,
              let x = number(.x), let y = number(.y),
              let width = number(.width), let height = number(.height) else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    func stepping(_ field: Field, by delta: CGFloat) -> Self? {
        guard let value = number(field), delta.isFinite else { return nil }
        var next = self
        next[field] = Self.text(value + delta)
        return next.rect == nil ? nil : next
    }

    /// Preserve relative geometry when live display dimensions replace stored
    /// dimensions, using capture's scale factors without its final intersection.
    /// Out-of-bounds or invalid text stays invalid instead of silently clipping.
    func rebased(to displaySize: CGSize) -> Self? {
        guard var next = Self(displaySize: displaySize) else { return nil }
        for field in Field.allCases {
            guard let value = number(field) else { next[field] = self[field]; continue }
            let scale = field == .x || field == .width
                ? displaySize.width / self.displaySize.width
                : displaySize.height / self.displaySize.height
            next[field] = Self.text(value * scale)
        }
        return next
    }

    private static func text(_ value: CGFloat) -> String {
        let text = String(Double(value))
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}
