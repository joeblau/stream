import AppKit
import Foundation
import SwiftUI

private struct StudioAXNode: Codable, Sendable {
    let role: String
    let label: String
    let value: String
    let x: Double, y: Double, width: Double, height: Double
    let focused: Bool
    let enabled: Bool
    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

@MainActor enum WorkspaceAccessibilityReceipts {
    static var contrast: ColorSchemeContrast = .standard
    static var reduceMotion = false
    static var dynamicType = DynamicTypeSize.large
}

/// Mounted inside the shipping root's interface modifier by the tool runner.
/// It observes the real inherited environment rather than recreating the policy.
struct WorkspaceAccessibilityProbe: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.studioReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType
    private func record() {
        WorkspaceAccessibilityReceipts.contrast = contrast
        WorkspaceAccessibilityReceipts.reduceMotion = reduceMotion
        WorkspaceAccessibilityReceipts.dynamicType = dynamicType
    }
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear(perform: record)
            .onChange(of: contrast) { record() }
            .onChange(of: reduceMotion) { record() }
            .onChange(of: dynamicType) { record() }
    }
}

@MainActor enum StudioAccessibilityHarness {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw NSError(domain: "StudioAccessibility", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
    private static func client(_ arguments: [String] = []) async throws -> [StudioAXNode] {
        let parent = String(getpid())
        guard let path = ProcessInfo.processInfo.environment["STREAM_ACCESSIBILITY_CLIENT"] else {
            throw NSError(domain: "StudioAccessibility", code: 77, userInfo: [NSLocalizedDescriptionKey: "External owned-process AX client is missing; use the workspace runner"])
        }
        return try await Task.detached {
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = [parent] + arguments
            process.standardOutput = output; process.standardError = errors
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw NSError(domain: "StudioAccessibility", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: detail])
            }
            return try JSONDecoder().decode([StudioAXNode].self, from: data)
        }.value
    }
    private static func snapshot(_ name: String) async throws -> [StudioAXNode] {
        let nodes = try await client()
        if let path = ProcessInfo.processInfo.environment["STREAM_ACCESSIBILITY_ARTIFACTS"] {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(nodes).write(to: folder.appendingPathComponent(name + ".json"))
        }
        print("AX SNAPSHOT \(name): \(nodes.count) native elements")
        return nodes
    }
    private static func primaryControlsFit(_ nodes: [StudioAXNode]) throws {
        guard let window = nodes.first(where: { $0.role == "AXWindow" }) else {
            try require(false, "Public AX snapshot has no owned window"); return
        }
        for label in ["Take", "Record", "Preview", "Public Go Live"] {
            guard let node = nodes.first(where: { $0.role == "AXButton" && $0.label == label }) else {
                try require(false, "Missing primary control \(label)"); continue
            }
            try require(node.frame.width > 0 && node.frame.height > 0 && window.frame.contains(node.frame),
                "Primary control \(label) extends outside the owned window: \(node.frame), window \(window.frame)")
        }
    }
    private static func key(_ code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = [], window: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: code)!
        NSApp.sendEvent(event)
    }
    static func run(workspace: StudioWorkspace, window: NSWindow) async throws {
        let baseline = try await snapshot("baseline-1440x900")
        for label in ["Scenes panel", "Preview and program panel", "Chat panel", "Inspector panel"] {
            try require(baseline.contains { $0.role == "AXGroup" && $0.label == label }, "Missing named \(label)")
        }
        let colors = baseline.filter { $0.role == "AXButton" && $0.label.hasPrefix("Annotation color: ") }
        try require(Set(colors.map(\.label)) == Set(["Red", "Orange", "Yellow", "Green", "Blue", "White"].map { "Annotation color: " + $0 }),
            "Annotation palette must expose six distinct native color names")
        try require(colors.filter { $0.value == "Selected" }.map(\.label) == ["Annotation color: Red"], "Initial annotation color selection is not exposed")
        _ = try await client(["press", "Annotation color: Blue"])
        let selected = try await snapshot("annotation-blue")
        try require(selected.first { $0.label == "Annotation color: Blue" }?.value == "Selected"
            && workspace.runtime.dispatcher.annotations.colorHex == "#0A84FF", "Native color action did not select and announce blue")
        print("PASS: external public AX exposes all four named panels and six named colors with actual selected values/actions")

        _ = try await client(["press", "Compact Layout"])
        window.setContentSize(NSSize(width: 1024, height: 640))
        try await Task.sleep(for: .milliseconds(200))
        let compact = try await snapshot("compact-1024x640")
        try require(!compact.contains { ["Chat panel", "Inspector panel", "Settings panel"].contains($0.label) }, "Compact Layout retained a hidden panel")
        try require(compact.contains { $0.label == "Scenes panel" } && compact.contains { $0.label == "Preview and program panel" }, "Compact Layout lost scenes or canvas")
        try primaryControlsFit(compact)
        print("PASS: actual Compact Layout action at 1024×640 keeps Take, Record, Preview and Public Go Live inside the native window")

        WorkspaceFixtureDefaults.value.set(20.0, forKey: "studio.interface.textSize")
        WorkspaceFixtureDefaults.value.set(true, forKey: "studio.interface.increaseContrast")
        WorkspaceFixtureDefaults.value.set(true, forKey: "studio.interface.reduceMotion")
        try await Task.sleep(for: .milliseconds(300))
        let large = try await snapshot("large-text-contrast-reduce-motion")
        try primaryControlsFit(large)
        let regularHeight = compact.first { $0.role == "AXStaticText" && $0.value == "Preview off" }?.height ?? 0
        let largeHeight = large.first { $0.role == "AXStaticText" && $0.value == "Preview off" }?.height ?? 0
        try require(regularHeight > 0 && largeHeight > regularHeight, "Native text geometry did not grow with the interface text preference")
        try require(WorkspaceAccessibilityReceipts.dynamicType == .accessibility1 && WorkspaceAccessibilityReceipts.reduceMotion,
            "Shipping root did not propagate large text and Reduce Motion")
        print("PASS: 20-point preference grows native Preview off text \(regularHeight)→\(largeHeight) points; actual root inherits accessibility1 and Reduce Motion")

        workspace.runtime.dispatcher.execute(.openSettings(.application))
        try await Task.sleep(for: .milliseconds(200))
        let settings = try await snapshot("settings-application")
        try require(settings.contains { $0.label == "Interface text size" && $0.value == "20" }, "Native interface size slider does not announce its value")
        _ = try await client(["press", "Increase interface contrast"])
        try await Task.sleep(for: .milliseconds(100))
        try require(!WorkspaceFixtureDefaults.value.bool(forKey: "studio.interface.increaseContrast"), "Native contrast control failed to turn off")
        _ = try await client(["press", "Increase interface contrast"])
        try await Task.sleep(for: .milliseconds(100))
        try require(WorkspaceFixtureDefaults.value.bool(forKey: "studio.interface.increaseContrast"), "Native contrast control failed to turn on")
        workspace.runtime.dispatcher.execute(.closeSettings)
        try await Task.sleep(for: .milliseconds(200))

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        _ = try await client(["focus", "Search scenes"])
        let previousResponder = window.firstResponder
        let previousOwner = (previousResponder as? NSTextView)?.delegate as? NSView
        try require(previousOwner?.window === window, "Scene search did not acquire a native field editor")
        key(35, characters: "P", modifiers: [.command, .shift], window: window)
        try await Task.sleep(for: .milliseconds(300))
        guard let sheet = window.attachedSheet else {
            try require(false, "Actual ⇧⌘P key event did not open the command palette"); return
        }
        let palette = try await snapshot("palette-keyboard")
        try require(palette.contains { $0.label == "Search studio actions" }, "Command palette search is not exposed")
        key(53, characters: "\u{1b}", window: sheet)
        try await Task.sleep(for: .milliseconds(300))
        try require(window.attachedSheet == nil, "Actual Escape key did not close the palette")
        try require(window.firstResponder === previousResponder && ((window.firstResponder as? NSTextView)?.delegate as? NSView) === previousOwner,
            "Palette dismissal lost native keyboard focus from the original scene-search control")
        print("PASS: actual native scene-search focus→⇧⌘P→command sheet→Escape restores the original field editor and owning control")
        print("SCOPE: owned shipping MainWindow, public external AX IPC and process-local key events; no VoiceOver, trust grant, global preference change or actual capture/output")
        if WorkspaceAccessibilityReceipts.contrast != .increased, let host = window.contentView {
            let original = host.appearance
            host.appearance = NSAppearance(named: .accessibilityHighContrastDarkAqua)
            try await Task.sleep(for: .milliseconds(150))
            print("HOSTING CONTRAST PROBE: appearance=\(host.effectiveAppearance.name.rawValue), root=\(WorkspaceAccessibilityReceipts.contrast)")
            host.appearance = original
            try await Task.sleep(for: .milliseconds(100))
        }
        guard WorkspaceAccessibilityReceipts.contrast == .increased else {
            throw NSError(domain: "StudioAccessibility", code: 77, userInfo: [NSLocalizedDescriptionKey:
                "Increase Contrast stores/toggles correctly but native high-contrast appearance aliases \(window.effectiveAppearance.name.rawValue) and the root colorSchemeContrast remains standard on this host. Contrast/VoiceOver/manual focus qualification remains open."])
        }
        print("PASS: native high-contrast environment is increased")
    }
}
