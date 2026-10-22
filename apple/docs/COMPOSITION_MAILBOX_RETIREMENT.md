# Retire pending compositor frames when a sink ends

Removing or replacing a sink now closes its actual compositor mailbox. Close linearizes with admission and dequeue under the existing lock, detaches pending frames, and releases them after unlocking. An already-dequeued callback can finish; shipping removal never waits for it. A closed mailbox refuses later posts and cannot drain its retired backlog. Replacing a token on the same canvas closes that canvas's previous mailbox; registering the same token on another canvas preserves the existing independent registrations. Removing the token closes its Program, secondary and clean registrations.

This fixes a bounded ownership leak during retirement. Previously a blocked callback's serial drain retained the mailbox and all pending frames even after the engine removed its dictionary entry. Those frames could occupy the renderer's entire four-surface pool and prevent unrelated output from obtaining the next frame. The pool's allocation threshold remains **four**; no memory limit, frame rate, geometry, encoder, render call, clock schedule or performance gate changes.

## Actual renderer and mailbox proof

Run from `apple` with the normal local vendor dependencies available:

```sh
zsh scripts/run_composition_mailbox_retirement_harness.zsh --negative-control
zsh scripts/run_composition_mailbox_retirement_harness.zsh
```

The checked-in runner builds the actual app dependency graph with two jobs and Swift `-j2`. It uses the actual `CompositionEngine`, `SceneRenderer`, Core Video pool and serial mailboxes, with an owned 16×16 shape through the existing explicit native-validation render entry. Continuations and semaphore gates determine ordering; no sleep, retry timing, media, camera, microphone or desktop capture controls the result. A validation-only probe retains the mailbox, never a snapshot of its raw buffers, and exposes numeric state plus a serial queue barrier. Shipping removal has no barrier or join.

Two sinks use the production default pending capacity of two. A blocks on frame 1. B registers afterwards and blocks on frame 2. Rendering frames 3 and 4 leaves both mailboxes pending `[3,4]`, so four distinct source surfaces have known owners: A's active 1, B's active 2, and pending 3/4. A healthy third sink drains each frame without retaining its buffer.

| Stage | Attempts | Rendered | Failed | Healthy frames |
|---|---:|---:|---:|---|
| Attempt frame 5 with four known holders | 5 | 4 | 1 | 1,2,3,4 |
| Remove A; B still holds pending 3/4 | 6 | 4 | 2 | 1,2,3,4 |
| Remove B too; both old active callbacks still blocked | 7 | 5 | 2 | 1,2,3,4,7 |

Retirement frees pending 3/4 before either old callback returns, and healthy output resumes with the unchanged pool limit. Releasing the two gates and fencing their serial queues proves A delivered only frame 1 and B only frame 2: no retired backlog callbacks occur. Repeated close leaves the same state. Additional cases cover removal and same-token replacement on all three canvases, plus the existing cross-canvas token behavior.

The negative control removes **only** the three `removeSink` calls to `close()`. It preserves the fixture assertions, clock guards, renderer, pool and mailbox implementation. The same final observation then reads seven attempts, four renders and three failures, with both retired backlogs still `[3,4]`. It fails the unchanged recovery assertion with expected exit −5. The runner releases both gates and fences their queues before that assertion, so an expected negative failure does not leave blocked sink work.

The restored production run also executes all six existing actual clock-authority cases: stopped tick, restarted tick, output reconfiguration, stopped missed-deadline update, restarted missed-deadline update and explicit validation. The original clock fixture source is unchanged; the combined tool removes only its `@main` annotation. CI invokes this combined runner in place of the previous clock-only runner, preserving the six checks without a second full graph build.

## Retained evidence and limits

The [machine receipt](COMPOSITION_MAILBOX_RETIREMENT_2026-10-22.json) binds the production and three-call negative source hashes, actual observations, original build/runtime logs, five unchanged clock observations and source-only instrumentation compatibility output. All 53 source/proof assertions pass. Original logs are `/tmp/stream-mailbox-retirement-negative-20261022.log` and `/tmp/stream-mailbox-retirement-production-20261022.log`; generated artifacts are under this checkout's `apple/build/composition-mailbox-retirement-validation`. The archived negative engine is reconstructed from the same source with only those three calls removed and matches the compiled hash captured before the negative build.

The bounded hot-path generator now recognizes and preserves the new closed admission/dequeue guards. Its source-only generation, Swift parsing and workflow validation pass; the dispatch-only diagnostic workflow's existing identity pin is updated for that generator change. No diagnostic or sustained workflow was dispatched for this fix, and the sustained harness/workflow and original gates remain byte-identical to the base.

This proves retirement liveness, **not complete isolation from every raw-buffer owner**. Already-dequeued callbacks, recorder queues and downstream SDKs can retain extracted raw buffers; close cannot revoke them. The controlled case identifies its four owners, while the previous hosted traces lack complete recorder/CI/SDK lifetime events. Their instrumented `-6689` return is Core Video's allocation-threshold exhaustion, not generic resource allocation failure (`-6662`), but it does not identify every holder. The original 600-second failures lack this return-code attribution and remain unchanged. First-use graph/CI work and long CI wall spans also remain unattributed. No sustained capacity improvement or #92 closure follows from this regression.
