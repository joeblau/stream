# Guest return sender/browser diagnostic, 2026-10-22

This bounded owned diagnostic localizes the retained silent return. It does not qualify TURN/TLS audio playout or change shipping routing, permission, sink, codec or transport behavior. The original browser positive PCM gate failed unchanged.

## Observation boundaries

`STREAM_GUEST_RETURN_DIAGNOSTIC=1` adds observers only to generated validation copies of the shipping return sender and video CLI. Received PCM and admitted pre-encoder PCM are separate bounded windows (64 chunks each). At most128 actual emitted Opus packets and their actual SDK send results are retained. A command decodes those exact packets with a separate public Apple AudioCodec instance on a detached task. "Independent" in the original receipt means separate from the sender/AVAudioConverter path, not a different codec implementation. No raw PCM/Opus, SDP, peer IDs, addresses, credentials or personal capture enters the diagnostic receipt. Source hashes and a bounded deidentified receipt are in [the machine report](NATIVE_GUEST_RETURN_AUDIO_DIAGNOSTIC_2026-10-22.json).

Counters/windows belong to the fixture process, not to a lease generation. This recorded failure is the first and only receive lease and ends before any rejoin test; the last routing revision is not a lease identifier. Future reconnect diagnostics must use a fresh process or explicitly reset/tag observation windows before attributing them to a replacement peer.

The browser observer adds only inbound-audio counters and actual context/track/worklet status. Existing stereo amplitude, own-voice exclusion and near-zero mute assertions are unchanged. No statistics are substituted for decoded PCM.

## Local positive control

The new `run_guest_return_sender_diagnostics.zsh` builds current Core and runs2.2s of generated stereo PCM through the actual mixer/rings/current-recipient return mailbox, shipping native Opus encoder and separate Apple AudioCodec decoder. It starts no physical capture, output device, receiver socket or browser. Final run admitted205chunks and emitted108packets, all RTP steps960, zero encoder errors. Admitted tones were0.400081/0.199999; decoded tones0.384664/0.189718. Successful network sends are explicitly0 in this unit. Log: `/tmp/stream-wave4-guest-return-local-final-20261022.log`.

## Actual owned TLS/Chrome attempt

Exact source baselinea346f56; optional TLS backendc7df56076fd3876ae72c8911d9c1ca29a5d067cd3998c92c47761f7d4c29415c. The fresh own CLI/cache build compiled current Core/Mac sources, copied only immutable package inputs and the verified optional archive, and reused no prior compiler products or module caches (`--dependencies-only`). Build log: `/tmp/stream-wave4-guest-return-diagnostic-build-final-20261022.log`. Exact CLI SHA420e68384f7abc24b7b0125d44fe5e43b3c50a177c3e459fa9f514599f599a8e.

The single instrumented attempt retained the prior explicit null AudioContexts and muted owned HTML player (`--video-flow-only --owned-null-contexts`). It used generated media, real Manager/default receiver factory, local Worker, owned TLS-only Coturn and Chrome155.0.8059.85. It changed no OS, trust, permission or personal application state.

- Admitted pre-encoder stereo tones:0.399969/0.200005, RMS0.282832/0.141423.
- Actual packet attempts933; successful SDK sends933; encoder errors0. The retained128 exact successfully sent packets independently decoded122880stereo frames, tones0.391748/0.195462 and RMS0.279034/0.139216. All127 retained RTP steps were960.
- Chrome received931Opus RTP packets /151615payload bytes, packetsLost0. Its jitterBufferEmittedCount, totalSamplesReceived, totalSamplesDuration and totalAudioEnergy were all0.
- The remote track was enabled, unmuted and live. The real48kHz null AudioContext was running; its AudioWorklet processed288768frames, all zero. The unchanged0.4/0.2 positive PCM gate therefore failed.

Log: `/tmp/stream-wave4-guest-return-sender-browser-diagnostic-20261022.log`. Native/Chrome/Worker owned processes exited or were retired by the fixture; exact owned PIDs were confirmed absent. All original failed logs remain preserved.

## Meaning and next measurement

This run rules out absent/muted sender PCM and demonstrates positive payload decoding through the separate Apple decoder. It does not alone establish cross-implementation RTP interoperability. Actual RTP arrived at Chrome; this narrows the remaining boundary to receive jitter-buffer/decoder/consumption before WebAudio samples. It does not distinguish null-sink or host audio-service consumption behavior from RTP/SDP/playout interoperability, and does not by itself establish a TLS defect. No production patch follows without a measured cause.

The next narrow discriminator would be an owned same-browser WebRTC oscillator loopback using the identical null-context/muted-player consumption chain, comparing actual input PCM, inbound RTP/jitter emission and output PCM. That has not been run by this change. Do not repeat the full network fixture unchanged, relax its original positive gates, or count incoming packet/energy metadata as decoded return acceptance. Normal HTML audio, rendered PCM, AEC, AV timing, capacity, production TLS adoption/deployment and whole-issue127 acceptance remain unqualified.

## Reproduction

Run the local unit with `zsh apple/scripts/run_guest_return_sender_diagnostics.zsh` through the shared native build-slot helper. For an explicitly authorized full diagnostic, set `STREAM_GUEST_RETURN_DIAGNOSTIC=1` before preparing the owned current-source CLI and before invoking the browser fixture. Optional `prepare_owned_nice_media_cli.py --dependencies-only` preserves old compiler caches by copying only package inputs into the new derived root. The default preparer behavior and shipping targets are unchanged.

## Subsequent source and reference-codec audit

[NATIVE_GUEST_RETURN_WIRE_AUDIT.md](NATIVE_GUEST_RETURN_WIRE_AUDIT.md) traces
the exact Chrome155 receive-clock/FIFO boundary and native SDP/RTP/RTCP contract.
Its native-only current-source encoder-to-existing-libopus test separately
proves raw stereo20ms payload interoperability without any browser/network or
output device. The one approved all-Chrome null-sink loopback stopped during
initialization and remains UNQUALIFIED; it did not establish same-symptom or
positive browser consumption. All original failed artifacts remain failed.
