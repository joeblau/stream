import SwiftUI

struct StudioHelpView: View {
    private let topics: [(String, String)] = [
        ("Preview and Program", "Scene and layer edits are staged in Preview. Take publishes them to Program. Revert discards unpublished edits. Direct Live Editing applies each edit immediately. Start and stop preview, recording, and live output independently."),
        ("Audio routing", "Program is the outgoing mix. Monitor is headphone playback; use headphones to avoid feedback. Per-channel mute, gain, routing, effects, and delay affect the corresponding bus. A guest's return needs mix-minus so they do not hear their own voice."),
        ("Sources and permissions", "Add cameras and screen sources in Sources. Grant camera/microphone access and choose screen content through the system picker. Missing sources can be relinked by stable identity. Repair revoked permissions in System Settings. NDI, DeckLink, and Zoom require their own qualified adapters."),
        ("Outputs and rehearsal", "Configure destinations inside the studio. LIVE requires a publisher acknowledgment; Connecting and Reconnecting have distinct states. Local rehearsal uses preview and recording. Provider private/test broadcasts require provider support. Recording errors are shown independently of network output."),
        ("Shows and transfer", "The toolbar show name opens projects and profiles. Selecting a show stages it; Apply requires stopped streaming/recording. Backup History previews prior scenes. Export Show chooses included media or repairable references. Import previews a separate show, remaps IDs, and requires source and destination setup."),
        ("Chat and comment queue", "Connect Restream in Settings. Search/filter public messages, favorite them and build a queue. Create a staged Comment Slot; Show/Hide edit Preview and Take publishes. Direct Live Editing applies changes immediately. Direct provider sessions, reply/moderation, avatars and viewer metrics are unavailable."),
        ("Session recovery", "Recovery reviews interrupted sessions without restarting outputs or replaying commands. Restore Local Context explicitly opens the saved show/profile and available staged references; media restores paused. Missing content needs Backup History or relinking. Review Recordings opens the attached library."),
        ("External controls", "The command palette and configurable shortcuts use the same commands as the studio. Global shortcuts require explicit consent. Hardware and local clients must pair through an enabled authenticated control interface; revoke clients when access is no longer needed. Actions reject missing or unavailable targets.")
    ]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Studio Help").font(.title2)
                ForEach(topics, id: \.0) { topic in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(topic.0).font(.headline)
                        Text(topic.1).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.padding(16)
        }.frame(width: 440, height: 500)
    }
}
