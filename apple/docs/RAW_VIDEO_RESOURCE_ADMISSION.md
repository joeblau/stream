# Raw video resource admission foundation

This is accounting and owned-pool infrastructure for the frame-delivery broker.
It is not a claim that all existing output paths have been migrated or that
hardware throughput, capture, public broadcasting or SDK behavior is qualified.

The explicit admission ceiling uses the same numerical amount as
`StreamCapability.desktopPreviewFootprintBudget`: RAM/5, bounded to 256 MiB–4 GiB.
It is a **separate conservative software policy**. Before admitting storage:

```
fresh actual process physical footprint
  + ALL committed raw-bank ceilings (prepared, active, retired, quarantined)
  + proposed additional backing
  <= admission ceiling
```

Resident raw bytes are intentionally counted again. This is not free RAM, a
process hard cap, a bound on codec/GPU/framework scratch, or a hardware capacity
certification. Unknown or older-than-two-second measurements deny new admission
without changing existing outputs. Existing encoder, geometry, disk, workload
and availability gates remain authoritative.

`RawVideoResourceCoordinator.shared` survives controller/workspace changes. Each
bank belongs to a stable logical domain, an exact descriptor and an activation
generation. A repeated request can reuse the SAME active-session bank; a restart
or different geometry cannot reuse unknown old backing. Exposed banks remain
fully charged after retirement, even when all visible sample references return.
Bare IOSurface/Metal aliases invalidate generic all-buffer checkout refunds.

Synchronous `reserveBatch` precedes writer/publisher factories. One global native
pool probe runs at a time; its 64 MiB provisional credit is included in the same
ceiling. The actual pool is measured from CV data size, every plane's stride and
height, and IOSurface allocation size. The largest backing measure determines
its charge. The existing queue eviction basis (`CVPixelBufferGetDataSize`) is
kept separately as `queueCostBytes`: Program recording needs Q+5 with generic
delivery pending2/callback1/native1/incoming1, while direct ISO uses Q+2. No
unaccounted probe pool remains beside the admitted bank.

The batch commits only after all candidates pass and a fresh final footprint
measurement succeeds. There are at most 256 banks, 32 active/waiting preparation
calls, and 32 ownership claims per bank. Rejections insert no history records.
These are finite software metadata limits, not measured hardware performance.

Every native buffer is allocated through the bank's threshold-enforcing method;
the underlying pool is private. Exposure is recorded before a buffer returns.
After that transition, the active frame path avoids the global admission lock.
Pool closure revokes new allocations, drains already-admitted allocations,
detaches the actual native pool, and only then refunds a never-exposed bank.
This works even when stale receipts retain the bank object. Closure never waits
while holding the coordinator policy lock.

Receipts have authoritative per-bank claims. Independent preparations sharing
one active bank cannot cancel each other's ownership. `selecting(domain:)`
atomically transfers a domain claim to a new child receipt; stale copies of the
parent cannot roll it back. An adopted source bank therefore needs an
Engine-owned transferred receipt. A private endpoint must not retire a shared
source bank. Installation still needs the broker's asynchronous acknowledgment
before media starts; this foundation does not replace that barrier.

The focused proof uses only owned 16×16 CoreVideo pools, actual process
measurements, semaphores and generated synthetic identities. Eleven pure tests
cover atomicity, stale/unknown measurements, overflow, backing/queue-cost
separation, metadata bounds and restart quarantine. The native proof covers
retained receipts, independent owners, transferred claims, real threshold
exhaustion, explicit retirement and a held allocation versus rollback. A held
global policy transaction also verifies that an already-exposed healthy bank
can allocate before that transaction is released. No renderer, SDK, capture,
device, network, window, permission or output graph is constructed.

Run the Core test suite normally, and run the owned native proof using matching
built products:

```sh
RAW_RESOURCE_CORE_PRODUCTS=/path/to/products \
zsh apple/scripts/run_raw_video_resource_harness.zsh
```

The retained local receipt distinguishes the minimal actual-source Core module
used for this focused proof from a full application/Core build:
[RAW_VIDEO_RESOURCE_ADMISSION_2026-10-22.json](RAW_VIDEO_RESOURCE_ADMISSION_2026-10-22.json).
