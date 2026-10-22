import AppKit
import ApplicationServices
import SwiftUI

@MainActor private final class SelectionReceipt: ObservableObject {
    @Published var selected = 1
    @Published var activations: [Int] = []
    @Published var baselineActivations = 0
    func select(_ id: Int) { selected = id; activations.append(id) }
}
private struct OwnedSemanticControls: View {
    @ObservedObject var receipt: SelectionReceipt
    var body: some View {
        VStack {
            OwnedSceneCards(receipt: receipt)
            Button("Owned SwiftUI baseline") { receipt.baselineActivations += 1 }
                .accessibilityLabel("Owned SwiftUI baseline")
        }
    }
}
private struct OwnedSceneCards: View {
    @ObservedObject var receipt: SelectionReceipt
    @FocusState private var focused: Int?
    var body: some View {
        HStack {
            ForEach(1...2, id: \.self) { id in
                SceneSelectionButton(name: "Owned scene \(id)", isSelected: receipt.selected == id,
                    status: id == 1 ? "Preview, Unpublished changes" : "Program, Locked",
                    action: { receipt.select(id) }) {
                        VStack { Rectangle().fill(.gray).frame(width: 100, height: 56); Text("Owned scene \(id)") }
                            .padding(5).contentShape(Rectangle())
                    }
                    .focused($focused, equals: id)
            }
        }.padding().onAppear { focused = 1 }
    }
}
@MainActor private final class NativeControlReceipt: NSObject {
    var count = 0
    @objc func activate(_ sender: NSButton) { count += 1 }
}
private struct OwnedCAXNode: @unchecked Sendable {
    let element: AXUIElement
    let row: [String: String]
}
private struct OwnedCAXSnapshot: Sendable {
    let nodes: [OwnedCAXNode]
    let status: String
    let complete: Bool
}
private struct OwnedCAXClientReport: Codable, Sendable {
    let rows: [[String: String]]
    let status: String
    let complete: Bool
    let clientTrusted: Bool
    let presses: [String: Int32]
}
private enum OwnedCAX {
    /// Only this tool's own application/window tree. The caller awaits from
    /// MainActor so the event loop remains free to service public AX requests.
    static func snapshot(targetPID: pid_t = getpid(), expectedSize: CGSize, appKitTitle: String) -> OwnedCAXSnapshot {
        guard targetPID == getpid() || targetPID == getppid() else {
            return .init(nodes: [], status: "Refused non-owned PID", complete: false)
        }
        let app = AXUIElementCreateApplication(targetPID)
        AXUIElementSetMessagingTimeout(app, 1)
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var errors: [String] = []
        func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            var result: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, key as CFString, &result)
            if status != .success && errors.count < 16 { errors.append("\(key)=\(status.rawValue)") }
            return status == .success ? result : nil
        }
        guard let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] else {
            return .init(nodes: [], status: "Own AXWindows unavailable; \(errors)", complete: false)
        }
        var candidateFacts: [[String: String]] = []
        var candidates: [(AXUIElement, String)] = []
        for candidate in windows.prefix(16) {
            AXUIElementSetMessagingTimeout(candidate, 1)
            let rawTitle = value(candidate, kAXTitleAttribute)
            let title = rawTitle as? String ?? ""
            let role = value(candidate, kAXRoleAttribute) as? String ?? ""
            var owner: pid_t = 0, size = CGSize.zero
            let ownerStatus = AXUIElementGetPid(candidate, &owner)
            let rawSize = value(candidate, kAXSizeAttribute)
            if let rawSize, CFGetTypeID(rawSize) == AXValueGetTypeID() {
                AXValueGetValue(rawSize as! AXValue, .cgSize, &size)
            }
            let sizeMatches = abs(size.width - expectedSize.width) < 1 && abs(size.height - expectedSize.height) < 1
            let matches = role == kAXWindowRole && ownerStatus == .success && owner == targetPID && sizeMatches
            candidateFacts.append(["role": role, "title": title,
                "titleCFType": rawTitle.map { String(describing: CFCopyTypeIDDescription(CFGetTypeID($0))) } ?? "nil",
                "ownerIsTarget": String(ownerStatus == .success && owner == targetPID), "size": "\(size)",
                "expectedHostSize": "\(expectedSize)", "roleOwnershipAndSizeMatch": String(matches)])
            if matches { candidates.append((candidate, title)) }
        }
        let exact = candidates.filter { $0.1 == appKitTitle }
        let selected = exact.count == 1 ? exact.first?.0 : windows.count == 1 && candidates.count == 1 ? candidates.first?.0 : nil
        guard let window = selected else {
            return .init(nodes: [], status: "Own public window metadata mismatch; AppKitTitle=\(appKitTitle); windowCount=\(windows.count); candidates=\(candidateFacts); \(errors)", complete: false)
        }
        var queue = [window], nodes: [OwnedCAXNode] = [], seen: [CFHashCode: [AXUIElement]] = [:]
        while !queue.isEmpty && nodes.count < 128 && ProcessInfo.processInfo.systemUptime < deadline {
            let element = queue.removeFirst(), hash = CFHash(element)
            guard !(seen[hash] ?? []).contains(where: { CFEqual($0, element) }) else { continue }
            seen[hash, default: []].append(element)
            AXUIElementSetMessagingTimeout(element, 1)
            let title = value(element, kAXTitleAttribute) as? String ?? ""
            let label = value(element, kAXDescriptionAttribute) as? String ?? ""
            let rawValue = value(element, kAXValueAttribute)
            nodes.append(.init(element: element, row: ["role": value(element, kAXRoleAttribute) as? String ?? "",
                "label": label.isEmpty ? title : label,
                "value": rawValue as? String ?? (rawValue as? NSNumber)?.stringValue ?? ""]))
            queue += value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        return .init(nodes: nodes, status: "ownWindow=true; AppKitTitle=\(appKitTitle); candidates=\(candidateFacts); nodes=\(nodes.count); remaining=\(queue.count); budgetExpired=\(ProcessInfo.processInfo.systemUptime >= deadline); optionalAttributeErrors=\(errors)", complete: queue.isEmpty && ProcessInfo.processInfo.systemUptime < deadline)
    }
    static func press(_ node: OwnedCAXNode) -> Int32 {
        AXUIElementSetMessagingTimeout(node.element, 1)
        return AXUIElementPerformAction(node.element, kAXPressAction as CFString).rawValue
    }
    static func runChild() {
        guard CommandLine.arguments.count >= 6, let target = pid_t(CommandLine.arguments[2]), target == getppid(),
              let width = Double(CommandLine.arguments[3]), let height = Double(CommandLine.arguments[4]) else { exit(1) }
        alarm(10)
        let snapshot = snapshot(targetPID: target, expectedSize: CGSize(width: width, height: height), appKitTitle: CommandLine.arguments[5])
        var statuses: [String: Int32] = [:]
        if snapshot.complete {
            for label in CommandLine.arguments.dropFirst(6) {
                guard let node = snapshot.nodes.first(where: { $0.row["role"] == kAXButtonRole && $0.row["label"] == label }) else { continue }
                statuses[label] = press(node)
            }
        }
        let report = OwnedCAXClientReport(rows: snapshot.nodes.map(\.row), status: snapshot.status,
            complete: snapshot.complete, clientTrusted: AXIsProcessTrusted(), presses: statuses)
        guard let data = try? JSONEncoder().encode(report) else { exit(1) }
        print(String(decoding: data, as: UTF8.self))
    }
    static func runRawChild() {
        guard CommandLine.arguments.count >= 6, let target = pid_t(CommandLine.arguments[2]), target == getppid() else { exit(1) }
        alarm(10)
        let raw = SceneSelectionCAXRawWindowReport(target) as Data
        let report = OwnedCAXClientReport(rows: [], status: "Raw Objective-C/C AX window metadata: " + String(decoding: raw, as: UTF8.self),
            complete: false, clientTrusted: AXIsProcessTrusted(), presses: [:])
        guard let data = try? JSONEncoder().encode(report) else { exit(1) }
        print(String(decoding: data, as: UTF8.self))
    }
    static func child(expectedSize: CGSize, appKitTitle: String, labels: [String], rawMetadata: Bool = false) async -> OwnedCAXClientReport? {
        let executable = CommandLine.arguments[0], parent = getpid()
        return await Task.detached {
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = [rawMetadata ? "--owned-cax-raw-client" : "--owned-cax-client", String(parent), String(Double(expectedSize.width)), String(Double(expectedSize.height)), appKitTitle] + labels
            process.standardOutput = output; process.standardError = errors
            do { try process.run() } catch { print("Owned AX client launch failed"); return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let folder = ProcessInfo.processInfo.environment["STREAM_SCENE_SEMANTIC_ARTIFACTS"] {
                let suffix = labels.contains("Owned SwiftUI baseline") ? "baseline" : "scene-action"
                try? data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("child-\(suffix).json"))
                try? errors.fileHandleForReading.readDataToEndOfFile().write(to: URL(fileURLWithPath: folder).appendingPathComponent("child-\(suffix).stderr"))
            }
            guard process.terminationStatus == 0 else { print("Owned AX client exit=\(process.terminationStatus)"); return nil }
            return try? JSONDecoder().decode(OwnedCAXClientReport.self, from: data)
        }.value
    }
}
@main @MainActor struct SceneSelectionNativeHarness {
    static func key(_ window: NSWindow, _ text: String, code: UInt16) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else { preconditionFailure("Owned key event creation") }
            window.sendEvent(event)
        }
    }
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--owned-cax-raw-client" { OwnedCAX.runRawChild(); return }
        if CommandLine.arguments.dropFirst().first == "--owned-cax-client" { OwnedCAX.runChild(); return }
        setbuf(stdout,nil)
        let app = NSApplication.shared; app.setActivationPolicy(.regular); app.finishLaunching()
        Task { @MainActor in exit(await run()) }; app.run()
    }
    static func run() async -> Int32 {
        let receipt = SelectionReceipt()
        let window = NSWindow(contentRect: NSRect(x: 60,y: 60,width: 350,height: 250),
            styleMask: [.titled,.closable],backing: .buffered,defer: false)
        window.isReleasedWhenClosed = false; window.title = "Owned scene selection semantics"
        let root = NSView(frame: NSRect(x:0,y:0,width:350,height:250)); window.contentView = root
        let host = NSHostingView(rootView: OwnedSemanticControls(receipt: receipt))
        host.frame = NSRect(x:0,y:50,width:350,height:200); root.addSubview(host)
        let nativeReceipt = NativeControlReceipt()
        let native = NSButton(title:"Owned AppKit positive control",target:nativeReceipt,action:#selector(NativeControlReceipt.activate(_:)))
        native.frame = NSRect(x:20,y:10,width:310,height:30)
        native.setAccessibilityLabel("Owned AppKit positive control"); root.addSubview(native)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try? await Task.sleep(for: .milliseconds(200))
        let publicCAX = CommandLine.arguments.contains("--public-cax-self")
        let rawChildCAX = CommandLine.arguments.contains("--public-cax-raw-child")
        let childCAX = rawChildCAX || CommandLine.arguments.contains("--public-cax-child")
        let expectedSize = window.frame.size, appKitTitle = window.title
        let nativeBeforeObservation = nativeReceipt.count
        let child = childCAX ? await OwnedCAX.child(expectedSize: expectedSize, appKitTitle: appKitTitle,
            labels: ["Owned SwiftUI baseline", "Owned AppKit positive control"], rawMetadata: rawChildCAX) : nil
        let cax = publicCAX ? await Task.detached { OwnedCAX.snapshot(expectedSize: expectedSize, appKitTitle: appKitTitle) }.value : nil
        let report: Data
        if let child {
            print("External owned C AX observation: clientTrusted=\(child.clientTrusted); \(child.status)")
            report = (try? JSONSerialization.data(withJSONObject: child.rows, options: [.sortedKeys])) ?? Data()
        } else if let cax {
            print("Public C AX self observation: \(cax.status)")
            report = (try? JSONSerialization.data(withJSONObject: cax.nodes.map(\.row), options: [.sortedKeys])) ?? Data()
        } else { report = SceneSelectionAXReport(window) as Data }
        let nodes = (try? JSONSerialization.jsonObject(with: report)) as? [[String: String]] ?? []
        var pressResults: [String: Int32] = [:]
        func pressOwned(_ label: String) async -> Bool {
            if childCAX {
                let result: OwnedCAXClientReport?
                if ["Owned SwiftUI baseline", "Owned AppKit positive control"].contains(label) { result = child }
                else { result = await OwnedCAX.child(expectedSize: expectedSize, appKitTitle: appKitTitle, labels: [label]) }
                guard let status = result?.presses[label] else { return false }
                pressResults[label] = status
                return status == AXError.success.rawValue
            }
            if let cax {
                guard let node = cax.nodes.first(where: { $0.row["label"] == label && $0.row["role"] == NSAccessibility.Role.button.rawValue }) else { return false }
                let status = await Task.detached { OwnedCAX.press(node) }.value
                pressResults[label] = status
                return status == AXError.success.rawValue
            }
            return SceneSelectionAXPress(window, label)
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let onConsole = (session?[kCGSessionOnConsoleKey as String] as? Bool).map { $0 as Any } ?? NSNull()
        let facts: [String: Any] = ["AXTrusted": AXIsProcessTrusted(), "sessionPresent": session != nil,
            "onConsole": onConsole,
            "windowVisible": window.isVisible, "windowKey": window.isKeyWindow, "applicationActive": NSApp.isActive,
            "lockState": "unknown: no public supported lock-state read used"]
        print("Public capability facts: \(facts)")
        if let path = ProcessInfo.processInfo.environment["STREAM_SCENE_SEMANTIC_ARTIFACTS"] {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            try? report.write(to: folder.appendingPathComponent("native-nodes.json"))
            try? JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys]).write(to: folder.appendingPathComponent("public-capabilities.json"))
        }
        let baseline = nodes.filter { $0["role"] == NSAccessibility.Role.button.rawValue && $0["label"] == "Owned SwiftUI baseline" }
        var baselinePressed = false
        if baseline.count == 1 { baselinePressed = await pressOwned("Owned SwiftUI baseline") }
        try? await Task.sleep(for: .milliseconds(50))
        let baselineQualified = baselinePressed && receipt.baselineActivations == 1
        print("Actual genuine stock SwiftUI baseline buttons=\(baseline.count), press=\(baselinePressed), callbacks=\(receipt.baselineActivations)")
        let nativeBefore = childCAX ? nativeBeforeObservation : nativeReceipt.count
        let bridgePressed: Bool
        if publicCAX || childCAX { bridgePressed = await pressOwned("Owned AppKit positive control") }
        else { bridgePressed = SceneSelectionAXPress(native,"Owned AppKit positive control") }
        let afterBridge = nativeReceipt.count
        let directPressed = native.accessibilityPerformPress()
        print("Actual native control role=\(native.accessibilityRole()?.rawValue ?? "nil"), label=\(native.accessibilityLabel() ?? "nil"), bridgePress=\(bridgePressed), bridgeCallbacks=\(afterBridge-nativeBefore), directPress=\(directPressed), directCallbacks=\(nativeReceipt.count-afterBridge)")
        let nativeQualified = bridgePressed && afterBridge - nativeBefore == 1
        if let path = ProcessInfo.processInfo.environment["STREAM_SCENE_SEMANTIC_ARTIFACTS"] {
            try? JSONSerialization.data(withJSONObject: pressResults, options: [.sortedKeys]).write(to: URL(fileURLWithPath: path).appendingPathComponent("public-press-status.json"))
        }
        guard baselineQualified && nativeQualified
                && (cax?.complete ?? true) && (!childCAX || child?.complete == true) else {
            print("UNQUALIFIED: genuine stock baseline is unavailable through the selected public observation boundary. Missing production nodes are not attributed to lock state or counted as product failure; observation cause remains unknown.")
            print("SCOPE: no production scene action/key acceptance follows. No fake tree, TCC request, VoiceOver toggle, global input or activation.")
            return 77
        }
        print("PASS genuine stock SwiftUI baseline role, label and actual accessibilityPerformPress callback")
        let buttons = nodes.filter { $0["role"] == NSAccessibility.Role.button.rawValue && $0["label"]?.hasPrefix("Select scene Owned scene") == true }
        print("Actual in-process public AX nodes=\(nodes.count), named scene buttons=\(buttons.count)")
        if buttons.count == 2 {
            precondition(buttons.contains { $0["label"] == "Select scene Owned scene 1" && $0["value"] == "Selected, Preview, Unpublished changes" })
            let pressed = await pressOwned("Select scene Owned scene 2")
            precondition(pressed)
            precondition(receipt.selected == 2 && receipt.activations.last == 2)
            print("PASS actual semantic scene button label/value/role and accessibilityPerformPress callback")
        } else { print("FAIL: production scene buttons missing despite a working genuine SwiftUI baseline"); return 1 }
        let before = receipt.activations.count
        key(window," ",code:49); try? await Task.sleep(for:.milliseconds(100))
        let afterSpace = receipt.activations.count
        key(window,"\t",code:48); key(window," ",code:49)
        try? await Task.sleep(for:.milliseconds(100))
        let keyboardQualified = afterSpace > before && receipt.activations.count > afterSpace && receipt.activations.suffix(2) == [1,2]
        if keyboardQualified {
            print("PASS actual owned native Space→first production scene button, Tab→Space→second production scene button")
        } else if !window.isKeyWindow || !NSApp.isActive {
            print("UNQUALIFIED: local key routing did not meet the unchanged callback oracle while the owned host is non-key or inactive; no control-defect or lock attribution. callbacks=\(receipt.activations)")
            return 77
        } else {
            print("FAIL: actual local keyboard scene-button activation; callbacks=\(receipt.activations), firstResponder=\(String(describing:window.firstResponder.map { type(of:$0) }))")
        }
        // This exact native object is queried directly. It is not inserted
        // into or substituted for SwiftUI's unavailable semantic subtree.
        print("SCOPE: actual mounted production SceneSelectionButton, own public in-process AX selectors/local window events only; no global activation/input/AX permissions, no VoiceOver or visual-contrast qualification")
        return keyboardQualified ? 0 : 1
    }
}
