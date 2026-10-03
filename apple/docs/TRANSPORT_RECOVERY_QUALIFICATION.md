# Actual independent transport recovery

Run the shipping `DestinationOutputController`, one shared H.264/AAC encoder,
`RTMPPublisher` and `SessionPublisher(.srt)` against two owned loopback FFmpeg
receivers:

```sh
zsh apple/scripts/run_shared_encoder_harness.zsh --transport-recovery-only
zsh apple/scripts/run_shared_encoder_harness.zsh --transport-recovery-only --software
```

The fixture interrupts only its original RTMP `Process`, waits for the actual
publisher's `reconnecting` state, and launches a replacement receiver on the
same owned endpoint. The existing publisher must return to `live`. Independent
original-timestamp source audio/video continues throughout; the SRT publisher
must stay live, retain its original acknowledged start, and share the same
single encoder. The factory must be called exactly twice for the whole run.
Both outputs must complete their real stop acknowledgments.

All three receiver files undergo actual H.264/AAC decode and track checks. The
surviving SRT file must have strictly increasing decoded timestamps with no
missing 25fps cadence tick, preserve the independently generated early/late
source flash distance, and reach the original final source interval. Its first
received sample is not assumed to be source PTS zero: the real SRT startup
primer can omit an initial prefix, so the independent original .52s flash
anchors the timeline. The tail comparison permits one 40ms frame boundary.

Local M3 Max/macOS 27.0.1/Xcode 26.6 runs pass with both the shipping hardware
preference and the explicit public software VideoToolbox encoder. Initial runs
decode 392 continuous survivor frames; the final artifact-retention rerun decodes
393. The early/late flashes are
.24/11.7199888889 seconds, preserving the original 11.48-second spacing; final
decoded PTS is 15.6399888889 seconds (15.6799777778 in the final rerun). Actual RTMP files exist before and after
recovery, and SRT audio/video remain synchronized. The pinned upstream SDK emits
a `close()` continuation warning during this exercised reconnect, although the
actual reconnect and both stop acknowledgments complete; this test does not
qualify sustained reconnect resource usage.

The hosted Intel run at `895e25d` reached receiver setup but the installed
minimal Homebrew `ffmpeg` lacked the SRT protocol, so it did not qualify
transport recovery. The workflow now installs `ffmpeg-full`, checks actual
RTMP/SRT protocol availability before compilation, and selects that binary
explicitly through its formula prefix.

The Native transport recovery workflow runs both modes on Apple Silicon and
Intel and retains original receiver files and logs. Hosted checks must pass on
the final commit before they qualify that architecture.

This is an owned local endpoint-loss test. It does not qualify provider ingest,
Internet route changes, physical unplug/display removal, macOS sleep/lock,
permission revocation, source fallback pixels, or automatic resumption policies.
Issue #158 remains open for those separate requirements. No account keys,
operator files, devices, global permissions or system services are used.
