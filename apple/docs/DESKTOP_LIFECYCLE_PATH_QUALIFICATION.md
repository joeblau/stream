# Desktop lifecycle and route callback qualification

The original issue #158 asks for independent multi-output reconnect, visible
configured source failover, and documented handling of lock, sleep/wake,
display removal, permission revocation and network change without surprise
publishing. It does not promise universal provider or device support.

Run the existing owned-source fixture and its optional real transport case:

```sh
STREAM_VENDOR_ROOT=/path/to/clean/Vendor \
FAILOVER_NATIVE_BUILD_PATH=/tmp/owned-resilience-derived \
zsh apple/scripts/run_source_failover_native_harness.zsh

STREAM_VENDOR_ROOT=/path/to/clean/Vendor \
FAILOVER_NATIVE_BUILD_PATH=/tmp/owned-resilience-derived \
zsh apple/scripts/run_source_failover_native_harness.zsh --path-supervision-only
```

Each invocation bounds its child to 60 seconds and retains its own artifacts.
The transport case requires an FFmpeg receiver advertising RTMP and SRT (the
same `STREAM_FFMPEG_BIN` override and exit-77 prerequisite as the original
shared-encoder fixture). Only the exact receiver processes it creates can be
interrupted. All listeners and publishing endpoints are owned loopback. The
fixture uses generated frames/PCM, temporary defaults and memory credentials;
it changes no network interface, TCC setting, system sleep/lock state or account.

## Lifecycle ordering

The shipping coordinator now treats wake and unlock as ordered capture gates.
A locked wake records the optional preview intent, refreshes no source and
starts no preview. Unlock permits that preview, but never publishing or
recording. An unlock delivered before wake leaves capture retired until wake.
Duplicate/unmatched wake and unlock events are ignored. A late lock after
sleep does not reconstruct a slate or repeat teardown.

The native destination-controller harness checks both orderings, duplicated
signals, preserved publisher allocations and persisted policy. Its new
assertions fail against the original coordinator because unmatched wake
refreshes sources. The actual owned-source controller/renderer/mixer/recorder
fixture also checks locked wake, duplicate wake and duplicate unlock, in
addition to all original fourteen painted source/scene windows, nine PCM
cases, private-slate silence, strict track endpoints and runtime retirement.

## Route supervision

The RTMP callback previously awaited the entire reconnect loop from its
`NWPathMonitor` iteration when a restored route found a detached output. A
second route loss then stayed queued behind reconnect. RTMP handoff recovery
also inherited the debounce task that the next update cancels. SRT already
has a separate recovery task for these cases.

RTMP now owns path-triggered recovery separately. The task is installed before
it runs, coalesces pending requests with the existing single-flight guard,
clears after completion, and is cancelled by explicit stop. The path consumer
and debounce tasks remain available to process subsequent updates.

The optional fixture replaces only `NWPathMonitor` snapshot delivery in its
generated copy of the shipping RTMP source. It runs the real callback,
backoff, publishers, shared H.264/AAC encoder and two FFmpeg sockets. Its
metadata → loss → restoration → loss during reconnect → restoration sequence
must consume the second loss within a one-second deadline and
recover RTMP to a replacement receiver. The healthy SRT publisher must retain
its original start acknowledgment, with exactly two publisher allocations and
one shared encoder throughout. Late updates after acknowledged stop cannot
restart output.

All three actual files keep the original track/endpoint checks; the original
strict A/V sync checks remain enabled for the first RTMP and continuous SRT
files. Every decoded SRT cadence step, independent early/late source cue and
original source tail is checked. No tolerance, source timestamp or output
deadline was relaxed. The original RTMP source fails precisely at the
one-second second-loss-consumption assertion with this same real fixture.

Local qualification uses Mac15,8 / Apple M3 Max, macOS 27.2 (26B118), Xcode
27.2 (27B5038j). The source fixture decoded 310 frames over 10.36842 seconds;
both private windows have PCM RMS zero. The route fixture retains 392
continuous decoded SRT frames over 15.67999 seconds, source flashes at
0.24/11.71999 seconds (the unchanged 11.48-second separation), and final video
PTS 15.63999 seconds. Both actual RTMP segments decode and all strict checks
pass. Receiver input/output-error messages at deliberate close are retained.
The final source regression on the RTMP fix also passes all original checks,
decoding 308 frames over 10.335 seconds with both private windows silent.

## Original acceptance coverage and limits

Independent reconnect/backoff with a healthy surviving output and configured
freeze/blank/offline/standby-source/standby-scene rendering have real socket or
decoded media evidence. Lock and sleep/wake resume policy is exercised through
shipping callbacks and actual recorder/capture/render teardown. Network-change
policy is exercised through shipping callbacks and real reconnecting sockets.

These controlled events do not measure OS delivery of physical lock/sleep,
display removal or TCC revocation, nor an actual interface handoff. The base
fixture does not execute permission-transition or display-removal callbacks.
Its optional `--permission-transitions` mode now qualifies screen/microphone
retirement, regrant, transient-error classification and stale discovery
completion with owned producer/discovery boundaries and actual decoded media.
The 22-phase recording additionally verifies independent permission-recovery
ownership and nonblocking diagnostic sampling during a controlled microphone
history drain, with its original five-second deadline;
see [the measured source qualification](SOURCE_FAILOVER_NATIVE.md).
Display-removal and camera-permission callbacks still need focused evidence
before claiming all of issue #158;
physical devices or Internet/provider tests are qualification limits, not new
universal acceptance requirements inferred from this fixture.
