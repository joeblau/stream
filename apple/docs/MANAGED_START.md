# Managed YouTube start review

`YouTubeStartReader` and `ManagedYouTubeStartCoordinator` form the native pre-publisher gate for explicitly managed YouTube destinations. The new sheet is a runtime view hook; the controller/runtime integration must route **every** managed start (toolbar, per-destination, retry, palette and adapters) through the same gate. Until that binding is integrated, these independent components do not change the existing publishing path.

The reader performs uncached authorized GETs through the injected account boundary. It verifies `channels.list(mine=true)`, the exact selected broadcast ID and channel, its bound stream ID, and the exact stream ID/channel/CDN profile. It reads the broadcast again after the stream so a changed binding cannot silently become a successful review. The review stores public IDs/title/privacy/schedule/lifecycle/auto flags/profile only; it contains no token, ingest endpoint or key and has no Codable representation.

Only fresh broadcasts with `ready` or `live` lifecycle and streams with `ready` or `inactive` state are eligible. Missing/deleted/foreign resources, incomplete/transitioning/terminal broadcasts, already active streams, unknown auto-start/stop flags, bad stream health and unsupported metadata remain blocked. `created` is not treated as ready. A future scheduled event requires the separate early-start checkbox. All starts require explicit acknowledgment of the exact reviewed event and sending-video effect. Auto-start false means an encoder connection followed by a deliberate external YouTube Studio transition; auto-start true can make sending video start the public broadcast immediately. Stream never calls a transition or changes the flags. It never describes an unknown flag as manual behavior.

The current managed route deliberately qualifies H.264 SDR / AAC through RTMP or RTMPS, at up to 3840×2160 landscape or 2160×3840 portrait, 60 fps, 1–4 second whole-number keyframes and 128 kbps AAC maximum. Fixed YouTube resolution/frame-rate settings must exactly match the landscape geometry and 30/60 fps. Portrait, square and custom layouts require a paired `variable` stream profile. Ultra-low latency above 1080p is blocked. These checks qualify the local policy only, not a live provider's acceptance; the controller still checks the actual Mac/transport/ingest/encoder budgets. YouTube documents other codecs, but this gate does not qualify Stream's enhanced RTMP implementation for them.

Confirmation performs a separate fresh ownership/event/stream read, validates the same reviewed binding, profile, schedule, lifecycle, privacy and flags, reads credentials, and rechecks the broadcast after that read. It requires an endpoint for the selected exact RTMP/RTMPS transport; it does not silently downgrade RTMPS. If any check fails, credentials never reach a publisher. The account request boundary must fence its workspace/session authority and actual credential generation before and after every GET. A final generation and exact destination/sanitized-settings comparison occurs immediately before the synchronous one-use host callback. Reviews expire after sixty seconds; operations have a thirty-second deadline and ten-second request timeout. Cancellation, deadline, account replacement or graph shutdown cannot revive a late review or credential read. Review queues are bounded at ten. No retry, POST, transition or persistent credential operation is in this reader/coordinator.

## Host hooks

The runtime owns one coordinator and binds its `generation` and `read` closures to the shared `ProviderAccountSession.recoveryAuthorizationGeneration(.youtube)` and `managedReadRequest(_:provider:expectedGeneration:)` helpers. Capture the account weakly and refuse absent/retired graphs. Observe its `managedReadRevision` for immediate review cancellation on authorization intent changes; the final generation fence is mandatory independently of that UI signal.

The controller supplies:

- `current(id)`: build `ManagedYouTubeStartContext(destination:settings:authorityRevision:)` from the current saved destination and freshly loaded settings, with `settings.outputProfile` set to the actual selected program/secondary canvas and authorityRevision set to the account's synchronous `managedReadRevision`. The constructor removes connection URL/key before storing this snapshot. It must also return nil while locked, rehearsing, closed, unavailable, or already starting/active, so final checks reject those changes. The synchronous revision check complements the async credential-generation fence.
- `publish(context, credentials)`: synchronously recheck the current context, rehearsal/lock/canvas availability, aggregate recording/publishing encoder reservations and `DestinationValidator.startErrors`. Recompute the complete active-destination encoding plan, adapt settings with these just-read credentials and only then allocate/start the publisher. Return false on resource/validation rejection. Do not suspend between validation and factory allocation, cache these credentials, or fall back to an old destination Keychain key.
- `startDestination`: if a provider binding exists, call `request(context)` before reading destination credentials or allocating any publisher and return after interception. A binding without a YouTube event remains blocked. Manual destinations get `false` from the gate and use their existing start path. Unsupported managed providers receive an explicit external/manual explanation rather than a guessed review.
- `stopDestination`: cancel that pending review before stopping its output. `stopStream`, lock/rehearsal/profile retirement and recovery replacement cancel pending reviews. Call `shutdown()` before retiring the runtime and when closing/quitting; call `cancelAll()` to abandon pending attempts without permanently retiring the graph.
- Present `ManagedYouTubeStartReviewView(coordinator:)` when entries are nonempty. Dismissal must call `cancelAll()` if the producer abandons the review. A retry uses `reviewAgain(id)` to capture current settings, not the old rejected snapshot.

Resource reservations remain the controller's responsibility. A reviewed destination does not reserve an encoder while the producer reads the sheet; the final synchronous callback must reject newly exhausted budgets before starting any part of that destination. Per-target reviews/failures stay independent; this feature does not introduce atomic multistream scheduling or an automatic retry policy.

## Reproducible software evidence

Run from the repository root with Xcode 26.6 selected:

~~~sh
DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer \
  zsh apple/scripts/run_managed_start_harness.zsh
~~~

This dependency-free generated Core test project runs seven production reader tests, then compiles the actual native coordinator and SwiftUI review sheet with its injected wire fixture. It proves fresh exact ownership and binding, metadata/profile/lifecycle validation, consent/future-schedule gating, one-use publisher-factory handoff, settings/account changes, noncooperative late review/credential responses, deadline, permission/offline/quota failure, explicit retry with current settings, resource refusal and bounded queues. No external requests, tokens, real publishers, camera/audio permissions or provider mutations occur. An unsigned full app build separately verifies integration of these source files; live authorized account/ingest behavior and production distribution remain separate gates.

## Current primary references

- [YouTube broadcast resource](https://developers.google.com/youtube/v3/live/docs/liveBroadcasts): lifecycle, ownership, binding, schedule, auto-start/stop and latency.
- [YouTube stream resource](https://developers.google.com/youtube/v3/live/docs/liveStreams): exact stream metadata, RTMP/RTMPS endpoints, resolution/frame-rate pairing and health.
- [YouTube encoder guidance](https://support.google.com/youtube/answer/2853702?hl=en): provider codec/frame-rate/keyframe guidance. The local conservative gate and fixtures do not establish live-service acceptance.

YouTube does not offer an atomic compare-binding-and-start transaction for an external encoder. Fresh checks bracket the key read and narrow races; an external Studio/operator change after the final GET remains outside this software proof. Other-provider scheduling, authorized live qualification and cross-provider partial scheduling acceptance remain open under #134.
