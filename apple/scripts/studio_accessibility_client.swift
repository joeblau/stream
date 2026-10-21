import ApplicationServices
import Foundation

// Separate public AX client: in-process AX calls bypass IPC and can invoke
// SwiftUI getters on the caller executor. This client only addresses its
// parent fixture PID. It never requests accessibility trust.
private struct StudioAXNode {
    let element: AXUIElement
    let role: String
    let label: String
    let value: String
    let frame: CGRect
    let focused: Bool
    let enabled: Bool
}
private enum StudioAXClient {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    static func rectangle(_ element: AXUIElement) -> CGRect {
        var origin = CGPoint.zero, size = CGSize.zero
        if let value = attribute(element, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cgPoint, &origin)
        }
        if let value = attribute(element, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: origin, size: size)
    }
    static func snapshot() throws -> [StudioAXNode] {
        guard CommandLine.arguments.count > 1, let pid = pid_t(CommandLine.arguments[1]), pid == getppid() else {
            throw NSError(domain: "StudioAccessibility", code: 77, userInfo: [NSLocalizedDescriptionKey: "AX client must address only its parent fixture process"])
        }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 1)
        guard let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement], let window = windows.first else {
            throw NSError(domain: "StudioAccessibility", code: 77, userInfo: [NSLocalizedDescriptionKey: "Owned process does not expose its public AX window; trust=\(AXIsProcessTrusted())"])
        }
        var queue = [window], result: [StudioAXNode] = []
        var seen: [CFHashCode: [AXUIElement]] = [:]
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while !queue.isEmpty && result.count < 2_000 {
            let element = queue.removeFirst()
            let hash = CFHash(element)
            guard !(seen[hash] ?? []).contains(where: { CFEqual($0, element) }) else { continue }
            seen[hash, default: []].append(element)
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw NSError(domain: "StudioAccessibility", code: 77, userInfo: [NSLocalizedDescriptionKey: "Owned AX snapshot exceeded its 20-second bound"])
            }
            let title = attribute(element, kAXTitleAttribute) as? String ?? ""
            let description = attribute(element, kAXDescriptionAttribute) as? String ?? ""
            let titleElement = attribute(element, kAXTitleUIElementAttribute)
            let relatedTitle: String
            if let titleElement, CFGetTypeID(titleElement) == AXUIElementGetTypeID() {
                relatedTitle = attribute(titleElement as! AXUIElement, kAXValueAttribute) as? String ?? ""
            } else { relatedTitle = "" }
            let rawValue = attribute(element, kAXValueAttribute)
            let value = (rawValue as? String) ?? (rawValue as? NSNumber)?.stringValue ?? ""
            result.append(.init(element: element, role: attribute(element, kAXRoleAttribute) as? String ?? "",
                label: !title.isEmpty ? title : !description.isEmpty ? description : !relatedTitle.isEmpty ? relatedTitle
                    : attribute(element, kAXPlaceholderValueAttribute) as? String ?? "",
                value: value, frame: rectangle(element),
                focused: attribute(element, kAXFocusedAttribute) as? Bool ?? false,
                enabled: attribute(element, kAXEnabledAttribute) as? Bool ?? true))
            queue += attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        guard queue.isEmpty else {
            throw NSError(domain: "StudioAccessibility", code: 77, userInfo: [NSLocalizedDescriptionKey: "Owned AX tree exceeded the 2,000-element bound"])
        }
        return result
    }
    static func action(_ label: String, focus: Bool = false) throws {
        guard let node = try snapshot().first(where: { $0.label == label }) else {
            throw NSError(domain: "StudioAccessibility", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing public AX control: \(label)"])
        }
        let status = focus
            ? AXUIElementSetAttributeValue(node.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            : AXUIElementPerformAction(node.element, kAXPressAction as CFString)
        guard status == .success else {
            throw NSError(domain: "StudioAccessibility", code: 2, userInfo: [NSLocalizedDescriptionKey: "AX press \(label): \(status.rawValue)"])
        }
    }
}

do {
    if CommandLine.arguments.count > 3 && CommandLine.arguments[2] == "press" {
        try StudioAXClient.action(CommandLine.arguments[3]); print("[]")
    } else if CommandLine.arguments.count > 3 && CommandLine.arguments[2] == "focus" {
        try StudioAXClient.action(CommandLine.arguments[3], focus: true); print("[]")
    } else {
        let rows = try StudioAXClient.snapshot().map { node -> [String: Any] in
            ["role": node.role, "label": node.label, "value": node.value,
             "x": node.frame.minX.isFinite ? node.frame.minX : 0,
             "y": node.frame.minY.isFinite ? node.frame.minY : 0,
             "width": node.frame.width.isFinite ? node.frame.width : 0,
             "height": node.frame.height.isFinite ? node.frame.height : 0,
             "focused": node.focused, "enabled": node.enabled]
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit((error as NSError).code == 77 ? 77 : 1)
}
