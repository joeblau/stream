# Deliberate broadcast ending

Reviewed against current primary documentation on 2026-10-02. Open **Destinations → Stop Local / End Remote / End All**. The controls require a bound retained workspace runtime. Every ending action is an explicit operator decision; disconnect, transport failure, project recovery and account authorization never complete remote events automatically.

| Action | Local publisher | Remote provider | Recording |
| --- | --- | --- | --- |
| Stop Local / Stop All Local | Detach the selected captured publishing sessions and await publisher stop acknowledgment | No completion API request; a provider can still apply its own ingest-disconnect/auto-stop policy | Continues |
| End Remote | Continues | Fresh ownership/state verification followed by one supported permitted completion request | Continues |
| End Both / End All | Stop each captured session independently after its remote result or bounded timeout | Attempt each supported event independently; unsupported or uncertain results remain explicit | Continues |
| Review Remote / Review Local Receipt | No new local stop | Remote review reads state only; local review reads the original stop receipt | Continues |

## Provider authority and receipts

YouTube completion requires an actual granted `youtube` or `youtube.force-ssl` scope. Immediately before the mutation, Stream reads the selected broadcast, checks that its channel matches the destination binding, and requires live state. It sends `liveBroadcasts.transition` with `broadcastStatus=complete` once and accepts completion only when the returned event ID/channel match and `lifeCycleStatus` is `complete`. An already ended/revoked event needs only the fresh read. Upcoming events are neither deleted nor started as an ending substitute. The documented transition, scopes, response and errors are defined by [YouTube liveBroadcasts.transition](https://developers.google.com/youtube/v3/live/docs/liveBroadcasts/transition); fresh state uses [liveBroadcasts.list](https://developers.google.com/youtube/v3/live/docs/liveBroadcasts/list).

Remote review also works with a granted `youtube.readonly` scope. Account replacement, logout or shutdown invalidates pending work before every subsequent request and ignores late receipts. Missing grants, ownership, current state or quota authority block the completion. Rate failures install the account cooldown. Mutations never retry automatically. [YouTube broadcast status fields](https://developers.google.com/youtube/v3/live/docs/liveBroadcasts#status.lifeCycleStatus) define the returned lifecycle state; a fresh local publisher acknowledgment is a separate observation.

Twitch, Restream, Facebook Pages, LinkedIn Live and ordinary custom destinations have no verified remote-completion operation implemented in these connectors. End Both/All still stops their local sessions and reports **Unavailable · manual provider action required**. This is a connector capability gate, not a claim that a provider can never offer another authorized control. The current [Twitch API reference](https://dev.twitch.tv/docs/api/reference/) and [Restream event API catalog](https://developers.restream.io/events) are the primary boundaries researched. Stream does not substitute Restream channel removal or destination toggling for ending the actual downstream event; [Restream's MCP documentation](https://developers.restream.io/mcp-server) distinguishes its own state changes from destination-platform changes.

A lost reply, invalid completion response, cancelled sent request or remote deadline produces **Unknown · completion not confirmed**. A failed preliminary check says no completion was sent and leaves remote state unknown. Receipts include their local arrival time and become visibly stale after 60 seconds. Review Remote performs a fresh read; an explicit retry is a separate operator action. Multiple outputs bound to the same provider/channel/event share one completion request within an ending plan. Different events retain independent results: one failure does not prevent another event ending or local publishing stopping.

Targets capture the metadata and unique session token actually used when their publisher started. Editing a saved destination for its next start cannot redirect the running session's ending request. A replacement session with the same destination ID cannot be stopped by an older plan. Local stop detaches media immediately, but reports **Stopped** only after the actual publisher acknowledges stop. A ten-second local receipt deadline leaves **Stop unconfirmed**; Review Local Receipt can observe a later acknowledgment without issuing another stop. Repeated disconnect while a stop is pending does not fabricate idle state. Recent acknowledged tokens are bounded to 128; expired receipts require ordinary state review.

## Optional outro through the shared scene path

End All can select an existing saved outro or black scene, take it through the shared **Select Scene → Take** dispatcher, wait for the configured transition to finish, and hold for a minimum of 0–120 seconds before the remote/local ending phases. Take or revert pending staged edits first. A black scene with an existing fade transition uses that normal transition path; this feature does not introduce a second renderer or fade engine.

The delayed plan captures the Program publication revision and every selected publisher session/binding. A new Program publication, an output replacement/routing change, workspace shutdown or lifecycle cancellation aborts the delayed ending. Moving away and back to the same scene still changes the Program revision. A transition that never completes times out after 30 seconds. Provider completion can extend the visible outro beyond its minimum hold. The continuing local recording also receives the selected scene. No plan or command is persisted or replayed after restart.

## Retained runtime hooks

After creating the retained controller, account session, dispatcher and Preview/Program model, root workspace integration calls once:

```swift
controller.bindEnding(accounts: providerAccounts,
                      dispatcher: dispatcher,
                      previewProgram: previewProgram)
```

Call `controller.ending.cancelPending()` on sleep/session interruption and `controller.ending.shutdown()` before workspace switch/close. Shutdown removes observers and authority; constructing a new runtime does not resume an old plan. The binder cancels pending macros before a deliberate local stop and uses `DestinationOutputController.stopIfCurrent` for the captured token. Its boundary has no recording-stop operation. The root lifecycle policy can independently drain recording on sleep; that is distinct from deliberate broadcast ending.

## Validation and remaining acceptance

`ProviderAPITests` verifies fresh ownership, one-shot completion, matching acknowledgment, already-ended reads, upcoming-state rejection and uncertain lost replies. `apple/scripts/run_provider_accounts_harness.zsh` drives the production native account session and credential vault with memory/HTTP fixtures: real granted-scope gates, read-only review, account cache receipts and logout between the fresh read and mutation. It never reads the operator's provider credentials.

`apple/scripts/run_studio_ending_harness.zsh` compiles the production output controller and ending coordinator under Swift 6. Injected publishers and HTTP verify actual local acknowledgment, immutable active routing, healthy peers, late-stop receipts, stale session refusal, remote-only delivery continuity, unsupported/partial remote results, shared-event deduplication, cancelled late replies, timed-outro cancellation and successful timing. The full native app build checks the actual Select Scene/Take and transition binding. The existing destination lifecycle harness remains the regression check for independent supervision.

These are local software fixtures. No real provider mutations or messages were sent. Authorized YouTube event completion, public ingest and partial-stop acceptance, and visible native Program/recording acceptance remain required before claiming issue #135 complete. Provider scheduling issue #134 still has thumbnail/privacy editing, YouTube stream create/bind, broader scheduling/destination-selection workflows and authorized provider acceptance gaps; this change does not claim them complete.
