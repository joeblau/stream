# Studio keyboard controls and accessibility

Open **Commands** in the toolbar or press **Shift-Command-P** to search studio
commands. Use arrows to select a result and Return to run it. The palette shows
current availability and the reason a command cannot run. Commands are checked
again by the shared dispatcher when invoked.

**Shortcuts** records additional bindings for a command. The initial Command-1
through Command-9 mappings point to scene UUIDs, so rename and reorder preserve
them. Command-L controls the current stream and Return performs Take. Shortcuts
live in `stream.shortcuts.v1.json` inside the selected project. Multiple keys may
address one command, but one key combination cannot address two commands. A
deleted target retains an explicitly missing mapping and never addresses a new
resource by position. Keys describe physical positions; their recorded labels
help identify them on the keyboard used to configure the project.

Native editing/file/navigation and existing annotation/presentation menu keys
are reserved. Production shortcuts are suppressed while typing in Stream, in a
sheet, and on auto-repeat. Return also preserves native control activation.

Global shortcuts start disabled. Enable the machine-local global switch and
choose **Global** for each binding. Global bindings require Command plus Option
or Control. Native macOS hot-key registration reports another app's ownership
instead of silently pretending registration succeeded. Global bindings are
unregistered on studio teardown/project switching. The master consent is omitted
from project files and exports. Global control still checks current targets and
availability, and never replays missed commands on reconnect.

The catalog covers scene selection, Take/Revert, layer and camera/PIP visibility,
audio mute/monitor/bus controls, media/playlist/sound transport, queued comments
and output start/stop. The native guest controller also supplies room actions and
current guest admission, Program/Monitor, screen approval, reconnect and removal
commands. Bindings target stable resource IDs; removed guests retain missing
mappings, and commands resolve against the current admitted connection before
execution.

Settings > Application offers interface text size, increased interface contrast,
and reduced UI motion. Explicit interface captions scale with the text-size
setting on macOS, including the scene browser, mixer, inspector, chat, settings
and command palette. Contrast uses opaque panel surfaces, borders and legible
secondary text alongside the native control appearance; media pixels retain
their original colors. System Reduce Motion also suppresses UI animations. These
preferences are machine-local. Compact Layout hides chat/inspector on a laptop;
the toolbar restores panels and its Focus menu moves keyboard focus. The
inspector uses a menu so every section fits on a narrow panel. Layer rows expose
named visibility/selection/order actions to VoiceOver. Mixer faders and buttons
announce their channel, value, and state; rapidly updating meters are excluded
from the accessibility tree. Chat's Follow New Messages toggle lets a producer
keep the reading position while messages arrive. Panel focus falls back to the
canvas when its panel closes. A surviving native control retains focus when an
unrelated panel changes. Settings, controller and permission sheets preserve
weak bookmarks to the original native control, including the control that owns
AppKit’s shared field editor; removed or hidden controls are never restored.
Command sheets restore the former first responder when it still belongs to the
studio.

## Validation

Run `apple/scripts/run_studio_shortcuts_harness.zsh` for deterministic target,
persistence, conflict, text-entry/modal/auto-repeat, opt-in, disconnect/reconnect,
project isolation and future-version preservation checks.

Run `apple/scripts/run_local_shortcut_harness.zsh` on a logged-in Mac for owned
AppKit window and first-responder qualification. It installs the shipping local
event monitor and sends app-local `NSEvent` fixtures through `NSApplication`.
The shipping catalog/dispatcher performs real scene selection, Take,
rename/reorder/delete and locked-layer rejection/recovery. Native text fields,
multiline editors and buttons retain typing/Return. An actual attached sheet
suppresses parent commands while explicit binding capture remains available.
The shipping SwiftUI palette receives text, Down and Return through its actual
search editor, executes the selected command once, dismisses and restores the
original field focus. Repeats cannot collapse palette presentation. Other owned
windows and monitor removal are checked too.

The runner uses temporary documents/preferences and generated tool-only
credential/microphone boundaries. It never registers global hotkeys, starts
capture/publishing, controls another application or injects `CGEvent` input.
Missing WindowServer access is explicitly unqualified (exit 77); a stalled
fixture fails within 45 seconds. These fixtures establish local event dispatch,
not physical keyboard input, device reconnect, global foreground-app control or
accessibility traversal. Build `StreamMac` separately for the complete app.

Run `apple/scripts/run_global_shortcut_harness.zsh` for the shipping Carbon
registration path with a separate owned application in front. It requires
existing event-post access and never requests a permission grant. Temporary
preferences and a temporary application isolate the test chord. Synthetic
WindowServer events verify both opt-ins, repeated press/release, ordinary input
in the foreground application, current command availability without replay,
palette suppression, disabling the master switch and unregistering on teardown.
The foreground helper restores the previous application and has a 20-second
watchdog. Missing access or an occupied chord exits 77. The local native run on
2026-10-21 passed; this does not qualify physical keys or arbitrary third-party
applications.

The `--modal-only` variant needs no event-post access or foreground application.
It sends owned Carbon events through the installed shipping handler while an
actual unattached AppKit application-modal session is open. This reproduced a
global command escaping the modal guard; the controller now checks
`NSApp.modalWindow` as well as its attached sheet. The regression passes
suppression, no replay on dismissal and a fresh deliberate press afterward.
A later full foreground run on this host could not activate its owned helper
and correctly exited 77 before posting input; the earlier successful run and
this environment limitation are separate evidence.

The workspace runner has three separate accessibility paths:

- `--accessibility` walks and invokes the owned studio through a separate public
  AX client. It never requests trust or controls another application.
- `--accessibility-local` queries actual mounted objects through the public
  native accessibility selectors. It does not fabricate SwiftUI semantics; an
  unavailable virtual element tree is explicitly unqualified.
- `--accessibility-native-controls` checks the mounted AppKit controls,
  process-local keyboard events, focus restoration and production style
  rendering. It cannot qualify an unavailable SwiftUI virtual accessibility
  tree and says so in its result.

The 2026-10-22 host session is locked. Existing AX trust was present, but external
AX exposed no owned window and direct native selectors exposed only native
controls/chrome rather than SwiftUI virtual labels and actions. No unlock,
permission grant, global key event or VoiceOver/system setting change was made.
The actual semantic label/action/order check remains open for issue #90. Native
control/render checks and their exact results are recorded separately; they are
not a substitute for that remaining check.

The final scoped native run on Mac15,8 / macOS 27.2(26B118), dated 2026-10-22,
built all native harness sources and exited 0. It exercised the shipping mounted
scene-search control, actual process-local Shift-Command-P/Escape/Tab events,
settings dismissal and an actual attached AppKit sheet through the production
focus notification attachment. The original field editor/control survived
restoration. The 13→20 point preference grew the native search callout by over 40%,
to 18.4615 points; the production relative caption fitting size grew 121×14 to 175×20.
At 1024×640 the actual root inherited text size, contrast and reduced-motion
preferences. These are native font/environment observations, not a completed
check of every primary-control boundary.

Actual original PCM drove the real software mixer to 0.79999995 pre-fader peak
while production meter polling preserved the native scene-search owner. All 24
incoming chat queue fixtures were accepted without replacing the native chat
search field editor. The owning fader remains a virtual SwiftUI control with no
native NSSlider descendant here; its own-focus and accessibility-action checks
are still unqualified. The software-only meter fixture explicitly disables
Voice Polish, Audio Unit inserts and monitoring; it makes no DSP claim.

The native bitmap's normal red reference did not match its comparison control,
so contrast pixels remain unqualified. The production contrast implementation
is present and compiled; this result does not establish an actual media color
change or a successful visual contrast comparison. The current actual evidence,
run hash and precise remaining scope are in
[`STUDIO_ACCESSIBILITY_2026-10-22.json`](STUDIO_ACCESSIBILITY_2026-10-22.json).

## Show macros

Inspector > Macros creates named ordered sequences from the shared command
catalog. Edit a step's delay, condition and Stop/Continue failure policy, and
move steps with keyboard buttons. Preview / Run lists every step and its current
availability before running. Future steps are checked again at execution time;
a currently stopped output may become available after an earlier step starts it.

Only one macro runs at a time. Output/Take transitions settle before the next
step, with a 30-second timeout; publisher or recording failures stop the sequence
unless that step explicitly uses Continue. Conflicting manual Start/Take/rundown
actions are rejected while a macro owns the sequence. Emergency Stop cancels the
macro before stopping its output. Cancel prevents delayed future steps, retains
completed actions and reports progress. Macros cannot invoke macros or use the
output toggle command. Launching a project never resumes an old macro run.

Macro documents contain stable command/resource IDs and policy only, stored in
`stream.macros.v1.json` within the project. Macro Run and Cancel are available in
the same shortcut catalog that hardware controllers consume. Test with
`apple/scripts/run_show_macros_harness.zsh`.
