# Manual static Twitch emote tiles

**Enable Manual Static Twitch Emote Tiles** defaults off for every workspace
runtime and is not persisted. On a newly accepted message from the currently
connected, authorized direct Twitch reader, **Show emote** displays the first
supported static emote in native chat. Its 32-point aspect-fit image has the
provider fragment's accessible label; the complete literal caption remains
selectable. This action works without a selected scene slot, including while
Direct Live Editing is on. It does not change staging or Program.

Separate **Stage Comment + Static
Emote** and **Stage Alert + Static Emote** buttons can load the first supported
static emote beside its complete public caption. The tile uses the existing
comment artwork area, with full alpha and aspect fit. It does not replace
Unicode, fragment text or literal braces with guessed images. Alert staging
still requires its separate manual-promotion opt-in and alert slot.

The actual EventSub fragment must include a bounded emote ID, set ID, text and
an explicit `static` format; its ordered fragments must reconstruct the exact
public message. Message text alone, Restream event labels, private events,
animated-only metadata and malformed identities cannot authorize artwork.
The existing direct reader makes an explicit metadata GET through its existing
account request and vault. Set zero uses Get Global Emotes; other sets use Get
Emote Sets with that exact set ID. No second provider account, OAuth flow,
subscription, application token or extra permission is created.

The response must contain one matching emote and the supported provider
image-template shape, plus explicit static/light/3.0 capabilities. These come
from the authorized response, rather than inferring an image URL from a name.
This follows Twitch's [emote handling documentation](https://dev.twitch.tv/docs/chat/send-receive-messages#handling-emotes)
and [Emote APIs](https://dev.twitch.tv/docs/api/reference/#get-global-emotes).
The existing reader bounds metadata reads to one in flight and at most one per
second, with a five-second request timeout. It refuses stopped, disconnected,
removed-message and retired-generation results; no automatic retry exists.

Only the exact HTTPS Twitch static CDN path is accepted. Queries, fragments,
credentials, custom ports, encoded/foreign paths and animated variants are
rejected. The ephemeral image session has no cache, credential storage or
cookies, denies redirects, and has five-second request/resource timeouts.
Only HTTP 200 image/png is accepted, up to 256 KiB, one PNG image and 512 pixels
per side. Native decoding downsamples to at most 112 pixels per side. At most
two artwork operations per workspace run across native chat previews and staged
slots. Cancellation immediately revokes their presentation tickets but retains
each operation's capacity until its actual resolver/loader call exits, so
opt-out/re-enable cannot overlap a new pair with canceled work still draining.
Thirty-two distinct static emote identities can be
retained for this app run; capacity refusal is visible before another fetch.
Repeated identities reuse immutable pixels. New identities never evict taken
Program artwork. The existing avatar cache keeps its separate bound.

Every staging tile action requires Direct Live Editing to be off. Download completion
can stage only the same accepted message, connected source epoch, workspace,
selected slot, exact original layer and unchanged author/platform/style intent.
Disabling tiles, provider changes, tombstones and shutdown cancel pending work.
Late results cannot mutate replacement content. Rejoin does not rearm old
message artwork; a new accepted message and deliberate action are needed.
Completion changes only staging; **Take** publishes it. Ordinary text-only
Show/Stage Alert clears the optional tile in staging. Hide and page changes
retain their existing Take behavior. Provider removal or disconnect does not
silently alter a deliberately taken scene card.

Native chat previews use the same current-message/source-epoch checks,
authorized metadata resolver, bounded PNG loader and in-memory image store.
They require an explicit click; neither message arrival nor opt-in starts a
fetch. Preview keys are ephemeral and bounded by the retained message queue.
Account replacement, connection changes, removal, opt-out and shutdown cancel
pending previews and clear their message-to-image keys. A late result cannot
restore a removed or retired preview, and rejoining does not authorize an old
message. Shared cached pixels can be shown again only by a deliberate action
on an eligible current message. Preview changes do not enter guest chat,
recording captions or scene persistence.

Pixels and opaque artwork keys stay in the existing in-memory comment store;
scenes carry no remote URL, image bytes, credential or provider write route.
There is no new layer type, shared Core/iOS schema or provider payload styling.
On app restart the ephemeral image is unavailable and the caption remains.
Guest public chat remains text-only; emote metadata and URLs never enter its
control protocol. Operator private messages are separate.

YouTube Super Sticker artwork remains unavailable: the documented
[LiveChatMessages API](https://developers.google.com/youtube/data/live/reference/rest/v3/liveChatMessages)
does not supply its image URL. Animated emotes, cheermotes, arbitrary remote
artwork, inline substitution and automatic arrival-driven promotion also remain
unsupported.

Local validation on 2026-10-21 runs the existing direct-chat and audience-event
harnesses. The shared-reader fixture checks actual fragment normalization,
metadata request/response predicates, local read rate and held late responses.
The whole-source audience fixture checks actual native Program pixels only
after Take, a non-square alpha PNG, literal Unicode/braces, distinct comment and
alert use, unchanged text-only guest wire, default-off/DLE/tombstone/source-close/
rejoin/shutdown fences, cache bounds and PNG format/dimension/byte rejection.
`TakenStaticEmote.png` is an owned synthetic pattern, not fabricated provider
artwork. An optional `STREAM_STATIC_EMOTE_PUBLIC_CDN_PROBE=1` also passed the
shipping loader against Twitch's documented public sample and writes
`PublicCDNStaticEmote.png`; this anonymous public resource check is separate from
an authorized chat-feed test. No live OAuth grant or external chat event was
used. Live provider authorization/order/rate acceptance remains open; these
software proofs do not close #139 or #143.

An independent rerun from integrated revision `29167ab` also passes the native
audience and shared-reader fixtures. Its artwork has a truly transparent
corner and a separate half-opaque green corner. Against an otherwise identical
render using an all-clear artwork image (same inset/text/card), the shipping
renderer preserves 12 exact backdrop pixels and 16 partly composited green
pixels inside the 21 × 10 non-square tile bounds. The earlier synthetic pattern
was fully opaque, so its aspect-ratio check alone did not establish alpha
preservation; this comparison supplies that missing evidence. The PNG remains
an owned local pattern, not an authorized live-provider result.


A completion review additionally reproduced and fixed two native defects.
An explicit Hide (including an already-hidden slot) or text-only Show/Stage
Alert now retires that slot's pending artwork operation. Exact layer equality
alone cannot represent a newer no-op operator instruction. Artwork completion
still uses the private guarded staging path, so it cannot cancel itself.
The recording archive now accepts the existing `Emotes` event kind and retains
its complete literal public caption. A real native movie writer plus the
production recording feed/archive/reader verifies both received-message and
visible-show records, including Unicode/braces, while excluding artwork URLs,
metadata and private token expansion. This remains owned fixture evidence,
not an authorized live Twitch chat-feed qualification.
