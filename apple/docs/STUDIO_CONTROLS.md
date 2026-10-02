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
audio mute/monitor/bus controls, media/playlist/sound transport and output
start/stop. Comments and guest slots are visibly unavailable until their actual
controllers exist; the editor cannot bind those notices.

Settings > Application offers interface text size, native increased contrast,
and reduced UI motion. System Reduce Motion also suppresses UI animations. These
preferences are machine-local. Compact Layout hides chat/inspector on a laptop;
the toolbar restores panels and its Focus menu moves keyboard focus. The
inspector uses a menu so every section fits on a narrow panel. Layer rows expose
named visibility/selection/order actions to VoiceOver. Mixer faders and buttons
announce their channel, value, and state; rapidly updating meters are excluded
from the accessibility tree. Chat's Follow New Messages toggle lets a producer
keep the reading position while messages arrive. Panel focus falls back to the
canvas when its panel closes; command sheets restore the former first responder
when it still belongs to the studio.

## Validation

Run `apple/scripts/run_studio_shortcuts_harness.zsh` for deterministic target,
persistence, conflict, text-entry/modal/auto-repeat, opt-in, disconnect/reconnect,
project isolation and future-version preservation checks. Build `StreamMac` to
validate the native menu, window, accessibility and hot-key integrations.

Manual acceptance still needs VoiceOver/Accessibility Inspector and Full
Keyboard Access on a running studio: traverse panels and layer actions, adjust
mixer sliders, restore focus after all native import/permission/settings sheets,
read chat with Follow disabled, and test 1024×640 at every text size/contrast
setting. Check global registration and ordinary text input while another app is
foreground. These manual checks are not represented as completed by the harness.
