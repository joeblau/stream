import AppKit
import CoreMedia
import Foundation
import SwiftUI
import StreamCore

private struct StudioAXNode: Codable, Sendable {
    let role: String
    let label: String
    let value: String
    let x: Double, y: Double, width: Double, height: Double
    let focused: Bool
    let enabled: Bool
    let actions: [String]
    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

@MainActor enum WorkspaceAccessibilityReceipts {
    static var contrast: ColorSchemeContrast = .standard
    static var interfaceContrast = false
    static var textScale = 1.0
    static var reduceMotion = false
    static var dynamicType = DynamicTypeSize.large
}

/// Mounted inside the shipping root's interface modifier by the tool runner.
/// It observes the real inherited environment rather than recreating the policy.
struct WorkspaceAccessibilityProbe: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.studioReduceMotion) private var reduceMotion
    @Environment(\.studioIncreaseContrast) private var interfaceContrast
    @Environment(\.studioTextScale) private var textScale
    @Environment(\.dynamicTypeSize) private var dynamicType
    private func record() {
        WorkspaceAccessibilityReceipts.contrast = contrast
        WorkspaceAccessibilityReceipts.interfaceContrast = interfaceContrast
        WorkspaceAccessibilityReceipts.textScale = textScale
        WorkspaceAccessibilityReceipts.reduceMotion = reduceMotion
        WorkspaceAccessibilityReceipts.dynamicType = dynamicType
    }
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear(perform: record)
            .onChange(of: contrast) { record() }
            .onChange(of: interfaceContrast) { record() }
            .onChange(of: textScale) { record() }
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
        if CommandLine.arguments.contains("--accessibility-local") {
            let rows = try nativeNodes()
            if arguments.count >= 2 {
                guard let row = rows.first(where: { $0.1.label == arguments[1] }) else { throw NSError(domain: "StudioAccessibility", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing actual native accessibility control \(arguments[1])"]) }
                let element = row.0
                let performed: Bool
                switch arguments[0] {
                case "focus": element.setAccessibilityFocused?(true); performed = true
                case "increment": performed = element.accessibilityPerformIncrement?() ?? false
                case "press": performed = element.accessibilityPerformPress?() ?? false
                case "action":
                    let action = element.accessibilityCustomActions?()?.first { $0.name == arguments.last }
                    if let handler = action?.handler { performed = handler() }
                    else if let action, let target = action.target, let selector = action.selector { performed = NSApp.sendAction(selector, to: target, from: action) }
                    else { performed = false }
                default: performed = false
                }
                try require(performed, "Actual native accessibility action failed: \(arguments)")
                try await Task.sleep(for: .milliseconds(70))
                return []
            }
            return rows.map(\.1)
        }
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
    private static func nativeObjectValue(_ element: AnyObject?, _ selectorName: String) -> AnyObject? {
        let selector = NSSelectorFromString(selectorName)
        // AppKit may use NSProxy roots as well as NSObject subclasses.
        guard element?.responds?(to: selector) == true else { return nil }
        return element?.perform?(selector)?.takeUnretainedValue()
    }
    private static func nativeNodes() throws -> [(AnyObject, StudioAXNode)] {
        let title = ProcessInfo.processInfo.environment["STREAM_ACCESSIBILITY_WINDOW_TITLE"]
        guard let window = NSApp.windows.first(where: { title == nil || $0.title == title }) else { throw CocoaError(.fileNoSuchFile) }
        var queue: [AnyObject] = [window], rows: [(AnyObject, StudioAXNode)] = []
        var seen = Set<ObjectIdentifier>()
        while !queue.isEmpty && rows.count < 2_000 {
            let element = queue.removeFirst()
            guard seen.insert(ObjectIdentifier(element)).inserted else { continue }
            let title = element.accessibilityTitle?() ?? "", label = element.accessibilityLabel?() ?? ""
            let related = nativeObjectValue(nativeObjectValue(element, "accessibilityTitleUIElement"), "accessibilityValue") as? String ?? ""
            let rawValue = nativeObjectValue(element, "accessibilityValue")
            let value = rawValue as? String ?? (rawValue as? NSNumber)?.stringValue ?? (rawValue as? NSAttributedString)?.string ?? ""
            let rect = element.accessibilityFrame?() ?? .zero
            rows.append((element, .init(role: element.accessibilityRole?()?.rawValue ?? "", label: !title.isEmpty ? title : !label.isEmpty ? label : !related.isEmpty ? related : element.accessibilityPlaceholderValue?() ?? "",
                value: value, x: rect.minX, y: rect.minY, width: rect.width, height: rect.height,
                focused: element.isAccessibilityFocused?() ?? false, enabled: element.isAccessibilityEnabled?() ?? false, actions: element.accessibilityCustomActions?()?.map(\.name) ?? [])))
            // AppKit can return private reparenting proxies from navigation order.
            // Read the genuine Objective-C NSArray before Swift's SDK generic
            // bridge attempts to cast every proxy to NSAccessibilityElement.
            let ordered = nativeObjectValue(element, "accessibilityChildrenInNavigationOrder") as? NSArray
            let children = ordered ?? (nativeObjectValue(element, "accessibilityChildren") as? NSArray)
            // SwiftUI's reparenting proxies implement the public informal ObjC
            // accessibility selectors without declaring the Swift protocol.
            if let children { for child in children { queue.append(child as AnyObject) } }
        }
        try require(queue.isEmpty, "Actual native accessibility graph exceeded its bound")
        return rows
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
    private static func requireLiveResponder(_ window: NSWindow, _ context: String) throws {
        guard let responder = window.firstResponder as? NSView,
              responder.window === window, !responder.isHiddenOrHasHiddenAncestor else {
            throw NSError(domain: "StudioAccessibility", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(context): no surviving visible native keyboard target in the owned window"])
        }
    }
    private static func key(_ code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = [], window: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: code)!
        NSApp.sendEvent(event)
    }
    static func showScheduling(workspace: StudioWorkspace) async throws {
        let accounts = workspace.runtime.providerAccounts
        let plan = accounts.showScheduling
        let youtube = StreamDestination(name: "Show YouTube", isEnabled: false, providerBinding: .init(provider: .youtube, channelID: "fixture-owner"))
        let manual = StreamDestination(name: "Show Manual", isEnabled: false)
        let window = NSWindow(contentRect: NSRect(x: 90, y: 90, width: 580, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: ProviderShowSchedulingEditor(coordinator: plan, destinations: [youtube, manual]))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        let initial = try await snapshot("show-scheduling-editor")
        for label in ["Title (1–100 characters)", "Timezone", "Scheduled start", "Privacy", "Show YouTube · YouTube", "Show Manual · Manual / custom", "Schedule Selected Destinations"] {
            try require(initial.contains { $0.label == label }, "Missing scheduling field: \(label)")
        }
        try require(initial.contains { $0.label == "Schedule Selected Destinations" && !$0.enabled }, "Empty show must not submit")
        _ = try await client(["focus", "Title (1–100 characters)"])
        guard let editor = window.firstResponder as? NSTextView else { throw NSError(domain: "StudioAccessibility", code: 1, userInfo: [NSLocalizedDescriptionKey: "Show title did not receive the native field editor"]) }
        editor.selectAll(nil)
        editor.insertText("Owned UI show", replacementRange: editor.selectedRange())
        window.makeFirstResponder(nil)
        _ = try await client(["press", "Show YouTube · YouTube"])
        _ = try await client(["press", "Show Manual · Manual / custom"])
        try await Task.sleep(for: .milliseconds(100))
        let ready = try await snapshot("show-scheduling-selected")
        try require(ready.contains { $0.label == "Schedule Selected Destinations" && $0.enabled }, "Selected valid show did not enable submission")
        _ = try await client(["press", "Schedule Selected Destinations"])
        try await Task.sleep(for: .milliseconds(100))
        try require(plan.title == "Owned UI show" && plan.targets.map(\.state) == [.blocked, .manualRequired] && !plan.running, "Actual editor did not submit independent capability-gated outcomes")
        try require(accounts.pending.document.records.isEmpty, "Unapproved UI fixture created a provider resource")
        print("PASS: shipping show editor public AX title/timezone/date/privacy/destination fields, disabled empty submit, actual text/select/submit interactions and independent blocked/manual outcomes; no provider mutations")
    }
    static func run(workspace: StudioWorkspace, window: NSWindow) async throws {
        window.title = "Owned Studio Accessibility"
        setenv("STREAM_ACCESSIBILITY_WINDOW_TITLE", window.title, 1)
        try await Task.sleep(for: .milliseconds(100))
        print("ACCESSIBILITY PATH: \(CommandLine.arguments.contains("--accessibility-local") ? "direct actual public NSAccessibility selectors/actions on the owned mounted UI (not external IPC)" : "external public AX IPC")")
        let baseline = try await snapshot("baseline-1440x900")
        if CommandLine.arguments.contains("--accessibility-local"), !baseline.contains(where: { $0.label == "Scenes panel" }) {
            throw NSError(domain: "StudioAccessibility", code: 77, userInfo: [NSLocalizedDescriptionKey: "Mounted SwiftUI virtual semantic tree is not available through native public selectors in this session; native chrome alone is not semantic label/action qualification"])
        }
        for label in ["Scenes panel", "Preview and program panel", "Chat panel", "Inspector panel"] {
            try require(baseline.contains { $0.role == "AXGroup" && $0.label == label }, "Missing named \(label)")
        }
        let panels = baseline.filter { $0.role == "AXGroup" && ["Scenes panel", "Preview and program panel", "Chat panel", "Inspector panel"].contains($0.label) }.map(\.label)
        try require(panels == ["Scenes panel", "Preview and program panel", "Chat panel", "Inspector panel"], "Public AX panel traversal order changed: \(panels)")
        let colors = baseline.filter { $0.role == "AXButton" && $0.label.hasPrefix("Annotation color: ") }
        try require(Set(colors.map(\.label)) == Set(["Red", "Orange", "Yellow", "Green", "Blue", "White"].map { "Annotation color: " + $0 }),
            "Annotation palette must expose six distinct native color names")
        try require(colors.filter { $0.value == "Selected" }.map(\.label) == ["Annotation color: Red"], "Initial annotation color selection is not exposed")
        _ = try await client(["press", "Annotation color: Blue"])
        let selected = try await snapshot("annotation-blue")
        try require(selected.first { $0.label == "Annotation color: Blue" }?.value == "Selected"
            && workspace.runtime.dispatcher.annotations.colorHex == "#0A84FF", "Native color action did not select and announce blue")
        print("PASS: actual native accessibility exposes all four named panels and six named colors with actual selected values/actions")

        // Exercise the actual outline's named custom actions, including its
        // staging model and shared layer selection, rather than a mock catalog.
        workspace.runtime.dispatcher.execute(.addLayer(.shape(ShapeSourcePayload()), in: nil))
        try await Task.sleep(for: .milliseconds(120))
        guard let added = workspace.runtime.previewProgram.stagedScene?.layers.last else { throw CocoaError(.coderInvalidValue) }
        workspace.runtime.dispatcher.execute(.renameLayer(added.id, to: "Owned accessible shape", in: nil))
        try await Task.sleep(for: .milliseconds(120))
        guard let layer = workspace.runtime.previewProgram.stagedScene?.layers.first(where: { $0.id == added.id }) else { throw CocoaError(.coderInvalidValue) }
        let layerRows = try await snapshot("layer-actions-before")
        try require(layerRows.contains { $0.label == "Scene list" && ["AXList", "AXTable", "AXOutline"].contains($0.role) }
            && layerRows.contains { $0.label == "Layer outline" && ["AXList", "AXTable", "AXOutline"].contains($0.role) },
            "Shipping scene/layer tables did not expose their native named table roles")
        guard let layerRow = layerRows.first(where: { $0.label.hasPrefix(layer.name + ",") && $0.actions.contains("Hide Layer") }) else {
            throw NSError(domain: "StudioAccessibility", code: 1, userInfo: [NSLocalizedDescriptionKey: "Shipping outline did not expose named layer actions"])
        }
        _ = try await client(["action", layerRow.label, "Hide Layer"])
        try require(workspace.runtime.previewProgram.stagedScene?.layers.first(where: { $0.id == layer.id })?.isVisible == false,
            "Native layer Hide action did not edit staged visibility")
        let hiddenRows = try await snapshot("layer-actions-hidden")
        guard let hiddenRow = hiddenRows.first(where: { $0.label.hasPrefix(layer.name + ",") && $0.actions.contains("Show Layer") }) else { throw CocoaError(.coderInvalidValue) }
        _ = try await client(["action", hiddenRow.label, "Select Layer"])
        try require(workspace.runtime.sceneStore.selectedLayerIDs == [layer.id], "Native outline Select action did not update actual shared selection")
        _ = try await client(["action", hiddenRow.label, "Show Layer"])
        try require(workspace.runtime.previewProgram.stagedScene?.layers.first(where: { $0.id == layer.id })?.isVisible == true,
            "Native layer Show action did not restore staged visibility")
        _ = try await client(["focus", "Search scenes"])
        let tabResponder = window.firstResponder
        key(48, characters: "\t", window: window)
        try await Task.sleep(for: .milliseconds(100))
        try require(window.firstResponder !== tabResponder, "Actual Tab key did not traverse from scene search")
        try requireLiveResponder(window, "Tab traversal")
        _ = try await client(["focus", "Search messages and authors"])
        let compactOwner = (window.firstResponder as? NSTextView)?.delegate as? NSView
        try require(compactOwner?.window === window, "Chat search did not acquire its native control before Compact Layout")
        _ = try await client(["press", "Compact Layout"])
        try await Task.sleep(for: .milliseconds(100))
        try require(((window.firstResponder as? NSTextView)?.delegate as? NSView) !== compactOwner,
            "Compact Layout retained the removed chat search as native focus")
        try requireLiveResponder(window, "Compact Layout fallback")
        print("PASS: actual layer outline Hide/Show/Select custom actions edit staged model/shared selection; actual Tab traverses scene search and Compact Layout moves focus off removed chat search")
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

        try require(WorkspaceAccessibilityReceipts.interfaceContrast && abs(WorkspaceAccessibilityReceipts.textScale - 20.0 / 13) < 0.001, "App-owned contrast and explicit text scaling did not propagate")
        let regularScenesHeight = compact.first { $0.role == "AXStaticText" && $0.value == "Scenes" }?.height ?? 0
        let largeScenesHeight = large.first { $0.role == "AXStaticText" && $0.value == "Scenes" }?.height ?? 0
        try require(regularScenesHeight > 0 && largeScenesHeight > regularScenesHeight, "Explicit scene-header font ignored the text-size preference")
        _ = try await client(["focus", "Search scenes"])
        let settingsOwner = (window.firstResponder as? NSTextView)?.delegate as? NSView
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

        try require(((window.firstResponder as? NSTextView)?.delegate as? NSView) === settingsOwner && settingsOwner?.window === window,
            "Settings dismissal did not restore the original native scene-search control")
        if !CommandLine.arguments.contains("--accessibility-local") { NSApp.activate(ignoringOtherApps: true) }
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
        print("SCOPE: owned shipping MainWindow and process-local key events; external IPC or direct native protocol path is explicitly identified above. No VoiceOver/global setting/trust changes; no actual camera or publishing.")
        try await contrastPixels()
        try await mixerAndUpdates(workspace: workspace, mainWindow: window)
        print("PASS: app-owned interface contrast is real even when native high-contrast appearance aliases Dark Aqua; actual interface text scales and native settings focus restores")
    }
}

private struct StudioContrastPixelProbe: View {
    var body: some View {
        HStack(spacing: 12) {
            Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1).frame(width: 64, height: 64)
            Text("Interface contrast sample").foregroundStyle(.studioSecondary)
        }
        .frame(width: 300, height: 100)
        .studioPanelSurface()
        .background(Color(nsColor: .windowBackgroundColor))
        .modifier(StudioInterfaceModifier())
        .preferredColorScheme(.dark)
        .defaultAppStorage(WorkspaceFixtureDefaults.value)
    }
}

extension StudioAccessibilityHarness {
    private static func contrastPixels() async throws {
        let probe = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 300, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        probe.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: StudioContrastPixelProbe())
        probe.contentView = host; probe.orderFront(nil)
        defer { probe.close() }
        var whiteCounts: [Int] = []
        for enabled in [false, true] {
            WorkspaceFixtureDefaults.value.set(enabled, forKey: "studio.interface.increaseContrast")
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.coderInvalidValue) }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            func pixel(_ x: Double, _ y: Double) throws -> NSColor {
                guard let color = bitmap.colorAt(x: Int(x / 300 * Double(bitmap.pixelsWide)),
                    y: Int(y / 100 * Double(bitmap.pixelsHigh)))?.usingColorSpace(.sRGB) else { throw CocoaError(.coderInvalidValue) }
                return color
            }
            if let path = ProcessInfo.processInfo.environment["STREAM_ACCESSIBILITY_ARTIFACTS"],
               let data = bitmap.representation(using: .png, properties: [:]) {
                try data.write(to: URL(fileURLWithPath: path).appendingPathComponent("interface-contrast-\(enabled).png"))
            }
            // Real opaque media-color swatch must retain its channels. The
            // contrast implementation acts on interface surfaces, never pixels.
            let red = try pixel(45, 50)
            try require(red.alphaComponent > 0.99 && red.redComponent > 0.95 && red.greenComponent < 0.05 && red.blueComponent < 0.05,
                "Native bitmap red reference mismatched before a qualified contrast comparison")
            let background = try pixel(290, 8)
            if enabled {
                try require(background.alphaComponent > 0.99 && max(background.redComponent, background.greenComponent, background.blueComponent) < 0.03,
                    "Actual contrast panel did not render an opaque black surface")
            }
            var white = 0
            for y in 10..<(bitmap.pixelsHigh - 10) {
                for x in (bitmap.pixelsWide / 3)..<(bitmap.pixelsWide - 10) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.99,
                       min(color.redComponent, color.greenComponent, color.blueComponent) > 0.95 { white += 1 }
                }
            }
            whiteCounts.append(white)
            if let path = ProcessInfo.processInfo.environment["STREAM_ACCESSIBILITY_ARTIFACTS"],
               let data = bitmap.representation(using: .png, properties: [:]) {
                try data.write(to: URL(fileURLWithPath: path).appendingPathComponent("interface-contrast-\(enabled).png"))
            }
        }
        try require(whiteCounts[1] > whiteCounts[0] + 20, "Actual secondary text did not become high-contrast white: \(whiteCounts)")
        print("PASS: actual native-hosted production contrast styles render black surfaces and white secondary text (\(whiteCounts)), preserving red media pixels")
    }

    private static func mixerAndUpdates(workspace: StudioWorkspace, mainWindow: NSWindow) async throws {
        WorkspaceFixtureDefaults.value.set(13.0, forKey: "studio.interface.textSize")
        WorkspaceFixtureDefaults.value.set(true, forKey: "studio.showChatPanel")
        mainWindow.setContentSize(CGSize(width: 1440, height: 900))
        guard let engine = WorkspaceFixtureAudio.latest else { throw CocoaError(.coderInvalidValue) }
        await startSoftwareMeters(workspace: workspace, engine: engine)
        let tap = workspace.runtime.controller.addProgramAudioTap { _ in }
        let source = Task.detached {
            let clock = ContinuousClock(), origin = CMClockGetTime(CMClockGetHostTimeClock()).seconds + 0.02, start = ContinuousClock.now
            for index in 0..<900 {
                guard !Task.isCancelled else { return }
                engine.enqueue(.microphone(deviceUID: nil), try ProgramRecordingFixtures.audio(at: origin + Double(index) / 100, timestampBase: 0, constantTone: true))
                try await clock.sleep(until: start.advanced(by: .milliseconds(index * 10 + 10)))
            }
        }
        defer {
            source.cancel(); workspace.runtime.controller.removeAudioTap(tap)
            Task { await engine.stop() }
        }
        let mixerWindow = NSWindow(contentRect: CGRect(x: 120, y: 120, width: 520, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        mixerWindow.isReleasedWhenClosed = false; mixerWindow.title = "Owned Mixer Accessibility"
        mixerWindow.contentView = NSHostingView(rootView: MixerPanelView()
            .environmentObject(workspace.runtime.controller).environmentObject(workspace.runtime.dispatcher)
            .environmentObject(workspace.runtime.sceneStore).environmentObject(workspace.runtime.previewProgram)
            .modifier(StudioInterfaceModifier()).preferredColorScheme(.dark)
            .defaultAppStorage(WorkspaceFixtureDefaults.value))
        mixerWindow.makeKeyAndOrderFront(nil)
        setenv("STREAM_ACCESSIBILITY_WINDOW_TITLE", mixerWindow.title, 1)
        defer { mixerWindow.close(); setenv("STREAM_ACCESSIBILITY_WINDOW_TITLE", mainWindow.title, 1) }
        try await Task.sleep(for: .milliseconds(500))
        let levels = await workspace.runtime.controller.mixerLevels()
        try require((levels.channels[.microphone(deviceUID: nil)]?.peak ?? 0) > 0.5, "Actual PCM did not drive shipping mixer meters")
        let mixer = try await snapshot("mixer-real-pcm")
        for label in ["Microphone volume", "Program volume", "Monitor volume", "Mute Microphone", "Solo Microphone", "Microphone aux send"] {
            try require(mixer.contains { $0.label == label && $0.enabled }, "Missing named live mixer control \(label)")
        }
        let originalVolume = workspace.runtime.dispatcher.state.micVolume
        _ = try await client(["increment", "Microphone volume"])
        try await Task.sleep(for: .milliseconds(100))
        try require(workspace.runtime.dispatcher.state.micVolume > originalVolume, "Actual AX increment did not adjust the production microphone fader")
        _ = try await client(["press", "Mute Microphone"])
        let mic = AudioChannelID.microphone(deviceUID: nil)
        try require(workspace.runtime.dispatcher.state.mixer.channelMutes[mic.label] == true, "Actual AX mute action did not reach dispatcher")
        _ = try await client(["press", "Unmute Microphone"])
        _ = try await client(["focus", "Microphone volume"])
        let before = try await snapshot("mixer-focus-before-updates")
        try require(before.contains { $0.label == "Microphone volume" && $0.focused }, "Mixer fader did not acquire actual public AX focus")
        try await Task.sleep(for: .milliseconds(600))
        let after = try await snapshot("mixer-focus-after-updates")
        try require(after.contains { $0.label == "Microphone volume" && $0.focused }, "Real live-meter polling stole fader focus")
        try require(!after.contains { $0.role == "AXLevelIndicator" }, "Rapid live meters should be hidden from accessibility traversal")
        mixerWindow.close(); setenv("STREAM_ACCESSIBILITY_WINDOW_TITLE", mainWindow.title, 1)
        mainWindow.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        _ = try await client(["focus", "Search messages and authors"])
        let owner = (mainWindow.firstResponder as? NSTextView)?.delegate as? NSView
        try require(owner?.window === mainWindow, "Chat search did not acquire its actual native control")
        for index in 0..<24 {
            workspace.runtime.chat.receive(.message(.init(id: "ax-message-\(index)", connectionID: "owned-fixture", platform: "YouTube", author: "Owned guest", roles: [],
                text: "Owned live update \(index)", timestamp: Date(), timestampIsReceiptTime: true, kind: "Text", avatarURL: nil)))
            try await Task.sleep(for: .milliseconds(20))
        }
        try require(((mainWindow.firstResponder as? NSTextView)?.delegate as? NSView) === owner,
            "Incoming actual chat queue updates replaced native search focus")
        _ = try await snapshot("chat-focus-after-incoming-messages")
        _ = try await client(["focus", "Search scenes"])
        let survivingOwner = (mainWindow.firstResponder as? NSTextView)?.delegate as? NSView
        _ = try await client(["press", "Inspector"])
        try await Task.sleep(for: .milliseconds(150))
        try require(((mainWindow.firstResponder as? NSTextView)?.delegate as? NSView) === survivingOwner && survivingOwner?.window === mainWindow,
            "An unrelated panel toggle replaced the surviving scene-search focus")
        _ = try await client(["focus", "Search messages and authors"])
        let removedOwner = (mainWindow.firstResponder as? NSTextView)?.delegate as? NSView
        _ = try await client(["press", "Chat"])
        try await Task.sleep(for: .milliseconds(150))
        try require(((mainWindow.firstResponder as? NSTextView)?.delegate as? NSView) !== removedOwner,
            "Closing Chat retained focus on a removed search control")
        try requireLiveResponder(mainWindow, "Closed Chat fallback")
        _ = try await client(["focus", "Search scenes"])
        let pickerOwner = (mainWindow.firstResponder as? NSTextView)?.delegate as? NSView
        var cancelled = false
        let timer = Timer(timeInterval: 0.2, repeats: true) { timer in
            let didCancel = MainActor.assumeIsolated {
                if let panel = NSApp.modalWindow as? NSOpenPanel {
                    cancelled = true; panel.cancel(nil); return true
                }
                return false
            }
            if didCancel { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        workspace.choosePackage()
        timer.invalidate()
        try await Task.sleep(for: .milliseconds(150))
        try require(cancelled && workspace.importPreview == nil, "Actual native package chooser was not cancelled independently")
        try require(((mainWindow.firstResponder as? NSTextView)?.delegate as? NSView) === pickerOwner,
            "Native package chooser cancellation lost the original field editor owner")
        print("PASS: actual public AX mixer fader increment/mute actions, real PCM meter polling focus, incoming chat updates focus, native package chooser cancel/restore; no capture permissions or provider writes")
    }
}

extension StudioAccessibilityHarness {
    /// Tests real AppKit views/events on the shipping mounted studio even if
    /// the locked session cannot materialize SwiftUI's virtual accessibility
    /// elements. This never substitutes a hand-built accessibility tree.
    private static func nativeViews(_ window: NSWindow) -> [NSView] {
        guard let content = window.contentView else { return [] }
        var queue = [content], result: [NSView] = []
        while !queue.isEmpty && result.count < 4_000 {
            let view = queue.removeFirst(); result.append(view); queue += view.subviews
        }
        return result
    }
    private static func field(_ name: String, in window: NSWindow) throws -> NSTextField {
        guard let field = nativeViews(window).compactMap({ $0 as? NSTextField })
            .first(where: { $0.placeholderString == name || $0.accessibilityPlaceholderValue() == name }) else {
            throw NSError(domain: "StudioAccessibility", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mounted native text field is missing: \(name)"])
        }
        return field
    }
    private static func focusField(_ name: String, in window: NSWindow) throws -> NSView {
        let control = try field(name, in: window)
        try require(window.makeFirstResponder(control), "Actual native field refused keyboard focus: \(name)")
        try require(((window.firstResponder as? NSTextView)?.delegate as? NSView) === control,
            "Actual field editor does not belong to \(name)")
        return control
    }
    static func runNativeControls(workspace: StudioWorkspace, window: NSWindow) async throws {
        print("SCOPE: actual mounted production MainWindow AppKit descendants, public native control actions, process-local NSEvents and rendered production styles. SwiftUI virtual semantic label/action/order walk remains UNQUALIFIED on this locked host.")
        window.title = "Owned Studio Native Controls"
        if let path = ProcessInfo.processInfo.environment["STREAM_ACCESSIBILITY_ARTIFACTS"] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let original = try focusField("Search scenes", in: window)
        let regularSearchPoints = (original as? NSTextField)?.font?.pointSize ?? 0
        let editor = window.firstResponder
        key(35, characters: "P", modifiers: [.command, .shift], window: window)
        try await Task.sleep(for: .milliseconds(200))
        guard let sheet = window.attachedSheet else { throw NSError(domain: "StudioAccessibility", code: 1, userInfo: [NSLocalizedDescriptionKey: "Actual process-local palette shortcut did not open its production sheet"]) }
        _ = try field("Search studio actions", in: sheet)
        key(53, characters: "\u{1b}", window: sheet)
        try await Task.sleep(for: .milliseconds(200))
        try require(window.attachedSheet == nil && window.firstResponder === editor
            && ((window.firstResponder as? NSTextView)?.delegate as? NSView) === original,
            "Actual palette Escape failed to restore its native field editor/control")
        key(48, characters: "\t", window: window)
        try await Task.sleep(for: .milliseconds(100))
        try require(window.firstResponder !== editor, "Actual Tab did not leave scene search")
        try requireLiveResponder(window, "Native Tab")
        _ = try focusField("Search scenes", in: window)
        workspace.runtime.dispatcher.execute(.openSettings(.application))
        try await Task.sleep(for: .milliseconds(180))
        workspace.runtime.dispatcher.execute(.closeSettings)
        try await Task.sleep(for: .milliseconds(180))
        try require(((window.firstResponder as? NSTextView)?.delegate as? NSView) === original,
            "Settings did not restore the exact surviving native search control")
        let nativeSheet = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        nativeSheet.isReleasedWhenClosed = false
        let sheetField = NSTextField(string: "Owned native sheet")
        sheetField.frame = CGRect(x: 20, y: 30, width: 260, height: 24)
        nativeSheet.contentView?.addSubview(sheetField)
        window.beginSheet(nativeSheet, completionHandler: { _ in })
        try require(nativeSheet.makeFirstResponder(sheetField), "Actual attached native sheet field refused focus")
        window.endSheet(nativeSheet); nativeSheet.orderOut(nil)
        try await Task.sleep(for: .milliseconds(180))
        try require(((window.firstResponder as? NSTextView)?.delegate as? NSView) === original,
            "Production native-sheet notification attachment did not restore the original native control")
        nativeSheet.close()
        print("PASS: actual mounted scene-search field → process-local Shift-Command-P → production command sheet → Escape preserves field editor/owner; actual Tab reaches a live native target; native settings dismissal and attached AppKit sheet notifications restore search")

        // Check toolbar panel actions through their real native NSButtons,
        // independently of the unavailable SwiftUI virtual AX bridge.
        func toolbarButton(_ title: String) -> NSButton? {
            // Toolbar view descendants need not live inside contentView.
            var roots = window.contentView?.superview.map { [$0] } ?? []
            var found: NSButton?
            while !roots.isEmpty {
                let view = roots.removeFirst()
                if let button = view as? NSButton, button.title == title || button.toolTip == title || button.accessibilityTitle() == title || button.accessibilityLabel() == title { found = button; break }
                roots += view.subviews
            }
            return found
        }
        _ = try focusField("Search messages and authors", in: window)
        let chatOwner = (window.firstResponder as? NSTextView)?.delegate as? NSView
        if let compact = toolbarButton("Compact Layout") {
            compact.performClick(nil)
            try await Task.sleep(for: .milliseconds(180))
            try require(!WorkspaceFixtureDefaults.value.bool(forKey: "studio.showChatPanel")
                && !WorkspaceFixtureDefaults.value.bool(forKey: "studio.showInspectorPanel"), "Actual native Compact Layout button failed to hide panels")
            try require(((window.firstResponder as? NSTextView)?.delegate as? NSView) !== chatOwner, "Compact layout retained removed chat focus")
            try requireLiveResponder(window, "Actual Compact Layout")
            print("PASS: actual native Compact Layout action hides panels and restores live native focus")
        } else {
            print("UNQUALIFIED: Compact Layout is a SwiftUI virtual button without a native NSButton descendant on this host. Rendering checks below set isolated fixture layout preferences; they do not qualify its action/focus fallback.")
            WorkspaceFixtureDefaults.value.set(false, forKey: "studio.showChatPanel")
            WorkspaceFixtureDefaults.value.set(false, forKey: "studio.showInspectorPanel")
        }
        window.setContentSize(CGSize(width: 1024, height: 640))
        WorkspaceFixtureDefaults.value.set(20.0, forKey: "studio.interface.textSize")
        WorkspaceFixtureDefaults.value.set(true, forKey: "studio.interface.increaseContrast")
        WorkspaceFixtureDefaults.value.set(true, forKey: "studio.interface.reduceMotion")
        try await Task.sleep(for: .milliseconds(200))
        try require(WorkspaceAccessibilityReceipts.interfaceContrast && WorkspaceAccessibilityReceipts.reduceMotion
            && abs(WorkspaceAccessibilityReceipts.textScale - 20.0 / 13) < 0.001, "Actual production root did not receive interface preferences")
        let largeSearch = try field("Search scenes", in: window)
        try require(regularSearchPoints > 0 && (largeSearch.font?.pointSize ?? 0) > regularSearchPoints * 1.4,
            "Actual native search callout did not scale with13→20pt preference: \(regularSearchPoints) → \(largeSearch.font?.pointSize ?? 0)")
        print("PASS: actual 1024×640 root receives20pt/contrast/reduced-motion and its native search font is \(largeSearch.font?.pointSize ?? 0)pt")
        do { try await contrastPixels() }
        catch { print("UNQUALIFIED: actual production contrast capture: \(error.localizedDescription). No contrast pixel qualification is claimed.") }
        do { try await nativeTypography() }
        catch { print("UNQUALIFIED: isolated caption geometry: \(error.localizedDescription). The mounted production search-font measurement above remains separate.") }
        try await nativeMixerAndChat(workspace: workspace, mainWindow: window)
        print("PASS: scoped native checks listed above completed; rendering qualifications are reported separately. UNQUALIFIED: full SwiftUI virtual accessibility labels/actions/order and external AX IPC; no permissions, unlock, global input or VoiceOver changes.")
    }
    private static func nativeTypography() async throws {
        let host = NSHostingView(rootView: Text("Owned relative caption").studioTextStyle(.caption)
            .modifier(StudioInterfaceModifier()).defaultAppStorage(WorkspaceFixtureDefaults.value))
        var sizes: [CGSize] = []
        for value in [13.0, 20.0] {
            WorkspaceFixtureDefaults.value.set(value, forKey: "studio.interface.textSize")
            try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
            sizes.append(host.fittingSize)
        }
        try require(sizes[0].height > 0 && sizes[1].height > sizes[0].height && sizes[1].width > sizes[0].width,
            "Actual production relative caption geometry failed to grow: \(sizes)")
        print("PASS: actual production caption rendering grows \(sizes[0]) → \(sizes[1]) with13→20pt preference")
    }
    private static func startSoftwareMeters(workspace: StudioWorkspace, engine: AudioMixEngine) async {
        // This is a keyboard/meter fixture, not Audio Unit or DSP qualification.
        // All state is confined to the tool's own runtime and temporary store.
        var settings = workspace.runtime.settings.activeSettings
        settings.voicePolishEnabled = false
        settings.channelFX = [:]
        settings.monitoringEnabled = false
        workspace.runtime.controller.applySavedSettings(settings)
        await engine.addChannel(.microphone(deviceUID: nil), insert: nil)
        await engine.run()
        print("SCOPE: owned meter runtime explicitly disables legacy Voice Polish, hosted Audio Units and monitoring; real software mixer/rings/PCM/meters retained")
    }
    private static func nativeMixerAndChat(workspace: StudioWorkspace, mainWindow: NSWindow) async throws {
        WorkspaceFixtureDefaults.value.set(13.0, forKey: "studio.interface.textSize")
        WorkspaceFixtureDefaults.value.set(true, forKey: "studio.showChatPanel")
        mainWindow.setContentSize(CGSize(width: 1440, height: 900))
        guard let engine = WorkspaceFixtureAudio.latest else { throw CocoaError(.coderInvalidValue) }
        await startSoftwareMeters(workspace: workspace, engine: engine)
        let tap = workspace.runtime.controller.addProgramAudioTap { _ in }
        let source = Task.detached {
            let clock = ContinuousClock(), origin = CMClockGetTime(CMClockGetHostTimeClock()).seconds + 0.02, start = ContinuousClock.now
            for index in 0..<500 {
                guard !Task.isCancelled else { return }
                engine.enqueue(.microphone(deviceUID: nil), try ProgramRecordingFixtures.audio(at: origin + Double(index) / 100, timestampBase: 0, constantTone: true))
                try await clock.sleep(until: start.advanced(by: .milliseconds(index * 10 + 10)))
            }
        }
        defer { source.cancel(); workspace.runtime.controller.removeAudioTap(tap); Task { await engine.stop() } }
        let mixer = NSWindow(contentRect: CGRect(x: 120, y: 120, width: 520, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        mixer.isReleasedWhenClosed = false; defer { mixer.close() }
        mixer.contentView = NSHostingView(rootView: MixerPanelView()
            .environmentObject(workspace.runtime.controller).environmentObject(workspace.runtime.dispatcher)
            .environmentObject(workspace.runtime.sceneStore).environmentObject(workspace.runtime.previewProgram)
            .modifier(StudioInterfaceModifier()).preferredColorScheme(.dark).defaultAppStorage(WorkspaceFixtureDefaults.value))
        mixer.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(500))
        let actualLevels = await workspace.runtime.controller.mixerLevels()
        try require((actualLevels.channels[.microphone(deviceUID: nil)]?.peak ?? 0) > 0.5, "Actual bounded PCM did not drive real mixer meters")
        if let slider = nativeViews(mixer).compactMap({ $0 as? NSSlider }).first {
            let old = workspace.runtime.dispatcher.state.micVolume
            try require(slider.accessibilityPerformIncrement(), "Actual native slider AX increment refused")
            try await Task.sleep(for: .milliseconds(100))
            try require(workspace.runtime.dispatcher.state.micVolume > old, "Actual native slider action did not update the production fader")
            try require(mixer.makeFirstResponder(slider), "Native mixer fader refused focus")
            try await Task.sleep(for: .milliseconds(600))
            try require(mixer.firstResponder === slider && slider.window === mixer, "Actual20Hz real-meter polling replaced native fader focus")
            print("PASS: actual native mixer slider callback updates production fader and real-meter polling preserves fader focus")
        } else {
            print("UNQUALIFIED: production fader is a SwiftUI virtual slider without a native NSSlider descendant; its accessibility action and own-focus checks need the virtual semantic tree.")
            mainWindow.makeKeyAndOrderFront(nil)
            let reading = try focusField("Search scenes", in: mainWindow)
            try await Task.sleep(for: .milliseconds(600))
            try require(((mainWindow.firstResponder as? NSTextView)?.delegate as? NSView) === reading,
                "Real PCM and production mixer polling stole the actual scene-search keyboard owner")
            print("PASS: real bounded PCM peak \(actualLevels.channels[.microphone(deviceUID: nil)]?.peak ?? 0) drives production mixer polling while native scene-search focus remains stable; this does not qualify virtual fader focus")
        }
        mixer.close(); mainWindow.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(120))
        let chat = try focusField("Search messages and authors", in: mainWindow)
        for index in 0..<24 {
            workspace.runtime.chat.receive(.message(.init(id: "native-focus-\(index)", connectionID: "owned-fixture", platform: "YouTube", author: "Owned guest", roles: [], text: "Owned live update \(index)", timestamp: Date(), timestampIsReceiptTime: true, kind: "Text", avatarURL: nil)))
            try await Task.sleep(for: .milliseconds(20))
        }
        try require(workspace.runtime.chat.queue.messages.filter { $0.id.hasPrefix("native-focus-") }.count == 24,
            "Actual chat queue did not accept all24 incoming update fixtures")
        try require(((mainWindow.firstResponder as? NSTextView)?.delegate as? NSView) === chat && chat.window === mainWindow, "Incoming actual chat updates replaced native search focus")
        print("PASS:24actual accepted incoming chat queue updates retain native chat-search field editor owner")
    }
}
