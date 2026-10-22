# Release the unused raw-publisher repeat cache in Program mode

Both raw publisher actors retain their latest video sample for legacy static-capture repetition. Their existing repeat guards already reject repetition after the first accepted Program audio buffer, because the compositor supplies Program's static-scene cadence. The cache was nevertheless retained when entering Program mode and replaced by every later Program video sample. It could therefore pin one compositor pixel buffer per raw publisher without serving the repeat path.

`RTMPPublisher` and `SessionPublisher` now clear that cache when they first accept Program audio, before the existing mixer-configuration await. Their video append paths retain a repeat sample only while Program audio mode is false. Rejected Program calls do not change mode or cache ownership. Legacy capture repetition, video admission, timing normalization, monotonic PTS enforcement, encoder/mixer call order and repeat guards are unchanged.

## Focused lifetime proof

The fixture compiles each whole production actor with the real SDK types. Its generated copies replace four selected mixer media effects with inert, nonretaining metadata receipts and add same-file private setup/inspection extensions. SessionPublisher's actual stream-presence guard uses an inert `StreamConvertible` actor whose methods trap if unexpectedly called. No publisher start, socket, encoder, audio device or capture operation runs. The actual actor append/repeat methods, sample buffers, normalizer and admission code remain in use.

Each lifetime probe owns a real one-buffer Core Video pool. Legacy append must prevent another allocation from that pool; legacy repetition must append one later-timed sample; replacing or clearing the cache must make the original pool reusable. This tests actual pixel-buffer ownership rather than merely inspecting an optional property.

The existing legacy restamp helper explicitly gives repeated samples an unspecified duration. The fixture records that validity separately and preserves it, while requiring the repeat PTS to advance. Ordinary Program video retains its original numeric frame duration.

For Program entry, stopped, paused and encoded-input calls must retain the legacy cache and leave mode unchanged. The accepted call then suspends at its existing mixer-configuration await. While that await is held, the actual actor must already be in Program mode with no cache, and the previously pinned source pool must be reusable. The test also checks configuration/audio order and actual normalized audio time. Subsequent Program video must retain its original admitted PTS and duration, leave no repeat-cache ownership, and keep repetition disabled.

Two separate negative builds remove one production fix at a time. The entry-negative removes only the first accepted Program cache clear. The future-negative restores only unconditional video caching. Each build runs both actual actors against the unchanged corresponding assertion. Continuations determine the configuration boundary; no sleep or retry decides the result.

## Executed evidence

On arm64 macOS 27.2 (26B118), all three variants built against fresh matching Core source and an independently owned pinned SDK checkout. The final positive tool passed legacy, first-entry and future-frame cases for both actors. All four negative child processes failed their exact expected ownership assertion, with observations saved before failure. The [receipt](PUBLISHER_PROGRAM_REPEAT_CACHE_2026-10-22.json) binds source, generated actors, binaries, observations and original logs.

Run through the shared two-slot reservation, with owned dependencies:

```sh
STREAM_VENDOR_ROOT=/path/to/owned/vendor \
  zsh apple/scripts/run_publisher_repeat_cache_harness.zsh
```

The runner builds and runs the entry-negative, future-negative and positive variants sequentially with `xcodebuild -jobs 2` and Swift `-j2`. Child runtime deadlines bound a broken fixture; they do not determine the lifetime assertions.

Two earlier failures remain retained. The first compile required two inert fixture protocol callbacks to be `nonisolated` under Swift 6. The next run reproduced all four intended negative failures, then rejected the fixture's incorrect expectation that legacy restamping preserved the input duration. The actual unchanged helper specifies `.invalid`; the corrected fixture requires that existing behavior explicitly. No production timing code, source-pool threshold, Program duration check or ownership assertion was relaxed.

## Scope

This work addresses only the unused repeat-cache ownership. It does not identify the owners in earlier hosted renderer-pool exhaustion, revoke raw buffers retained by another consumer, prove opaque SDK/VideoToolbox release, establish full output isolation or qualify sustained frame rate/A/V performance. Original issue #92 remains open. Native integration compilation of both shipping app targets belongs to the parent validation cohort.
