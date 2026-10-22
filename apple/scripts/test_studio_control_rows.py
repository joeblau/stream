#!/usr/bin/env python3
"""Owned offscreen sizing/scroll proof; never constructs the studio runtime.

Only the two shipping control-row bodies are extracted. Owner types and
popover-owning children are memory-only boundary stubs; all actions are inert.
The real StudioAccessibility text style and StudioControlRow are compiled.
No visible windows, input injection, media, documents or permissions are used.
This is a layout proof, not native VoiceOver/focus/contrast qualification.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time
import uuid


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
    init(kind: String) { self.kind = kind }
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
    static func emit(_ fields: [String: Any]) {
        var fields = fields
        fields["uptimeSeconds"] = ProcessInfo.processInfo.systemUptime
        let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([10]))
    }
    static func line(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let notices = ControlRowNoticeObserver()
        NotificationCenter.default.addObserver(notices, selector: #selector(ControlRowNoticeObserver.changed(_:)),
            name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(notices, selector: #selector(ControlRowNoticeObserver.changed(_:)),
            name: NSApplication.didFinishLaunchingNotification, object: nil)
        defer { NotificationCenter.default.removeObserver(notices) }
        emit(["event": "host", "os": ProcessInfo.processInfo.operatingSystemVersionString,
              "applicationRunning": NSApp.isRunning, "activationPolicy": NSApp.activationPolicy().rawValue,
              "preferredStyle": NSScroller.preferredScrollerStyle.rawValue])
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { emit(["event": "assertionFailure", "message": message]); throw NSError(domain: "StudioControlRows", code: 1,
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
                    emit(["event": "caseBegin", "kind": kind, "textPoints": value, "requestedStyle": style.rawValue])
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
                    func observe(_ phase: String) {
                        let current = scrolls(hosting.view)
                        emit(["event": "layout", "phase": phase, "kind": kind, "textPoints": value,
                              "requestedStyle": style.rawValue, "actualStyle": scroll.scrollerStyle.rawValue,
                              "preferredStyle": NSScroller.preferredScrollerStyle.rawValue,
                              "applicationRunning": NSApp.isRunning,
                              "horizontalScrollerClass": scroll.horizontalScroller.map { String(describing: type(of: $0)) } ?? "nil",
                              "verticalScrollerClass": scroll.verticalScroller.map { String(describing: type(of: $0)) } ?? "nil",
                              "horizontalScrollerStyle": scroll.horizontalScroller?.scrollerStyle.rawValue ?? -1,
                              "verticalScrollerStyle": scroll.verticalScroller?.scrollerStyle.rawValue ?? -1,
                              "hasHorizontalScroller": scroll.hasHorizontalScroller,
                              "hasVerticalScroller": scroll.hasVerticalScroller, "rulersVisible": scroll.rulersVisible,
                              "horizontalRulerAccessory": scroll.horizontalRulerView?.accessoryView != nil,
                              "verticalRulerAccessory": scroll.verticalRulerView?.accessoryView != nil,
                              "scrollSubviewClasses": scroll.subviews.map { String(describing: type(of: $0)) },
                              "capturedScrollID": String(describing: ObjectIdentifier(scroll)),
                              "capturedDocumentID": String(describing: ObjectIdentifier(document)),
                              "capturedScrollStillInHierarchy": current.contains { $0 === scroll },
                              "capturedDocumentStillInstalled": scroll.documentView === document,
                              "currentScrolls": current.map { view in
                                  ["id": String(describing: ObjectIdentifier(view)),
                                   "class": String(describing: type(of: view)), "style": view.scrollerStyle.rawValue,
                                   "documentID": view.documentView.map { String(describing: ObjectIdentifier($0)) } ?? "nil",
                                   "frame": NSStringFromRect(view.frame), "visible": NSStringFromRect(view.documentVisibleRect)] as [String: Any]
                              },
                              "narrow": NSStringFromSize(narrow), "wide": NSStringFromSize(wide),
                              "scrollFrame": NSStringFromRect(scroll.frame), "hostBounds": NSStringFromRect(hosting.view.bounds),
                              "documentFrame": NSStringFromRect(document.frame), "visibleRect": NSStringFromRect(scroll.documentVisibleRect),
                              "windowVisible": window.isVisible, "windowKey": window.isKeyWindow])
                    }
                    observe("beforeStyleAssignment")
                    // Only this owned scroll view changes style. No system
                    // preferences are changed to force classic scrollers.
                    scroll.scrollerStyle = style
                    observe("immediatelyAfterStyleAssignment")
                    settle(window, hosting)
                    observe("afterStyleLayout")
                    // Realization/style changes can update intrinsic height.
                    // Use exactly that reported height, with no padded allowance.
                    let measured = hosting.sizeThatFits(in: CGSize(width: 320, height: 640))
                    observe("afterIntrinsicMeasurement")
                    emit(["event": "measurement", "kind": kind, "textPoints": value,
                          "requestedStyle": style.rawValue, "measured": NSStringFromSize(measured)])
                    window.setContentSize(measured)
                    hosting.view.frame = CGRect(origin: .zero, size: measured)
                    settle(window, hosting)
                    observe("beforeStyleAssertion")
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
                    observe("afterTrailingScroll")
                    try require(abs(scroll.documentVisibleRect.maxX - contentWidth) < 0.5, "Native scrolling must reach the row's trailing controls")
                    window.setContentSize(CGSize(width: 844, height: measured.height))
                    hosting.view.frame.size.width = 844
                    settle(window, hosting)
                    observe("afterWideLayout")
                    try require(abs(scroll.documentVisibleRect.width - 844) < 0.5 && document.frame.width >= 843.5,
                        "Wide row must fill viewport, preserving existing Spacer alignment")
                    line("PASS row=\(kind) textPoints=\(value) scroller=\(style == .legacy ? "legacy" : "overlay") minimumCanvasWidth=\(measured.width) reportedHeight=\(measured.height) contentHeight=\(document.frame.height) retainedContentWidth=\(contentWidth) nativeScrollReachedTrailingEdge=true wideViewport=\(scroll.documentVisibleRect.width)")
                }
            }
        }
        line("PASS: 40 owned offscreen row/style cases at configured 11...20-point text; source rows and styles, exact intrinsic height/native scrolling, no runtime/devices/global input/AX claim")
    }
}

@MainActor final class ControlRowNoticeObserver: NSObject {
    @objc func changed(_ notification: Notification) {
        // AppKit documents the preferred-style notification object as private;
        // retain only its public name and current public style value.
        ControlRowLayoutProof.emit(["event": "notification", "name": notification.name.rawValue,
                                   "preferredStyle": NSScroller.preferredScrollerStyle.rawValue,
                                   "applicationRunning": NSApp.isRunning])
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
    parser.add_argument("--artifact-dir", type=Path,
                        help="Owned durable output; defaults to a unique build directory.")
    args = parser.parse_args()
    apple = Path(__file__).resolve().parents[1]
    source = (args.main_window_source or apple / "StreamMac/MainWindowView.swift").read_text()
    rows = "\n".join(property_source(source, name) for name in
                     ("transportBar", "streamStatusBadge", "goLiveButton", "transitionControls"))
    # The status badge is a separate method rather than a computed property.
    start = source.index("    private func badge(")
    end = source.index("    /// One button per streaming", start)
    rows += "\n" + source[start:end]
    folder = args.artifact_dir or apple / "build/studio-control-rows-validation/artifacts" / ("invocation-" + str(uuid.uuid4()))
    folder.mkdir(parents=True, exist_ok=False)
    fixture = folder / "OwnedControlRows.swift"
    fixture.write_text(HEADER + rows + "\n}\n" + MAIN)
    executable = folder / "ControlRows"
    inputs = [apple / "StreamMac/StudioAccessibility.swift", apple / "StreamMac/StudioControlRow.swift",
              args.main_window_source or apple / "StreamMac/MainWindowView.swift", Path(__file__).resolve()]
    metadata = {"startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "scope": "Offscreen component layout only; no runtime, visible/key window, input, AX, media or settings changes.",
                "sourceSHA256": {}, "stages": []}
    for index, path in enumerate(inputs):
        data = path.read_bytes()
        metadata["sourceSHA256"][str(path)] = hashlib.sha256(data).hexdigest()
        (folder / (str(index) + "-" + path.name)).write_bytes(data)
    metadata["generatedSourceSHA256"] = hashlib.sha256(fixture.read_bytes()).hexdigest()

    def persist():
        events = []
        runtime_log = folder / "runtime.log"
        if runtime_log.exists():
            for line in runtime_log.read_text(errors="replace").splitlines():
                try:
                    value = json.loads(line)
                    if isinstance(value, dict) and "event" in value:
                        events.append(value)
                except json.JSONDecodeError:
                    pass
        failed = any(stage.get("timedOut") or stage.get("exitCode", 0) != 0 for stage in metadata["stages"])
        phase = {"failed": failed, "lastEvent": events[-1] if events else None,
                 "lastCase": next((event for event in reversed(events) if event["event"] == "caseBegin"), None),
                 "lastLayout": next((event for event in reversed(events) if event["event"] == "layout"), None),
                 "assertion": next((event for event in reversed(events) if event["event"] == "assertionFailure"), None)}
        (folder / "failed-phase.json").write_text(json.dumps(phase, indent=2) + "\n")
        metadata["artifacts"] = {path.name: {"bytes": path.stat().st_size,
                                "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                                 for path in folder.iterdir() if path.is_file() and path.name != "result.json"}
        (folder / "result.json").write_text(json.dumps(metadata, indent=2) + "\n")

    def run(stage, command, timeout):
        record = {"stage": stage, "command": command, "timeoutSeconds": timeout}
        metadata["stages"].append(record)
        persist()
        started = time.monotonic()
        try:
            with (folder / (stage + ".log")).open("wb", buffering=0) as output:
                result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
                record["exitCode"] = result.returncode
                result.check_returncode()
        except subprocess.TimeoutExpired:
            record["timedOut"] = True
            raise
        finally:
            record["seconds"] = time.monotonic() - started
            persist()
            # Native output is already durable. Echo cannot backpressure it.
            sys.stdout.buffer.write((folder / (stage + ".log")).read_bytes())
            sys.stdout.buffer.flush()

    print("Owned control-row artifacts: " + str(folder), flush=True)
    try:
        run("compile", ["xcrun", "swiftc", "-swift-version", "6",
                        "-strict-concurrency=complete", "-j2", "-parse-as-library",
                        str(apple / "StreamMac/StudioAccessibility.swift"),
                        str(apple / "StreamMac/StudioControlRow.swift"),
                        str(fixture), "-o", str(executable)], 60)
        run("runtime", [str(executable)], 90)
    finally:
        metadata["finishedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        metadata["sourceInputsUnchanged"] = all(hashlib.sha256(Path(path).read_bytes()).hexdigest() == value
                                                 for path, value in metadata["sourceSHA256"].items())
        persist()


if __name__ == "__main__":
    main()
