# Guest return installation cleanup fence

The actual `NativeGuestMediaSink.installReturnVideo` can receive a successful
installation ACK after its token was revoked. That late ACK must return false
without removing the source: a previously delivered frame may still occupy the
serial codec owner. The owner's queued codec close remains responsible for
calling `removeReturnVideo`, which removes the exact old source once. It must
not remove a replacement token's source or release its reservation.

The focused fixture compiles the actual sink, video store, media receipts,
return-resource types, complete `AudioMixEngine`, and immutable recording/model
dependencies. Capture identities are exact production value declarations copied
from `LayerGraph` and `CaptureSourcePool`; the capture-pool class is not included.
There are no fake audio engines, receiver types or replacement media models.

At runtime it constructs only the actual mixer actor's empty registry and
scratch arrays, the actual video store/lease and sink, and controlled asynchronous
source callbacks. It does not call the mixer's `run`, register an audio guest,
add a channel, create PCM, instantiate DSP, or create a codec, sender, receiver,
RTC peer, capture, device, window, preference or network graph. Compiled recording
classes and resource coordinators are not instantiated.

An actor holds the actual source-install ACK while the test revokes the old
token and successfully installs its replacement. Releasing the old ACK returns
false with **zero** source removals. Explicit controlled codec-owner cleanup then
causes exactly one removal. Repeating old cleanup leaves the replacement
current. A second case closes the actual sink during installation and verifies
the same delayed-owner cleanup rule.

The negative executable uses the same harness and all the same dependencies.
Its only source change restores the old guard's early `await source.remove`.
It reports one premature removal and fails the unchanged assertion. Both
executables have a 45-second outer deadline.

```sh
GUEST_INSTALLATION_CORE_PRODUCTS=/path/to/matching/full/Core/products \
zsh apple/scripts/run_guest_installation_fence_harness.zsh
```

When the production sink/resource files are in another reviewed worktree,
`GUEST_INSTALLATION_NATIVE_SOURCE_ROOT=/path/to/worktree/apple` selects only
those two actual files; every other dependency remains the immutable local
source. The runner records origin and snapshot hashes and retains both native
logs and generated sources. It does not build a Core framework or the full app.

The local positive and old-guard negative both reached their intended results.
See [GUEST_INSTALLATION_FENCE_2026-10-22.json](GUEST_INSTALLATION_FENCE_2026-10-22.json)
for exact source, framework, executable and log bindings, including the initial
missing-value-declaration compile failure. The actual sender's corresponding
no-early-removal fix was source-reviewed only. This fixture does **not** qualify
sender execution, VideoToolbox draining, the full controller, RTC, return-media
delivery, hardware behavior or any issue's complete acceptance criteria.
