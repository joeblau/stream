# Guest mute, monitor solo and local names

The embedded Guests panel exposes mute and monitor solo for the current ready
connection. Both edit the existing persisted mixer document through
StudioCommandDispatcher, using the same channel as the Mixer inspector. There
is no separate guest gain, mute or solo state. Mute affects the guest channel;
solo affects private Monitor after Monitor admission and leaves Program
unchanged. A saved solo for a guest without Monitor permission grants no route
and does not suppress unrelated private audio.

Each panel/palette command captures the full room, host and guest generations,
slot, negotiation and native receive generation. Retained commands and adapter
callbacks reject a rejoined/replaced connection before changing settings. A new
authorized stable catalogue request resolves its current action normally; saved
slot Mixer configuration remains editable independently of room admission.

Save Local Name changes the project's optional `GuestSlot.localName`, used by
the panel and bound name overlays. Guest-reported `displayName` keeps its own
identity and can update without erasing the alias. Use Guest Name removes the
alias. Prepared slots may also configure an alias before arrival. Local names
persist and travel as literal public content in portable shows; they are not
sent to the Worker and never change an invite, credential or service identity.

Qualification uses the actual owned local Worker with URLSession HTTP/WebSocket,
the shipping manager/controller/dispatcher and real mixer PCM. The manager
fixture checks two independent tones: mute removes only the guest, monitor solo
excludes unrelated audio without changing Program, saved mute/solo reload through
the real settings file, and stale full-context commands/callbacks cannot edit a
rejoined guest. Actual project reload and portable reference remapping preserve
literal aliases. The slot renderer fixture checks that nested bound text equals
an independently rendered literal caption, retains its local alias when service
metadata updates, and restores reported-name pixels when cleared.

Run `apple/scripts/run_native_interview_manager_harness.zsh` with pinned
Node 24.15+/npm 12 installed in `workers/interviews`, then
`apple/scripts/run_guest_slots_harness.zsh`. The established generated fixture
boundaries isolate defaults and credentials and refuse device capture. The
manager media host is controlled; these tests do not qualify browser decoding,
deployed TURN, Internet/mobile/restricted networks or operator devices.

One native admitted media peer remains the measured limit. Private talkback,
guest messages and combined return routing are separate work; this change does
not close issue #128.
