import AppKit
import SwiftUI

/// Each presentation keeps its own weak native control bookmark. Field editors
/// are shared by AppKit, so restore their owning control, never an orphan editor.
@MainActor final class StudioFocusRestoration: ObservableObject {
    private final class Bookmark {
        weak var responder: NSResponder?
        init(_ responder: NSResponder?) { self.responder = responder }
    }
    private weak var window: NSWindow?
    private var bookmarks: [String: Bookmark] = [:]
    /// A queued completion belongs to one attachment and presentation intent.
    /// A new presentation, restoration request or detach retires older work,
    /// even if the same NSWindow/control is subsequently attached again.
    private var restorationGeneration: UInt64 = 0
    func attach(_ window: NSWindow?) {
        guard self.window !== window else { return }
        restorationGeneration &+= 1
        bookmarks.removeAll(); self.window = window
    }
    func remember(_ scope: String) {
        guard bookmarks[scope] == nil, let window else { return }
        restorationGeneration &+= 1
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
           let owner = editor.delegate as? NSView, owner.window === window {
            bookmarks[scope] = Bookmark(owner)
        } else { bookmarks[scope] = Bookmark(window.firstResponder) }
    }
    func restore(_ scope: String, fallback: (@MainActor () -> Void)? = nil) {
        guard let window, let bookmark = bookmarks.removeValue(forKey: scope) else { return }
        restorationGeneration &+= 1
        let generation = restorationGeneration
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window,
                  self.restorationGeneration == generation,
                  window.attachedSheet == nil else { return }
            if let view = bookmark.responder as? NSView, view.window === window,
               !view.isHiddenOrHasHiddenAncestor, window.makeFirstResponder(view) { return }
            fallback?()
        }
    }
}

/// Notification registration is actor-owned, while ARC teardown can happen
/// elsewhere. This bag also makes teardown safe if SwiftUI skips dismantling.
private final class StudioFocusObservers: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [NSObjectProtocol] = []
    func append(_ value: NSObjectProtocol) { lock.lock(); values.append(value); lock.unlock() }
    func removeAll() {
        lock.lock(); let old = values; values.removeAll(); lock.unlock()
        for value in old { NotificationCenter.default.removeObserver(value) }
    }
    deinit { removeAll() }
}

/// Native open/save/alert sheets use the same owned-window restoration path as
/// SwiftUI sheets. Observers neither inspect nor focus any other application's UI.
struct StudioFocusAttachment: NSViewRepresentable {
    let coordinator: StudioFocusRestoration
    final class Attachment: NSView {
        var coordinator: StudioFocusRestoration?
        private weak var observedWindow: NSWindow?
        private let observers = StudioFocusObservers()
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard observedWindow !== window else { return }
            removeObservers(); observedWindow = window; coordinator?.attach(window)
            guard let window else { return }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willBeginSheetNotification,
                object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.coordinator?.remember("native-sheet") }
                })
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification,
                object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.coordinator?.restore("native-sheet") }
                })
        }
        func removeObservers() {
            observers.removeAll()
        }
    }
    func makeNSView(context: Context) -> Attachment {
        let view = Attachment(); view.coordinator = coordinator; return view
    }
    func updateNSView(_ nsView: Attachment, context: Context) {
        nsView.coordinator = coordinator; coordinator.attach(nsView.window)
    }
    static func dismantleNSView(_ nsView: Attachment, coordinator: ()) {
        nsView.removeObservers(); nsView.coordinator?.attach(nil)
    }
}
