import Combine
import Foundation

extension RecordingController {
    /// Runtime binding forwards typed public deliveries only. Queue featuredID
    /// is staged intent; visibility comes from accepted rendered video instead.
    func bindChat(_ chat: StudioChatCoordinator) {
        chatSubscriptions.removeAll()
        for binding in chat.recentRecordingBindings { chatFeed.bind(binding) }
        let feed = chatFeed
        chat.recordingMessages.sink { [feed] message in feed.receive(message) }.store(in: &chatSubscriptions)
        chat.recordingBindings.sink { [feed] binding in feed.bind(binding) }.store(in: &chatSubscriptions)
    }
}
