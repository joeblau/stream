import AppKit
import Foundation

/// Receives this process's native open-document event without asking SwiftUI
/// to replace the single production window. URLs retain their original scope.
@MainActor
final class StudioPackageOpenReceiver: NSObject {
    static let shared = StudioPackageOpenReceiver()
    private weak var workspace: StudioWorkspace?
    private var installed = false
    private var pending: [URL] = []
    private let maximumFiles = 8

    func install() {
        guard !installed else { return }
        installed = true
        NSAppleEventManager.shared().setEventHandler(self,
            andSelector: #selector(receive(_:withReplyEvent:)),
            forEventClass: 0x61657674, andEventID: 0x6f646f63) // aevt / odoc
    }

    func bind(_ workspace: StudioWorkspace) {
        install()
        self.workspace = workspace
        let waiting = pending
        pending.removeAll()
        present(waiting, in: workspace)
    }

    func shutdown() {
        workspace = nil
        pending.removeAll()
        guard installed else { return }
        installed = false
        NSAppleEventManager.shared().removeEventHandler(forEventClass: 0x61657674, andEventID: 0x6f646f63)
    }

    @objc private func receive(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let list = event.paramDescriptor(forKeyword: 0x2d2d2d2d), // direct object
              (1...maximumFiles).contains(list.numberOfItems) else { return }
        let urls = (1...list.numberOfItems).compactMap { list.atIndex($0)?.fileURLValue }
            .filter { $0.isFileURL && $0.pathExtension.lowercased() == "streamshow" }
        guard !urls.isEmpty else { return }
        if let workspace { present(urls, in: workspace) }
        else { pending.append(contentsOf: urls.prefix(maximumFiles - pending.count)) }
    }

    private func present(_ urls: [URL], in workspace: StudioWorkspace) {
        guard !urls.isEmpty else { return }
        guard urls.count == 1 else {
            workspace.error = "Open one show package at a time."
            workspace.showProjects = true
            return
        }
        workspace.previewPackage(urls[0])
    }
}
