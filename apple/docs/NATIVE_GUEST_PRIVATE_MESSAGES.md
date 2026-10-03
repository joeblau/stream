# Private guest text messages

The native Guests panel and the guest browser exchange plain text over the
current authenticated WebRTC media control channel. The native Send button uses
`StudioCommandDispatcher` with the complete ready peer context. An old retained
button or command cannot send to the connection replacing it. Hosts that do not
advertise the private-message capability leave the browser composer disabled.
Text neither enters Program audio/video nor changes admission or routing.

Messages require an explicit send, at most 512 UTF-8 bytes and an exact current
negotiation. Both sides keep at most 64 ephemeral entries and eight pending
receipts. “Received” reports an actual acknowledgment after the other application
accepted the text; it does not report human reading. After ten seconds without
that receipt, delivery remains unknown. No message or mutation is automatically
replayed, including reconnect. Unsolicited or late acknowledgments do not create
history or change a timed-out receipt. Duplicate messages are suppressed within
the retained history. Connection replacement, control closure, removal, room end,
profile retirement and Quit clear the conversation; browser drafts are cleared
as well. Native drafts clear when the channel retires or the full context changes.

Conversation text stays separate from the shared control snapshot, project and
mixer documents, portable shows and recording archives. The UI renders plain
text, including literal HTML characters. Protocol and SDK queues remain bounded:
private traffic has its own rate/occupancy limits, malformed or excessive traffic
is dropped independently, and queued private events yield space to media control
events. No Task is created per message. Missing acknowledgments never trigger
media reconnect or disable healthy camera/audio.

## Qualification

Run `apple/scripts/run_native_interview_manager_harness.zsh` using its documented
pinned Node/Worker setup and isolated fixture storage. This uses the actual owned
Worker, URLSession, shipping manager/controller/dispatcher and owned SwiftUI
hosting lifecycle. Its controlled media host proves pending-versus-acknowledged
states, bounds, duplicate handling, saturated private-versus-media queue ownership,
control-close cleanup and rejection of retained commands after real host rejoin.
It does not claim RTP transport from the controlled host.

For actual data-channel transport, build
`apple/scripts/build_native_interview_media_cli.zsh` with the qualified pinned
public SDK include/archive and isolated StreamCore framework paths documented in
`NATIVE_INTERVIEW_RECEIVER.md`. Then run:

```sh
DYLD_FRAMEWORK_PATH=/absolute/owned/Build/Products/Debug \
NATIVE_INTERVIEW_MEDIA_CLI=/absolute/owned/native-interview-media-cli \
STREAM_INTERVIEW_TURN_SERVER=/absolute/owned/pinned-coturn/turnserver \
node workers/interviews/test/browser/native-session-relay-browser.mjs --private-messages
```

The fixture owns a disposable local Worker, local Coturn and synthetic Chrome
capture inputs. Both endpoints must actually select local UDP relay candidates.
It checks both directions and real receipts, literal Unicode/HTML, body/envelope
bounds, duplicate delivery, eight occupied receipts and ninth refusal, ten-second
unknown delivery without resend, late/unsolicited ACKs, malformed/stale/flood
isolation while real H.264/Opus media advances, and fresh rejoin/end cleanup.
Only message hashes and bounded delivery metadata enter fixture IPC or logs.
Synthetic credentials/state are removed during bounded child cleanup. The native
workflow runs this mode on ARM and Intel; hosted results remain separate from a
local pass.

This is the private-text slice of issue #128. Private microphone talkback needs a
separate addressed audio route and remains open. Native capacity remains one;
deployed broker/TURN, Internet/mobile/restricted-network, device permissions,
operator services and signed installation are separate qualification gates.
