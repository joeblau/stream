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
Unsupported guest/comment notices are unavailable and have no executable command.

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
