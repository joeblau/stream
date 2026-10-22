# Browser helper coexistence: capture-owner acknowledgments

The independent browser route remains disabled. This change supplies missing
software coordination for supported system-mix and pinned display filters; it
does not qualify a signed launch, SCK attribution or a live simultaneous capture.
Program/Preview/Hide demand and mixer registration already existed.

The pool now inventories every requested screen/app-audio owner **and** owners
whose old capture is still retiring. A bundle name in settings is insufficient.
The helper receives a live permit bound to the owning pool/runtime, session,
actual helper PID, current Program page leases and each capture-owner revision.
Missing owners, pending starts/filter updates, failed cleanup, permission loss
and old helper PIDs cannot authorize playback. Distinct capture keys feeding the
same application channel retain separate owner/operation boundary tokens; old
cleanup cannot release a newer handoff or leave its replacement channel closed. The session checks the permit
before its capture start, before every page Resume and immediately before opening its
mixer gate. Source changes revoke that authority synchronously.

For the system mix and pinned display app-exclusion filter, the capture owner
looks up the exact live helper PID/bundle in current shareable content and
awaits the actual SCStream `updateContentFilter`. It preserves the existing
stream/video geometry and unrelated application selection. Only the affected
source's audio delivery authority closes during this handoff: no saved fader,
mute, solo or other channel changes, and no unrelated source is stopped. An
already-entered callback completes on its original serial sample queue. The
owner fences that queue, then resets its own mixer rings, converter, meter and
insert signal history before issuing a current installed receipt. Deferred
main-actor screen-audio callbacks also retain their original delivery epoch.

Retirement invalidates callback ownership immediately and waits for an entered
SCStream start, exact stream stop, sample-queue fence and mixer-history reset.
Stop failures retain the old stream for cleanup retry; they are not receipts.
A replacement start waits for that retirement. An actual current-stream stopped
delegate is already a stop acknowledgment, and still takes the queue/history
barrier. Old completions cannot change a replacement owner's revision. A new
valid owner/helper/demand generation can recover without rebuilding the helper
session; removal from scene demand alone does not prove retirement.

Opaque sharing-picker filters, pinned window/application screen selections,
explicit-window display filters and direct helper-app recapture remain explicit
conflicts for audio-bearing routes. A static window list cannot prove exclusion
of future helper windows. Audio-disabled screens and separately selected other
application-audio filters are disjoint only after their actual start receipt.
No conflict is repaired by capturing System Mix as the helper or stopping an
unrelated source.

## Controlled evidence

`run_browser_exclusion_harness.zsh` compiles the real capture classes, production
transaction and full AudioMixEngine against an explicitly supplied matching
StreamCore framework copied into its owned build directory. It starts no SCK,
helper, UI, audio device, mixer clock, publisher or output graph. Held external
install/stop/history operations verify ordering, old-owner/demand/PID rejection,
failed cleanup, fresh-generation recovery, same-owner rapid retire/re-demand and
single-owner Stop after a held start completes late. An actual serial callback enters
the real mixer insert while retirement begins: history cannot reset until it
returns. Explicit production mix reads then require zero old source PCM,
unchanged unrelated 0.3 PCM, and fresh source PCM at its preserved 0.5 gain.
The same-file generated accessor calls the production mix operation; it does
not alter routing, PCM or shipping source.

The existing command-only helper harness additionally holds the inert capture
driver's start. Retiring its permit must prevent actual session Resume; a new
current proof recovers, and a different helper PID is refused. Another case
retires the proof during the first page's Resume acknowledgment and refuses
Resume for its sibling. Its legacy
bundle-set fixture API now compiles only with `STREAM_NATIVE_VALIDATION`; the
production pool always supplies owner permits.

The [frozen receipt](BROWSER_CAPTURE_EXCLUSIONS_2026-10-22.json) records the
separate compiled-source sets and original log hashes. Earlier compile/test
failures remain retained and are not relabeled as successful executions.

Whole-source compilation is checked separately with the capture-authority
runner's `BROWSER_CAPTURE_AUTHORITY_BUILD_ONLY=1`. No helper/capture qualification
runs in that mode. Frozen local logs and hashes are recorded with the owning
change. These controls do not substitute for real every-route recapture,
WebKit attribution/tails, signed shared-container access, speech/live A/V,
permissions or device acceptance. Helper local HTML/subresource access is still
unimplemented. `productionRouteQualified` stays false and #124 remains open.
