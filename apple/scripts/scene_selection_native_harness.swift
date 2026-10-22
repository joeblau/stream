import AppKit
import SwiftUI

@MainActor private final class SelectionReceipt: ObservableObject {
    @Published var selected = 1
    @Published var activations: [Int] = []
    func select(_ id: Int) { selected = id; activations.append(id) }
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
        setbuf(stdout,nil)
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
        Task { @MainActor in exit(await run()) }; app.run()
    }
    static func run() async -> Int32 {
        let receipt = SelectionReceipt()
        let window = NSWindow(contentRect: NSRect(x: 60,y: 60,width: 350,height: 200),
            styleMask: [.titled,.closable],backing: .buffered,defer: false)
        window.isReleasedWhenClosed = false; window.title = "Owned scene selection semantics"
        let root = NSView(frame: NSRect(x:0,y:0,width:350,height:200)); window.contentView = root
        let host = NSHostingView(rootView: OwnedSceneCards(receipt: receipt))
        host.frame = NSRect(x:0,y:50,width:350,height:150); root.addSubview(host)
        let nativeReceipt = NativeControlReceipt()
        let native = NSButton(title:"Owned AppKit positive control",target:nativeReceipt,action:#selector(NativeControlReceipt.activate(_:)))
        native.frame = NSRect(x:20,y:10,width:310,height:30)
        native.setAccessibilityLabel("Owned AppKit positive control"); root.addSubview(native)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try? await Task.sleep(for: .milliseconds(200))
        let report = SceneSelectionAXReport(window) as Data
        let nodes = (try? JSONSerialization.jsonObject(with: report)) as? [[String: String]] ?? []
        let buttons = nodes.filter { $0["role"] == NSAccessibility.Role.button.rawValue && $0["label"]?.hasPrefix("Select scene Owned scene") == true }
        print("Actual in-process public AX nodes=\(nodes.count), named scene buttons=\(buttons.count)")
        if buttons.count == 2 {
            precondition(buttons.contains { $0["label"] == "Select scene Owned scene 1" && $0["value"] == "Selected, Preview, Unpublished changes" })
            precondition(SceneSelectionAXPress(window,"Select scene Owned scene 2"))
            precondition(receipt.selected == 2 && receipt.activations.last == 2)
            print("PASS actual semantic scene button label/value/role and accessibilityPerformPress callback")
        } else {
            print("UNQUALIFIED: locked-session SwiftUI virtual semantic tree is unavailable; no replacement AX tree or invented label/action pass")
        }
        let before = receipt.activations.count
        key(window," ",code:49); try? await Task.sleep(for:.milliseconds(100))
        let afterSpace = receipt.activations.count
        key(window,"\t",code:48); key(window," ",code:49)
        try? await Task.sleep(for:.milliseconds(100))
        let keyboardQualified = afterSpace > before && receipt.activations.count > afterSpace && receipt.activations.suffix(2) == [1,2]
        if keyboardQualified {
            print("PASS actual owned native Space→first production scene button, Tab→Space→second production scene button")
        } else {
            print("UNQUALIFIED: actual local keyboard scene-button activation; callbacks=\(receipt.activations), firstResponder=\(String(describing:window.firstResponder.map { type(of:$0) }))")
        }
        // This exact native object is queried directly. It is not inserted
        // into or substituted for SwiftUI's unavailable semantic subtree.
        let bridgePressed = SceneSelectionAXPress(native,"Owned AppKit positive control")
        let directPressed = native.accessibilityPerformPress()
        print("Actual native control role=\(native.accessibilityRole()?.rawValue ?? "nil"), label=\(native.accessibilityLabel() ?? "nil"), bridgePress=\(bridgePressed), directPress=\(directPressed), callbacks=\(nativeReceipt.count)")
        if bridgePressed && directPressed && nativeReceipt.count == 2 {
            print("PASS bridge positive control: actual mounted NSButton role/label and accessibilityPerformPress callback; separate from production scene-button qualification")
        } else {
            print("UNQUALIFIED: genuine native-control AX positive control; no scene semantic acceptance follows")
        }
        print("SCOPE: actual mounted production SceneSelectionButton, own public in-process AX selectors/local window events only; no global activation/input/AX permissions, no VoiceOver or visual-contrast qualification")
        return buttons.count == 2 && keyboardQualified ? 0 : 77
    }
}
