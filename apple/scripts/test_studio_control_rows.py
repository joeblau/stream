#!/usr/bin/env python3
"""Owned offscreen sizing/scroll proof; never constructs the studio runtime.

Only the two shipping control-row bodies are extracted. Owner types and
popover-owning children are memory-only boundary stubs; all actions are inert.
The real StudioAccessibility text style and StudioControlRow are compiled.
No visible windows, input injection, media, documents or permissions are used.
This is a layout proof, not native VoiceOver/focus/contrast qualification.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile


HEADER = r'''
import AppKit
import SwiftUI
struct FixtureWorkspace { var showRecordingLibrary = false }
enum FixtureRecordingState { case idle, recording, paused, stopping; var isRecording: Bool { self == .recording } }
enum FixturePreview { case idle, active }
enum FixtureStream: Equatable { case idle, failed(String), connecting, live, reconnecting(String), stopping; var isLive: Bool { self == .live } }
struct FixtureState { var recording = FixtureRecordingState.idle; var preview = FixturePreview.idle; var stream = FixtureStream.idle; var hasPendingStagedEdits = true }
enum FixtureCommand { case startRecording, stopRecording, resumeRecording, pauseRecording, startNewRecordingFile, addRecordingMarker(String), startPreview, stopPreview, startStream, stopStream, take, revert }
struct FixtureDispatcher { var state = FixtureState(); func execute(_ command: FixtureCommand) {}; func canExecute(_ command: FixtureCommand) -> Bool { true } }
struct FixtureRecorder { var canStop = false; var state = FixtureRecordingState.idle }
struct FixtureController { var isRehearsing = false }
struct RecordingOptionsView: View { let recorder: FixtureRecorder; var body: some View { Button("Recording Options", systemImage: "slider.horizontal.3") {}.labelStyle(.iconOnly) } }
struct RecordingLibraryView: View { let recorder: FixtureRecorder; var openRequest: Binding<Bool>?; let addMarker: (String) -> Void; var body: some View { Button("Recording Library", systemImage: "film.stack") {}.labelStyle(.iconOnly) } }
struct SessionRecoveryReviewButton: View { var relink: () -> Void; var body: some View { EmptyView() } }
struct FixtureControlsView: View {
    var kind: String
    @State private var workspace = FixtureWorkspace()
    private let dispatcher = FixtureDispatcher(), recorder = FixtureRecorder(), controller = FixtureController()
    private var reduceMotion = true
    private enum InspectorTab { case assets, destinations }
    @State private var inspectorTab = InspectorTab.assets
    @State private var showInspectorPanel = false
    @State private var showPreflight = false
    private var directLiveBinding: Binding<Bool> { .constant(false) }
    var body: some View { if kind == "transport" { transportBar } else { transitionControls } }
'''
MAIN = r'''

@main struct ControlRowLayoutProof {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "StudioControlRows", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func settle(_ window: NSWindow, _ hosting: NSViewController) {
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            hosting.view.layoutSubtreeIfNeeded()
        }
        for value in 11...20 {
            let points = Double(value)
            for kind in ["transport", "transition"] {
                // Each explicit native style owns a fresh hosting hierarchy;
                // this checks static layout, not OS style-change delivery.
                for style in [NSScroller.Style.overlay, .legacy] {
                    let root = FixtureControlsView(kind: kind)
                        .font(.system(size: points))
                        .environment(\.studioTextScale, points / 13)
                        .environment(\.dynamicTypeSize, points >= 18 ? .accessibility1 : points >= 16 ? .xxxLarge : points >= 14 ? .xLarge : .large)
                    let hosting = NSHostingController(rootView: root)
                    let narrow = hosting.sizeThatFits(in: CGSize(width: 320, height: 640))
                    let wide = hosting.sizeThatFits(in: CGSize(width: 844, height: 640))
                    try require(narrow.width <= 320.5, "\(kind) at \(points) points exceeds 320-point canvas minimum: \(narrow)")
                    try require(narrow.height <= wide.height + 0.5, "\(kind) wraps controls vertically at \(points) points: narrow \(narrow) vs wide \(wide)")
                    let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 320, height: narrow.height), styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    defer { window.close() }
                    hosting.sizingOptions = []
                    window.contentViewController = hosting
                    window.setContentSize(narrow)
                    hosting.view.frame = CGRect(origin: .zero, size: narrow)
                    settle(window, hosting)
                    func scrolls(_ view: NSView) -> [NSScrollView] {
                        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrolls($0) }
                    }
                    let views = scrolls(hosting.view)
                    try require(views.count == 1, "Expected one native scroll container for unchanged row")
                    let scroll = views[0]
                    guard let document = scroll.documentView else { throw CocoaError(.coderInvalidValue) }
                    // Only this owned scroll view changes style. No system
                    // preferences are read/written to force classic scrollers.
                    scroll.scrollerStyle = style
                    settle(window, hosting)
                    // Realization/style changes can update intrinsic height.
                    // Use exactly that reported height, with no padded allowance.
                    let measured = hosting.sizeThatFits(in: CGSize(width: 320, height: 640))
                    window.setContentSize(measured)
                    hosting.view.frame = CGRect(origin: .zero, size: measured)
                    settle(window, hosting)
                    try require(scroll.scrollerStyle == style, "The owned native style must remain selected")
                    try require(!window.isVisible && !window.isKeyWindow, "Owned proof window must stay hidden and inactive")
                    try require(abs(scroll.documentVisibleRect.width - 320) < 0.5, "Actual native viewport must fit canvas minimum")
                    try require(scroll.frame.minY >= -0.5 && scroll.frame.maxY <= hosting.view.bounds.height + 0.5,
                        "Reported intrinsic height must contain native scroll view: \(kind) desiredStyle=\(style.rawValue) actualStyle=\(scroll.scrollerStyle.rawValue) measured=\(measured) scroll=\(scroll.frame) host=\(hosting.view.bounds) document=\(document.frame) visible=\(scroll.documentVisibleRect)")
                    try require(document.frame.height > 0 && scroll.documentVisibleRect.height + 0.5 >= document.frame.height,
                        "Reported intrinsic height must expose full control height, including classic scrollbar space: \(kind) measured=\(measured) scroll=\(scroll.frame) document=\(document.frame) visible=\(scroll.documentVisibleRect)")
                    try require(document.frame.width >= 320, "Overflow content was clipped instead of retained")
                    let contentWidth = document.frame.width
                    scroll.contentView.scroll(to: CGPoint(x: max(0, contentWidth - scroll.contentView.bounds.width), y: 0))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    try require(abs(scroll.documentVisibleRect.maxX - contentWidth) < 0.5, "Native scrolling must reach the row's trailing controls")
                    window.setContentSize(CGSize(width: 844, height: measured.height))
                    hosting.view.frame.size.width = 844
                    settle(window, hosting)
                    try require(abs(scroll.documentVisibleRect.width - 844) < 0.5 && document.frame.width >= 843.5,
                        "Wide row must fill viewport, preserving existing Spacer alignment")
                    print("PASS row=\(kind) textPoints=\(value) scroller=\(style == .legacy ? "legacy" : "overlay") minimumCanvasWidth=\(measured.width) reportedHeight=\(measured.height) contentHeight=\(document.frame.height) retainedContentWidth=\(contentWidth) nativeScrollReachedTrailingEdge=true wideViewport=\(scroll.documentVisibleRect.width)")
                }
            }
        }
        print("PASS: 40 owned offscreen row/style cases at configured 11...20-point text; source rows and styles, exact intrinsic height/native scrolling, no runtime/devices/global input/AX claim")
    }
}
'''


def property_source(source, name):
    marker = f"    private var {name}: some View {{"
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    annotation = "    @ViewBuilder\n" if name in ("streamStatusBadge", "goLiveButton") else ""
    return annotation + source[start:end]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--main-window-source", type=Path,
                        help="Alternate row source for exact before/fix comparison.")
    args = parser.parse_args()
    apple = Path(__file__).resolve().parents[1]
    source = (args.main_window_source or apple / "StreamMac/MainWindowView.swift").read_text()
    rows = "\n".join(property_source(source, name) for name in
                     ("transportBar", "streamStatusBadge", "goLiveButton", "transitionControls"))
    # The status badge is a separate method rather than a computed property.
    start = source.index("    private func badge(")
    end = source.index("    /// One button per streaming", start)
    rows += "\n" + source[start:end]
    with tempfile.TemporaryDirectory(prefix="stream-control-row-layout-") as temporary:
        folder = Path(temporary)
        fixture = folder / "OwnedControlRows.swift"
        fixture.write_text(HEADER + rows + "\n}\n" + MAIN)
        executable = folder / "ControlRows"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6",
                        "-strict-concurrency=complete", "-j2", "-parse-as-library",
                        str(apple / "StreamMac/StudioAccessibility.swift"),
                        str(apple / "StreamMac/StudioControlRow.swift"),
                        str(fixture), "-o", str(executable)], check=True, timeout=60)
        subprocess.run([str(executable)], check=True, timeout=20)


if __name__ == "__main__":
    main()
