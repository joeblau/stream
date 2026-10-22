# Resource baseline for each performance case

The performance fixture now resets and primes its existing resource sampler immediately after the original `started = clock.now` boundary, before creating the replay/audio tasks. The priming snapshot is discarded. The next retained sample derives its CPU delta from this case's process observation, rather than the preceding case's finalization and decode inspection.

This adds one existing sampler observation inside each original measured window. It does not move/restart the 600-second clock, change the 12-layer 1080p30 static/replay scenes, PCM producer, healthy/80ms sinks, real writer, resource heartbeat, nominal thresholds or deadlines. PCM construction is unchanged.

The original e41 archived `performance.json` records demonstrate the previous-state bleed:

| Original archive | First replay sample interval | CPU delta | Logical processors | Reported fraction |
| --- | ---: | ---: | ---: | ---: |
| ARM 12459150758 | 34.466146999999864s | 25.244643999999994s | 3 | 0.244149174357475 |
| Intel 12459625011 | 104.15071918800004s | 39.01825299999996s | 4 | 0.09365814586831854 |

Each fraction equals the cross-case CPU delta divided by elapsed time and logical processor count. The retained original JSON SHA256 values are `427df745b8a629df1c38dba2e6ab21564670dfaaff7a22e713efd6f5f52bf9bb` (ARM) and `821616b75b5b8efbb36f468c7345d8a91e7ba2efe82043be86d808caad175555` (Intel). The archives and their records remain untouched.

Source review follows the actual collector: `reset()` clears `previous`; the unreported `sample()` replaces it with the new observation; the first retained sample uses that observation in the existing delta formula. This is a source/control-flow argument, not a simulated timing test or a post-change measured value.

Validation is limited to Swift 6 parsing, whitespace and exact source comparison: only the comment and two sampler calls were added to the original fixture. No native workload, movie generation or 600-second benchmark was run for this correction. A later integrated fixture compile/run must establish actual results. This reporting correction makes no claim to repair missed compositor deadlines or satisfy #92.
