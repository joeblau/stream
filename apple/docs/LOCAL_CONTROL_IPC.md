# Stream local controller IPC, version 1

The native studio exposes a validated local IPC bridge for hardware plugins and
local automation. It uses UTF-8 JSON messages separated by a newline over TCP
bound specifically to **127.0.0.1:32145**. It has no HTTP interface, browser CORS
flow, LAN listener or unauthenticated command path. macOS's Network framework
owns the listener; sandboxed builds require the network-server entitlement.

Enable **Settings > Application > Enable paired local controllers**. Pair each
client by its descriptive name. Copy the client UUID and 256-bit token from the
pairing sheet into that client. Each token is saved in this Mac's Keychain;
`local-control.clients.v1.json` contains client names/UUIDs/dates only. Credentials
are omitted from projects and exports. Revoke disconnects that client's sessions,
deletes its credential and cancels a macro started by its connection. Disabling
local control closes all sessions. Project switching closes the old listener and
sessions, so a client must authenticate and inspect the new project before
sending another command.

Every request has `version: 1`, a UUID `id`, and a typed `type`. The first message
on a connection must authenticate:

```json
{"version":1,"type":"authenticate","id":"<request UUID>","clientID":"<paired UUID>","token":"<64 hex characters>"}
```

An `authenticated` response has the matching request ID, a new `sessionID` UUID,
and an authoritative state snapshot. Every later request must carry that
session ID and a new request ID. No later request includes the pairing token.
Do not retry output or toggle commands on reconnect. An old session ID is
rejected, and duplicate request IDs within a session cannot execute twice.

Supported operations:

| Request type | Additional fields | Response |
| --- | --- | --- |
| `capabilities` | `cursor` (optional nonnegative offset) | Up to 20 command descriptors; `nextCursor` and `totalCommands` |
| `snapshot` | None | Current state |
| `subscribe` | None | Snapshot, then full-state `event` messages |
| `command` | `commandID` (stable catalog ID) | Result and post-command snapshot |
| `ping` | None | `pong` |

Capabilities include UUID-based command/resource IDs, current titles/categories,
availability, and rejection reasons. Renaming/reordering a scene preserves its
command ID; deleted targets return `invalidTarget` and never retarget by name or
position. Example IDs: `scene.<scene UUID>.select`,
`scene.<scene UUID>.layer.<layer UUID>.visibility`, `output.stream.start`,
`output.stream.stop`, `output.record.start`, `studio.take`,
`macro.<macro UUID>.run`, and `macro.cancel`. Discover the actual IDs from the
running project. Bindings use the same catalog as native keyboard shortcuts.

A `result` response includes `result.commandID`, `result.succeeded`, an optional
structured `result.error`, and the authoritative state after the dispatcher
attempt. Permission/setup choices still gate execution. An accepted Start Stream
request can return `connecting`; only an acknowledged publisher produces `live`.
Native capture/output availability remains the shared dispatcher's decision.
Guest commands expose the current room and participant catalogue, with fresh admission limits and full-connection validation for mute/solo. Interview snapshots include public roster metadata and actual local Program/Monitor permission, screen approval and sharing; they contain no private message text, invite or credentials. Comment commands use the actual queued public chat and selected staged comment slot; Show/Hide follow Preview/Program policy and do not implicitly Take.

Version 1 now includes optional capability `kind` (`command`, `value` or display-only `feedback`) and `argument` (`page` or `text`) fields. Numeric commands accept exactly one finite normalized `value` (0…1) or `delta` (−1…1). Relative deltas resolve against current dispatcher state and clamp there, making multiple encoders safe. Gain targets convert normalized values to linear gain 0…2. `pdf.<UUID>.goto` accepts a zero-based integer `page` from 0 to 100000; the native deck store clamps to the actual document. `output.record.marker` accepts optional `text` with 1–512 UTF-8 bytes. Other IDs reject these arguments; arguments are forbidden outside command requests. Per-client adapter grants still check the exact stable target ID. Old clients can omit numeric/argument fields. Generation-sensitive controls require the current optional capability `authority` to be echoed on that command; an older client cannot run those controls without this fence.

Snapshot fields include `projectID`, monotonic `revision`, output lifecycle
labels, staged/program scene UUIDs, pending staged edits, staged layer visibility,
and macro progress. Events contain a full snapshot, coalesced to at most ten per
second. Capability changes also advance the revision; rediscover capabilities
when renamed/deleted targets change. Clients may request a fresh snapshot at any
time. The app does not queue commands for a disconnected client. A connection
that starts a macro owns that run; disconnecting or revoking it cancels future
steps. Reconnecting starts a fresh session and never resumes an old run.

Errors use stable codes: `versionMismatch`, `unauthorized`, `invalidRequest`,
`duplicateRequest`, `sessionLimit`, `malformedMessage`, `messageSize`, `rateLimit`,
`unavailable`, `invalidTarget`, and `invalidValue`. Response IDs match requests
when they could be decoded; unsolicited events and malformed-message errors do
not need an ID. Tokens are never included in responses or logs.

Limits: 8 concurrent connections, 16 paired clients, 65536 bytes per JSON frame,
60 requests per second per connection, 2048 handled request IDs per session,
10 seconds to authenticate, and 8 pending writes per connection. Oversize output
or a slow consumer closes the connection; clients should reconnect, rediscover
state and wait for a fresh user action. Bounds do not authorize replaying commands.

The sample client never retries a command automatically:

```sh
python3 apple/scripts/studio_local_control.py --credentials-file /path/outside/project/pairing.json --capabilities --search Scenes
python3 apple/scripts/studio_local_control.py --credentials-file /path/outside/project/pairing.json --snapshot
python3 apple/scripts/studio_local_control.py --credentials-file /path/outside/project/pairing.json --command 'scene.<UUID>.select'
python3 apple/scripts/studio_local_control.py --credentials-file /path/outside/project/pairing.json --subscribe
```

`--credentials-stdin` can read pairing JSON without putting a token in command
arguments. A nonzero exit reports rejection or connection failure and does not
retry. Store credentials outside project/repository files.

Run `apple/scripts/run_studio_local_control_harness.zsh` to exercise the actual
Network listener, framing, session security and pairing metadata using an
isolated credential backend and deterministic studio double. It checks native
wire authentication/version mismatch, stable-ID rename/delete, results,
subscription, request deduplication, reconnect, malformed messages, revocation,
remote macro cancellation, and shutdown. Build `StreamMac` for the actual
shared-dispatcher integration. Signed sandbox/Keychain and real hardware-plugin
flows still need validation on the installed app.

Optional snapshot fields now report normalized `values`, `mutes`, per-resource `playback`, staged group/global-overlay visibility, Program layer visibility, direct-live editing, and queued-comment/slot readiness and visibility. These are authoritative host values, not predicted tally or provider audience-delivery receipts. Oversize snapshots obey the same frame bound and close the connection rather than publishing a partial, misleading state.

D07 adds ephemeral capability `authority` (1–128 UTF-8 bytes), optional `bindingIntent` (`configuredSlot` or `currentConnection`) and `scope` (`project` or `studio`). Rediscover the exact capability for a fresh deliberate press; never persist authority or replay it. The native server compares current authority before execution. Configured guest-slot IDs deliberately survive a later rejoin, while a pending old press cannot mutate that replacement. Full-connection guest and chat-preset targets retain their captured lease. Only actual `show.<project>.profile.<profile>.select` capabilities with studio scope may cross the source profile context; the catalog lists the current show's complete saved profiles, not arbitrary cross-show targets.

Optional `guestSlots`, `showProfiles` and `audience` snapshot records report the saved slots/current member state, actual selected/requested profile, per-provider cached readings and native preset receipts. Requests accepted for profile switching are distinct from a completed runtime replacement. Audience readings expire after60 seconds and cached feedback after5 seconds without a native update; no provider polling or aggregate viewer total is invented. While subscribed, the server emits bounded one-second state updates even when no commands change.

Audience snapshots include every saved provider-bound destination in saved order, preserving the destination UUID even when its reading is unavailable or expired. The client accepts at most16,384 reading records and16MiB of audience JSON, within the global16MiB complete-response framing bound. Exceeding a supported bound rejects the response instead of silently truncating late destination keys. `scripts/run_studio_audience_projection_harness.zsh` executes the exact production mapper with65 entries and the final missing/zero/expired reading using data-only provider boundaries.
