#!/usr/bin/env python3
"""Hidden native geometry proof of the actual annotation toolbar, with inert owners.
No production runtime/store constructors, documents, preferences, device discovery,
activation, screen images, input injection, AX API, media or network are used.
"""
import argparse
import hashlib
import json
import shutil
from pathlib import Path
import subprocess
import tempfile

HEADER = r'''import AppKit
import SwiftUI
typealias SceneID = UUID
struct FixtureScene { let id = UUID() }
@MainActor final class PreviewProgramModel: ObservableObject {
    @Published var stagedScene: FixtureScene?
    init(selected: Bool) { stagedScene = selected ? FixtureScene() : nil }
}
@MainActor final class AnnotationStore: ObservableObject {
    static let palette = ["#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#0A84FF", "#FFFFFF"]
    var colorHex = "#FF3B30", penWidth = 6.0, highlighterWidth = 28.0
}
enum FixtureCommand {
    case setAnnotationTool(AnnotationTool?), undoAnnotationStroke(in: SceneID?), clearAnnotations(in: SceneID?)
    case setAnnotationVisibility(visible: Bool, in: SceneID?), setAnnotationsInProgram(Bool, in: SceneID?)
}
struct FixtureState { var annotations = AnnotationUIState() }
@MainActor final class StudioCommandDispatcher: ObservableObject {
    @Published var state = FixtureState()
    let annotations = AnnotationStore()
    func execute(_ command: FixtureCommand) {}
    func canExecute(_ command: FixtureCommand) -> Bool { true }
}
'''
MAIN = r'''
@main struct AnnotationToolbarLayoutProof {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "AnnotationLayout", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func controls(_ view: NSView) -> [NSControl] {
            if view is NSScroller { return [] }
            return (view as? NSControl).map { [$0] } ?? view.subviews.flatMap(controls)
        }
        func scrolls(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
        }
        func settle(_ window: NSWindow, _ hosting: NSViewController) {
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
            hosting.view.layoutSubtreeIfNeeded()
        }
        var cases: [[String: Any]] = []
        for points in [11.0, 16.0, 20.0] {
            for width in [320.0, 640.0, 844.0, 1280.0] {
                for tool: AnnotationTool? in [nil, .pen, .highlighter, .pointer] {
                    for selected in [true, false] {
                        for style in [NSScroller.Style.overlay, .legacy] {
                            let dispatcher = StudioCommandDispatcher()
                            dispatcher.state.annotations.activeTool = tool
                            let preview = PreviewProgramModel(selected: selected)
                            let root = AnnotationToolbarView()
                                .environmentObject(dispatcher).environmentObject(preview)
                                .font(.system(size: points))
                                .environment(\.studioTextScale, points / 13)
                                .environment(\.dynamicTypeSize, points >= 18 ? .accessibility1 : points >= 16 ? .xxxLarge : .large)
                            let hosting = NSHostingController(rootView: root)
                            let name = tool?.rawValue ?? "select"
                            let initial = hosting.sizeThatFits(in: CGSize(width: width, height: 1000))
                            try require(initial.width.isFinite && initial.height.isFinite && initial.height > 0,
                                        "Toolbar must report finite nonzero geometry")
                            try require(initial.width <= width + 0.5,
                                        "Actual annotation toolbar exceeds \(width)-point canvas: \(initial), tool=\(name), text=\(points)")
                            let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: width, height: initial.height),
                                styleMask: .borderless, backing: .buffered, defer: false)
                            window.isReleasedWhenClosed = false
                            hosting.sizingOptions = []
                            window.contentViewController = hosting
                            window.setContentSize(CGSize(width: width, height: initial.height))
                            hosting.view.frame = CGRect(x: 0, y: 0, width: width, height: initial.height)
                            settle(window, hosting)
                            let scrollViews = scrolls(hosting.view)
                            try require(scrollViews.count == 1, "One native scroll container must retain one set of toolbar controls")
                            let scroll = scrollViews[0]
                            guard let document = scroll.documentView else { throw CocoaError(.coderInvalidValue) }
                            scroll.scrollerStyle = style
                            settle(window, hosting)
                            let measured = hosting.sizeThatFits(in: CGSize(width: width, height: 1000))
                            window.setContentSize(CGSize(width: width, height: measured.height))
                            hosting.view.frame = CGRect(x: 0, y: 0, width: width, height: measured.height)
                            settle(window, hosting)
                            try require(!window.isVisible && !window.isKeyWindow, "Owned window must stay hidden and non-key")
                            try require(scroll.scrollerStyle == style, "Owned scroll style must remain selected")
                            try require(measured.width <= width + 0.5 && abs(scroll.documentVisibleRect.width - width) < 0.5,
                                        "Native viewport must fit actual canvas width")
                            try require(scroll.frame.minY >= -0.5 && scroll.frame.maxY <= measured.height + 0.5,
                                        "Reported height must contain the native scroll view")
                            try require(document.frame.height > 0 && scroll.documentVisibleRect.height + 0.5 >= document.frame.height,
                                        "Full toolbar height must remain visible including legacy scrollbar space")
                            let native = controls(document)
                            try require(native.count == 3, "One actual native tool picker and two switches must remain mounted")
                            var nativeGeometry: [[String: Any]] = []
                            for control in native {
                                let rect = control.convert(control.bounds, to: document)
                                let intrinsic = control.intrinsicContentSize
                                try require(rect.minX >= -0.5 && rect.maxX <= document.bounds.width + 0.5 && rect.minY >= -0.5 && rect.maxY <= document.bounds.height + 0.5,
                                            "Native control escapes retained document: \(type(of: control)) \(rect), document=\(document.bounds)")
                                if control is NSSegmentedControl, intrinsic.width > 0 {
                                    try require(rect.width + 0.5 >= intrinsic.width && document.frame.width >= intrinsic.width,
                                                "Tool picker must retain its native intrinsic width: \(rect), intrinsic=\(intrinsic)")
                                }
                                nativeGeometry.append(["type": String(describing: type(of: control)),
                                    "frameInDocument": ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height],
                                    "intrinsicSize": ["width": intrinsic.width, "height": intrinsic.height], "enabled": control.isEnabled])
                            }
                            scroll.contentView.scroll(to: .zero)
                            scroll.reflectScrolledClipView(scroll.contentView)
                            try require(abs(scroll.documentVisibleRect.minX) < 0.5, "Native scroll must reach leading controls")
                            let trailing = max(0, document.frame.width - scroll.contentView.bounds.width)
                            scroll.contentView.scroll(to: CGPoint(x: trailing, y: 0))
                            scroll.reflectScrolledClipView(scroll.contentView)
                            try require(abs(scroll.documentVisibleRect.maxX - document.frame.width) < 0.5,
                                        "Native scroll must reach trailing controls")
                            if width == 1280 {
                                let rightEdge = native.map { $0.convert($0.bounds, to: document).maxX }.max()!
                                try require(abs(document.frame.width - width) < 0.5 && abs(rightEdge - (width - 16)) < 2,
                                            "Wide toolbar must fill viewport and retain Spacer/trailing gates")
                            }
                            cases.append(["width": width, "textPoints": points, "selection": name, "hasStagedScene": selected,
                                "scrollerStyle": style == .legacy ? "legacy" : "overlay",
                                "reportedWidth": measured.width, "reportedHeight": measured.height,
                                "documentWidth": document.frame.width, "documentHeight": document.frame.height,
                                "viewportWidth": scroll.documentVisibleRect.width, "viewportHeight": scroll.documentVisibleRect.height,
                                "leadingAndTrailingReached": true, "nativeControls": nativeGeometry,
                                "hidden": !window.isVisible, "nonKey": !window.isKeyWindow])
                            window.close()
                            print("PASS width=\(width) points=\(points) selection=\(name) scene=\(selected) style=\(style.rawValue) height=\(measured.height) document=\(document.frame.size) viewport=\(scroll.documentVisibleRect.size)")
                        }
                    }
                }
            }
        }
        let report = try JSONSerialization.data(withJSONObject: ["cases": cases, "caseCount": cases.count,
            "scope": "Actual toolbar geometry/intrinsic native picker/native scroll with inert owners; no whole-window, AX, keyboard, glyph/pixel or contrast qualification"], options: [.prettyPrinted, .sortedKeys])
        try report.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("PASS: \(cases.count) actual annotation toolbar native geometry/scroll cases")
    }
}

'''

def definition(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        if source[end] == "{": depth += 1
        elif source[end] == "}": depth -= 1
        end += 1
    return source[start:end]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--toolbar-source", type=Path)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path, help="Retain the exact generated fixture and executable in an owned folder")
    args = parser.parse_args()
    apple = Path(__file__).resolve().parents[1]
    toolbar = (args.toolbar_source or apple / "StreamMac/AnnotationToolbarView.swift").read_text()
    toolbar = toolbar.replace("import StreamCore\n", "")
    model = (apple / "StreamMac/AnnotationModel.swift").read_text()
    definitions = "\n".join(definition(model, marker) for marker in
        ["struct AnnotationPointerState:", "struct AnnotationUIState:"])
    definitions += "\n" + definition((apple / "StreamMac/LayerGraph.swift").read_text(), "enum HexColor {")
    with tempfile.TemporaryDirectory(prefix="stream-annotation-layout-") as temporary:
        folder = Path(temporary)
        fixture = folder / "OwnedAnnotationToolbar.swift"
        fixture.write_text(HEADER + definitions + "\n" + toolbar + MAIN)
        executable = folder / "AnnotationToolbarLayout"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-strict-concurrency=complete", "-j2", "-parse-as-library",
            str(apple / "StreamCore/Annotations.swift"), str(apple / "StreamMac/StudioAccessibility.swift"),
            str(apple / "StreamMac/StudioControlRow.swift"),
            str(fixture), "-o", str(executable)], check=True, timeout=90)
        subprocess.run([str(executable), str(args.report)], check=True, timeout=90)
        sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
        report = json.loads(args.report.read_text())
        inputs = [apple / "StreamCore/Annotations.swift", apple / "StreamMac/StudioAccessibility.swift",
            apple / "StreamMac/StudioControlRow.swift", apple / "StreamMac/AnnotationModel.swift",
            apple / "StreamMac/LayerGraph.swift", Path(__file__).resolve()]
        report["sourceHashes"] = {str(path.relative_to(apple)): sha(path) for path in inputs}
        report["toolbarSourceSHA256"] = sha(args.toolbar_source or apple / "StreamMac/AnnotationToolbarView.swift")
        report["generatedFixtureSHA256"] = sha(fixture)
        report["executableSHA256"] = sha(executable)
        if args.artifacts:
            args.artifacts.mkdir(parents=True, exist_ok=True)
            shutil.copy2(fixture, args.artifacts / fixture.name)
            shutil.copy2(executable, args.artifacts / executable.name)
        args.report.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")

if __name__ == "__main__": main()
