import Foundation
import StreamCore

enum StudioStarter: String, CaseIterable, Identifiable {
    case desktop = "Desktop Demo"
    case tutorial = "Gaming / Tutorial"
    case camera = "Solo Camera"
    case slides = "Slides + PIP"
    case interview = "Interview"
    case starting = "Starting Soon"
    case pause = "Break"
    case ending = "Ending"
    var id: String { rawValue }
    var guidance: String {
        switch self {
        case .desktop, .tutorial: return "Select the screen/app to share and choose a camera. Configure your microphone in the mixer."
        case .camera: return "Choose a camera in Sources and adjust the title and microphone."
        case .slides: return "Import a PDF in Sources and bind the Slides placeholder to its PDF source. Choose a camera for PIP."
        case .interview: return "Replace the editable participant placeholders with cameras or qualified guest sources. Guest networking needs a configured interview service."
        case .starting, .pause, .ending: return "Edit the title, colors, and timer. Add optional licensed music in Sound; no account is required."
        }
    }

    func scene(camera: SourceDefinitionID?, screen: SourceDefinitionID?, profile: OutputProfile) -> Scene {
        var scene: Scene
        switch self {
        case .desktop, .tutorial:
            scene = .screenPlusCam(name: rawValue, screenSourceID: screen, cameraSourceID: camera)
        case .slides:
            scene = .screenPlusCam(name: rawValue, screenSourceID: screen, cameraSourceID: camera)
            scene.layers[0].payload = .pdf(PDFSourcePayload())
            scene.layers[0].sourceID = nil
            scene.layers[0].name = "Slides · choose a PDF source"
        case .camera:
            scene = .cameraSolo(name: rawValue, cameraSourceID: camera)
        case .interview:
            scene = Scene(name: rawValue, layers: [
                LayerNode(name: "Host Camera", sourceID: camera, payload: .camera(CameraSourcePayload()),
                    transform: LayerTransform(position: GraphPoint(x: 0.025, y: 0.14), size: GraphSize(width: 0.46, height: 0.70), anchor: .topLeft)),
                LayerNode(name: "Participant Placeholder", payload: .shape(ShapeSourcePayload(fillColorHex: "#253858")),
                    transform: LayerTransform(position: GraphPoint(x: 0.515, y: 0.14), size: GraphSize(width: 0.46, height: 0.70), anchor: .topLeft))
            ])
        case .starting, .pause, .ending:
            scene = Scene(name: rawValue, layers: [])
            scene.background = .solid(colorHex: "#13223C")
        }
        let fontSize = profile.canvasHeight > profile.canvasWidth ? 44.0 : 56.0
        let title = LayerNode(name: "Editable Title", payload: .text(TextSourcePayload(text: rawValue,
            fontSize: fontSize, alignment: .center, backgroundColorHex: "#13223C", padding: 12)),
            transform: LayerTransform(position: GraphPoint(x: 0.05, y: 0.02), size: GraphSize(width: 0.9, height: 0.11), anchor: .topLeft))
        scene.layers.append(title)
        if self == .starting || self == .pause {
            var timer = TimerOverlayConfiguration(durationSeconds: self == .starting ? 300 : 600)
            timer.zeroMessage = self == .starting ? "Starting now" : "Back soon"
            scene.layers.append(LayerNode(name: "Editable Countdown", payload: .text(TextSourcePayload(fontSize: fontSize * 1.5,
                alignment: .center, timer: timer)), transform: LayerTransform(position: GraphPoint(x: 0.10, y: 0.42),
                    size: GraphSize(width: 0.8, height: 0.25), anchor: .topLeft)))
        }
        if self == .interview {
            scene.layers.append(LayerNode(name: "Participant Name", payload: .text(TextSourcePayload(text: "Guest · choose a source", fontSize: fontSize / 2,
                alignment: .center)), transform: LayerTransform(position: GraphPoint(x: 0.515, y: 0.87), size: GraphSize(width: 0.46, height: 0.09), anchor: .topLeft)))
        }
        var logo = LayerNode(name: "Optional Logo · choose a local image", payload: .image(ImageSourcePayload()),
            transform: LayerTransform(position: GraphPoint(x: 0.84, y: 0.02), size: GraphSize(width: 0.12, height: 0.10), anchor: .topLeft))
        logo.isVisible = false
        scene.layers.append(logo)
        if self == .starting || self == .pause || self == .ending {
            scene.soundBindings.append(SceneSoundBinding(rule: .continue, name: "Optional Music · choose a local audio file", volume: 0))
        }
        return scene
    }
}
