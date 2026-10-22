# A full pool checkout does not prove arbitrary aliases are gone

The owned synthetic experiment on Mac15,8 / arm64, macOS 27.2 (26B118), Apple clang 21.0.0 falsifies a **general** private-bank refund oracle. A pool of four IOSurface-backed 16×16 BGRA buffers allowed all four simultaneous checkouts while a bare retained IOSurface or direct Metal texture still viewed the original backing. The checkout included that backing and overwrote its pixels. Refunding a bank solely because all four CVPixelBuffers can be checked out would therefore be unsafe for an arbitrary callback/SDK alias domain.

This demonstrates an ownership-contract limit, not a Core Video defect or recommended SDK usage. Apple explains that direct IOSurface/Metal users must maintain use counts to prevent recycling; the Core Video texture-cache route manages that interop while its wrapper remains alive through GPU completion. [Apple WWDC 2020, “Decode ProRes with AVFoundation and VideoToolbox,” around 20:54](https://developer.apple.com/videos/play/wwdc2020/10090/).

| Held owner after original wrapper release | Fixed four checkout results | Reused held backing / changed held pixels |
|---|---|---|
| CVPixelBuffer, with attachments stripped | 0,0,0,−6689 | No / No |
| CMSampleBuffer | 0,0,0,−6689 | No / No |
| Bare retained IOSurface | 0,0,0,0 | **Yes / Yes** |
| New CVPixelBuffer wrapping the same IOSurface | 0,0,0,−6689 | No / No |
| IOSurface with explicit use count | 0,0,0,−6689 | No / No |
| Direct Metal texture without use count | 0,0,0,0 | **Yes / Yes** |
| Direct Metal texture with explicit use count | 0,0,0,−6689 | No / No |
| CVMetalTextureCache wrapper | 0,0,0,−6689 | No / No |
| CIImage | 0,0,0,−6689 | No / No |
| Deferred CGImage | 0,0,0,−6689 | No / No |
| CMVideoFormatDescription metadata only | 0,0,0,0 | Metadata has no pixel ownership claim |
| Separate buffer attachment retaining original CVPixelBuffer | 0,0,0,−6689 | No / No |

Every case's after-actual-owner-release control acquired all four buffers successfully. All twelve APIs/cases were available in this run. `−6689` is Core Video's `kCVReturnWouldExceedAllocationThreshold`. No literal IOSurface/kernel identities or CF retain counts were logged; the artifact records identity booleans, full expected/observed visible bytes, return statuses and source/binary hashes.

The experiment uses one pool per case, the same threshold four on every allocation, four fixed probe calls with successful checkouts retained simultaneously, then four fixed control calls after explicitly releasing the real owner. Probes write a different owned pixel pattern and inspect held aliases before releasing the checked-out buffers. An independent unpooled reference supplies expected content, so reading a deferred image does not prematurely materialize the challenged pooled image. Manual Core Foundation lifetimes and scoped autorelease pools avoid mistaking a still-live local original for an escaped owner. No pool flush, polling, retry timing, codec, actual media, capture, UI or production output is involved. Metal cases construct owned texture views and read their bytes; this is not GPU performance qualification.

## Consequence for the source-isolation design

The result permits a **conditional** direction for sealed, correctly tracked CVPixelBuffer/CMSampleBuffer/IOSurface-use-count domains; it does not establish a universal drain predicate. Arbitrary callbacks may retain untracked surface views. Unknown SDK banks must remain charged or quarantined until their ownership contract and release proof are enforced. Callback return, stop acknowledgment, attachment removal or wrapper deinitialization alone cannot refund backing storage. The full isolation design still needs independent raw destination/encoding-group domains and admission receipts; one private pool for the existing aggregate Program publisher subscription would couple all its downstream raw destinations.

## Reproduction and receipt

From `apple`, the manual runner is:

```sh
python3 scripts/run_pool_drain_oracle.py --output build/pool-drain-oracle-reproduction
```

It compiles one Objective-C source with manual CF/ObjC lifetimes and executes one process under a 30-second runtime deadline. It does not retry a timed-out or failed experiment. Coordinate native slots before running it; no workflow invokes it automatically.

The original observed run used the retained source and `run_oracle.py` under `apple/build/pool-drain-oracle`, wrapped by the shared native-slot helper. The checked-in C source is byte-identical to that compiled source. The checked-in manual runner changes source/output path selection and was source-parsed, without executing the experiment again. Original wrapper log: `/tmp/stream-pool-drain-oracle-20261022.log`. The [machine receipt](POOL_DRAIN_ORACLE_2026-10-22.json) binds original raw content/status results, compile/runtime logs, binary, source and public SDK header hashes; 41 source/result assertions pass. One deprecated `CVBufferGetAttachment` compiler warning is retained. No production source or original qualification gate changed.
