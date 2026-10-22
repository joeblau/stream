# Guest return frame delivery

Program, Secondary and Clean guest returns use the same independently backed
delivery banks as other raw outputs. One synchronous transaction admits the
engine's source bank of four, a private ingress bank of five, and each eligible
adaptive encoder raster before installation can expose video. The five ingress
slots cover one pending broker frame, its callback, the sender's pending frame,
the active encode and the incoming transfer. Each conversion raster has two
slots. Identical small rasters share one bank; no source is upscaled.

The existing low/balanced/high profile ceilings, even raster dimensions, source
PTS/duration, RTP conversion and cadence remain in use. Conversion writes into
the admitted bank instead of creating an unbounded buffer per frame. A full
conversion bank raises a distinct counted capacity error and follows the
sender's existing local failure/retirement path. It is not ordinary cadence
shedding. Direct owned encoder callers also admit their conversion banks before
creating VideoToolbox.

Startup awaits the authoritative geometry command and an exact installation
lease. Source-bank ownership moves into the engine; stale caller receipt copies
cannot close it. Cancellation revokes a pending ticket synchronously. A stale
ACK cannot adopt or remove a replacement. Same-token reentry is refused before
acquiring an encoder reservation. Delivery cleanup still runs when its weak
controller has retired.

An unsuccessful late install ACK leaves source removal to the codec owner.
Stop revokes send authority immediately, then the serial sender closes VT before
removing the source and releasing its encoder reservation. Neither the sink's
late-ACK guard nor the sender's stale-prepare guard performs an early removal.

The owned resource fixture compiles the actual encoder, resource planner,
coordinator, broker and converter against the full StreamCore framework. Only
the exact production value declarations needed by that fixture and the pure
packet-cost function are extracted; no receiver or RTC transport is linked.
Generated BGRA input produces actual low/balanced/high H.264 packets with the
original RTP PTS, expected dimensions and duplicate rejection. A held capacity-two
bank raises its typed error before VT creation. Direct-call admission and exact
pending/replacement ownership also pass. An initial mismatched in-flight
camera-header compilation failed before execution and remains retained.

The separate [actual sink fence proof](GUEST_INSTALLATION_FENCE.md) verifies a
successful ACK after revocation, exactly-once explicit owner cleanup and
replacement protection. Restoring only the old removal guard fails that same
assertion. It constructs an idle mixer value only; no mixer run, codec, sender,
receiver, capture, device or network graph is started in that sink proof.

[The receipt](GUEST_RETURN_FRAME_DELIVERY_2026-10-22.json) binds the five passing
resource/VT cases and the independent reviews. The sender's serial ordering is
source reviewed; it is not an executed RTC lifecycle claim. Whole controller
compilation belongs to the combined integration gate. These bounded generated
inputs do not qualify live guest A/V, installed devices or sustained workloads.

With matching integrated sources and full Core products, run:

```sh
python3 apple/scripts/run_guest_return_resource_harness.py \
  --core-products /path/to/products --output /path/to/new-proof-directory
```

The runner retains exact source snapshots, extracted declarations, compiler
commands, executable and logs. It runs no transport and does not retry a failed
experiment. Coordinate the shared native build slots before execution.
