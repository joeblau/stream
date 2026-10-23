# Exhausted terminal audio input

`ProgramRecordingSession` now marks its audio writer input finished when the
terminal source boundary is known, real audio has reached that boundary, and
the audio queue is empty. It atomically closes audio admission before the
native call. This releases interleaving while video remains queued. Final
cleanup uses the same flag to avoid a second native finish call.

The early path requires a healthy started writer, a non-nil audio input, an
explicit finish request, and a resolved numeric boundary. It does not apply to
live recording, pause, an unresolved rotation boundary, or a missing PCM tail.
The existing three-second finish deadline, timestamps, media queues, and
sample-count and decoder assertions are unchanged.

The installed primary SDK contract is `AVAssetWriterInput.h`, lines 267–270,
under `/Applications/Xcode-27.1.0.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/AVFoundation.framework/Versions/A/Headers`.
It requires finishing each exhausted readiness-monitored input to prevent
other inputs from stalling on ideal interleaving. The receipt records the
header hash; SDK content is not copied into the repository.

## Controlled actual-writer regression

The single retained batch is
`/tmp/stream-wave25-terminal-audio-eos-proof-20261022`. It used actual
`ProgramRecordingSession`, its production dependencies, `AVAssetWriter`,
generated owned BGRA pixels and PCM, and the original independent decoder.
All 76 current Core source hashes matched the reused framework receipt before
the framework was copied into this proof directory. No Core build was needed.

The generated test copies add read-only writer-queue observations, count an
actual non-nil native audio `markAsFinished()` call after it returns, and inject
one final-video readiness gate. The harness first observes 59 accepted video
frames, all 100 accepted audio chunks, empty queues, and no audio EOS. Only then
does it introduce frame 59. That final frame waits for the observed native
audio EOS. This is an explicit controlled SDK-contract condition, not evidence
that the original Intel writer had the same readiness state.

| Exact invocation | Compile | Runtime | Result |
| --- | --- | --- | --- |
| Fixed actual source | 0 | 0 | 60 video / 100 audio; one native audio EOS; decoded 1.0 s, 60 frames, flash 0.5 s, tone 0.5000416667 s |
| Exact parent `9f9f6bc6f4aa81c4ba1d0e92e096047741d9bfb7` | 0 | −5 | 59 video / 100 audio; original three-second finalization error; intended assertion |

The fixed invocation also ran a second actual-writer case with 99 audio chunks,
an outstanding finish, and no premature audio EOS. Supplying the missing real
PCM chunk completed 60 video / 100 audio with one native audio EOS. Its decoded
file also contained 1.0 s and 60 frames, with the same flash and tone positions.
Both fixed files retained the original one-second duration and 80 ms sync gates.

The negative oracle requires successful compilation, no runtime timeout, the
expected Darwin assertion signal (−4 or −5), the exact 59/100 deadline result,
and the intended assertion marker. Other failures do not qualify. Both
invocations occurred once, without retries. The five-second setup and
45-second runtime guards are fixture bounds, separate from the unchanged
production three-second drain deadline. Direct children returned and were
reaped by `subprocess.run`; no process-group membership receipt was collected.

There was no capture, audio engine, browser helper, device, UI, network, or
external publishing operation. The Core coordinator only admitted owned
private pixel storage. Audio inspection used the existing offline
`AVAudioFile` decoder option.

## Reuse

The checked-in Python recipe and Swift harness are the exact executed bytes.
Preparation requires the exact parent commit in local Git history and a
matching existing Core framework with its 76-source receipt:

```sh
python3 apple/scripts/terminal_audio_eos_fixture.py prepare \
  --output /absolute/fresh-owned-proof \
  --framework /absolute/products/StreamCore.framework \
  --core-receipt /absolute/core-receipt.json
python3 /tmp/stream-native-build-slots-20261022.py --label terminal-audio-eos -- \
  python3 apple/scripts/terminal_audio_eos_fixture.py run \
  --output /absolute/fresh-owned-proof
```

Preparation refuses an existing output directory. Execution verifies prepared
source hashes and refuses existing outcomes. It compiles Swift 6 with `-j2`,
runs the fixed case first, and stops on any unexpected compile, setup, or
runtime result. The historical parent is extracted with `git show`, not
reconstructed by deleting a new guard. The current retained batch used the
root-authorized shared build-slot wrapper. The paths above illustrate reuse;
there was no additional execution after the retained batch.

## Original Intel failure remains separate

Run `39877849256`, job `120172937931`, failed the actual owned-ending fixture
at 34 video / 100 audio, zero reported drops, video endpoint 0.5666458333 s and
audio endpoint 1.0 s. It reported the writer's own finalization deadline.
The fixture directly awaited the actual writer callback; its five-second
polling helper did not govern finalization. No loss of writer ownership or
ending-action cancellation was identified in source.

The original log did not retain video readiness, remaining queue counts, or
the exact cutoff at failure. The controlled regression proves the SDK-contract
fix, not the original Intel cause or general CI remediation. The original
failed profile and deadline remain valid evidence. No native or hosted Intel
rerun was performed for this patch.
