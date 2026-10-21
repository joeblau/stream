# Native audience event cards

The chat sidebar separates the existing public decoder's Text, Emotes, Super
Chat, Super Sticker, Membership, Milestone and Gift types. Native event badges
use distinct symbols and bounded local palettes. Ordinary text preserves Unicode
emoji; Twitch's Emotes label requires documented emote fragments. YouTube events
retain their documented public display text. No amount, reaction count, image
URL or additional subscription is inferred from that text.

Audience Events offers manual alert promotion, off at every session start.
Choose a separate alert slot and a palette for its event type, then use **Stage
Alert** on an accepted event. Promotion, page changes and hiding require Direct
Live Editing to be off; **Take** publishes each change. Event arrival, changing
a palette, enabling or disabling promotion, reconnecting, and reloading saved
preferences never publish or replace a card. Normal Text messages cannot become
audience alerts. The existing comment queue and comment slot remain independent.

Cards are native text layers. They include the supported event label, optional
author/platform and the exact provider text. Existing grapheme-safe readable
pagination handles long/Unicode text; each alert page is staged separately. The
original bounded message remains intact. Public brace text is literal and cannot
expand private title tokens. Native paint identities bind taken cards to the
existing optional recording-chat archive. Palettes apply only on the next
deliberate promotion; already staged or Program text keeps its chosen style.

Comment and alert slots share a maximum of sixteen saved IDs. Their sets are
disjoint, and legacy comment-only metadata still loads. Up to seven event palette
choices persist as allowlisted strings in the project-local `audience-styles.json`
(reads stop after 4 KiB plus one rejection byte); saved opt-in and automatic
promotion do not exist. A retired coordinator cannot promote, edit styles or
apply retained UI actions. Actual card
colors/text travel in the ordinary scene document. The existing queue/message
bounds and shared dispatcher/renderer resource limits still apply. Text-only Stage Alert
does not load avatars, stickers, emote graphics, audio, HTML or remote media.
Separate explicit static Twitch tile buttons are described in
[STATIC_TWITCH_EMOTES.md](STATIC_TWITCH_EMOTES.md); they are off by default and
also require Take.
Provider removal invalidates future promotion of that message; a deliberately
staged/taken card remains ordinary scene content. A warning directs the operator
to Hide and Take, avoiding an unsolicited output change.

Animated emotes, sticker artwork, reaction feeds and unsupported provider
events are unavailable here. Only the separately enabled static Twitch tile
slice supports provider artwork. This sidebar does not refresh viewer metrics from chat
payloads. Existing authorized provider-account readings in Destinations have
their own capability and freshness checks; no combined count or unique-person
claim is made by these cards. Adaptive/animated event media and additional
provider permissions or subscriptions require separate implementation and
qualification.

Local software validation on 2026-10-21 uses
`apple/scripts/run_audience_events_harness.zsh`: shipping public decoder,
coordinator, dispatcher, renderer and project metadata with owned temporary
storage/defaults, nil credentials and refused desktop transport/capture. It
checks actual Program pixels before and after Take, a native PNG and recording
paint identity, literal braces/Unicode, off-by-default and direct-live guards,
separate/shared-capacity slots, staged Hide/pages, removed-event refusal,
oversized preference refusal, stale-session fences, and palette reload without
rearming. `run_studio_chat_harness.zsh` checks supported
classification/filter bounds; the direct-chat fixture checks actual public
YouTube event and Twitch emote normalization through the provider adapters.

No authorized live provider feed, real OAuth grant or external audience event
was used. Live ordering/rate/permission acceptance and actual presentation from
authorized test feeds remain open, as do viewer counts and unsupported remote
event media. The static Twitch tile document records its separate local proofs.
These local proofs do not close #143.
