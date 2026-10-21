import Foundation
import StreamCore

enum GuestLayoutTemplate: String, CaseIterable, Identifiable {
    case solo = "Solo"
    case sideBySide = "Side by Side"
    case grid = "Grid"
    case pictureInPicture = "Picture in Picture"
    case screenAndGuests = "Screen + Guests"
    var id: String { rawValue }
    var minimumSlots: Int { self == .sideBySide || self == .pictureInPicture ? 2 : 1 }
    var guidance: String {
        switch self {
        case .solo: return "Uses the first slot."
        case .sideBySide, .pictureInPicture: return "Uses the first two slots."
        case .grid: return "Uses every prepared slot."
        case .screenAndGuests: return "Uses the first slot's screen and every prepared camera."
        }
    }

    func scene(slots: [GuestSlot], profile: OutputProfile) -> Scene? {
        guard slots.count >= minimumSlots, slots.count <= 10 else { return nil }
        var layers: [LayerNode] = []
        func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> LayerTransform {
            LayerTransform(position: GraphPoint(x: x, y: y), size: GraphSize(width: width, height: height), anchor: .topLeft)
        }
        func participant(_ slot: GuestSlot, transform: LayerTransform, screen: Bool = false) {
            let label = screen ? "Shared screen" : slot.offlineMessage
            layers.append(LayerNode(name: "\(slot.name) · Editable Placeholder", payload: .shape(ShapeSourcePayload(fillColorHex: slot.placeholderColorHex)), transform: transform))
            layers.append(LayerNode(name: "\(slot.name) · Offline Message", payload: .text(TextSourcePayload(text: label,
                fontSize: min(24, 1080 * transform.size.height * 0.12), alignment: .center, wraps: false, overflow: .scaleDown)), transform: rect(transform.position.x, transform.position.y + transform.size.height * 0.36, transform.size.width, transform.size.height * 0.22)))
            layers.append(LayerNode(name: "\(slot.name) · \(screen ? "Screen" : "Camera")", sourceID: screen ? slot.screenSourceID : slot.cameraSourceID,
                payload: .guest(GuestSourcePayload()), transform: transform))
            if !screen {
                layers.append(LayerNode(name: "\(slot.name) · Automatic Name", payload: .text(TextSourcePayload(text: slot.nameTemplate,
                    fontSize: min(28, 1080 * transform.size.height * 0.07), alignment: .leading, backgroundColorHex: "#13223C", padding: 0, wraps: false, overflow: .scaleDown)),
                    transform: rect(transform.position.x, transform.position.y + transform.size.height * 0.78, transform.size.width, transform.size.height * 0.12)))
                layers.append(LayerNode(name: "\(slot.name) · Automatic Title", payload: .text(TextSourcePayload(text: slot.titleTemplate,
                    fontSize: min(20, 1080 * transform.size.height * 0.06), alignment: .leading, backgroundColorHex: "#13223C", padding: 0, wraps: false, overflow: .scaleDown)),
                    transform: rect(transform.position.x, transform.position.y + transform.size.height * 0.90, transform.size.width, transform.size.height * 0.10)))
            }
        }
        switch self {
        case .solo:
            participant(slots[0], transform: rect(0.03, 0.03, 0.94, 0.94))
        case .sideBySide:
            participant(slots[0], transform: rect(0.025, 0.10, 0.46, 0.80))
            participant(slots[1], transform: rect(0.515, 0.10, 0.46, 0.80))
        case .pictureInPicture:
            participant(slots[0], transform: rect(0, 0, 1, 1))
            participant(slots[1], transform: rect(0.69, 0.62, 0.28, 0.34))
        case .grid:
            let columns = slots.count <= 4 ? min(2, slots.count) : (slots.count <= 9 ? 3 : 4)
            let rows = Int(ceil(Double(slots.count) / Double(columns)))
            let width = 0.94 / Double(columns), height = 0.94 / Double(rows)
            for (index, slot) in slots.enumerated() {
                participant(slot, transform: rect(0.03 + Double(index % columns) * width, 0.03 + Double(index / columns) * height, width - 0.015, height - 0.02))
            }
        case .screenAndGuests:
            participant(slots[0], transform: rect(0.02, 0.02, 0.72, 0.96), screen: true)
            let columns = slots.count > 5 ? 2 : 1
            let rows = Int(ceil(Double(slots.count) / Double(columns)))
            let height = 0.96 / Double(rows), width = 0.22 / Double(columns)
            for (index, slot) in slots.enumerated() {
                participant(slot, transform: rect(0.76 + Double(index % columns) * width,
                    0.02 + Double(index / columns) * height, width - 0.005, height - 0.01))
            }
        }
        var scene = Scene(name: "Interview · \(rawValue)", layers: layers)
        scene.canvas.referenceSize = GraphSize(width: Double(profile.canvasWidth), height: Double(profile.canvasHeight))
        scene.background = .solid(colorHex: "#13223C")
        return scene
    }
}
