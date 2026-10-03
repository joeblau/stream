import SwiftUI

struct StudioHelpView: View {
    private let topics: [(String, String)] = [
        ("Preview and Program", "Scene and layer edits are staged in Preview. Take publishes them to Program. Revert discards unpublished edits. Direct Live Editing applies each edit immediately. Start and stop preview, recording, and live output independently."),
        ("Audio routing", "Program is the outgoing mix. Monitor is headphone playback; use headphones to avoid feedback. Per-channel mute, gain, routing, effects, and delay affect the corresponding bus. A guest's return needs mix-minus so they do not hear their own voice."),
        ("Sources and permissions", "Choose cameras that macOS exposes, screen selections, media, PDFs, Syphon servers or web overlays in Sources. Grant camera/microphone access and choose screen content through the system picker. Repair missing identities or revoked permissions before production. NDI, DeckLink, Zoom and native interview guest media require separate qualified adapters; selecting a source does not supply one."),
        ("Outputs and rehearsal", "Configure destinations inside the studio. LIVE requires a publisher acknowledgment; Connecting and Reconnecting have distinct states. Local rehearsal uses preview and recording. Provider private/test broadcasts require provider support. Recording errors are shown independently of network output."),
        ("Shows and transfer", "The toolbar show name opens projects and profiles. Selecting a show stages it; Apply requires stopped streaming/recording. Backup History previews prior scenes. Export Show chooses included media or repairable references. Import previews a separate show, remaps IDs, and requires source and destination setup."),
        ("Chat and comment queue", "Use Restream in Settings or explicitly Read Public Chat for an authorized YouTube/Twitch account. Search/filter public messages, favorite them and build a queue. Show/Hide edits the staged Comment Slot; Take publishes it. Long comments use complete pages: Previous/Next Page stages each page. Avatar is off by default and loads only available supported public images. Reply/delete require the actual provider's granted permissions; threaded YouTube replies and image emotes are unavailable. Viewer readings can be unavailable or stale; ingest alone never proves remote audience state."),
        ("Secondary canvas", "Expand Secondary Canvas below the main monitors. Copy Program Geometry, choose the secondary size, then drag or change visibility in Secondary Preview. Follow Program restores a layer's geometry link. Take publishes both layouts. Guides remain editor-only. Select Program or Secondary layout in each destination. Secondary recording has its own controls and mixed Program audio; encoder reservations and Mac qualification can block a start."),
        ("Recording and library", "Recording Options selects MP4/MOV, H.264/HEVC, quality, folder and file naming, with optional auto-record, countdown and splitting. Pause/Resume and New File leave streaming active. Available channel/bus taps support isolated WAV/M4A before or after inserts; independent widget audio and native guest capture are unavailable. Open the Recording Library to inspect sessions, tracks and failures, add markers, preview or trim a new clip, reveal in Finder, share or choose an editor explicitly. Recording has its own encoder; network encoder sharing is unavailable."),
        ("Stop Local and End Remote", "In Destinations, Stop Local detaches publishing without a provider completion request. End Remote freshly verifies and completes a permitted YouTube live event while local delivery continues. End Both/End All keeps independent results; other connectors need manual remote controls. Recording continues. A lost response stays unknown until review. An optional saved outro/black scene uses Select Scene and Take; changing Program or an output session cancels its delayed ending."),
        ("Optional device outputs", "The Outputs inspector offers the virtual camera and clean external display feed; the microphone's install instructions are separate. A virtual device requires explicit enablement and its signed installation/OS activation path. Receiving-app and physical-device compatibility remain unqualified. Optional adapter registrations start disabled and require explicit pairing; a declared media capability is not an installed transport."),
        ("Stream Deck pairing", "Install the development Stream Studio plugin, enable Local Control in Stream, and pair a client named Stream Deck. Copy its pairing JSON into a Studio Command key's property inspector, then choose Save Pairing in Keychain. Select a fresh command for the current project. Revoke the client in Stream or Forget Pairing in the plugin to remove access. Signed installation, physical devices and Plus hardware still need qualification; the repository Stream Deck guide has build and pairing steps."),
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
