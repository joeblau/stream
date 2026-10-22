# Optional low-latency encoder fallback

The HaishinKit fork retries compression-session creation once without optional
low-latency rate control when the requested mode returns `kVTParameterErr`.
Dimensions, codec, input pixel attributes and every other encoder specification
remain the same. Other creation errors and all existing settings/preparation
errors still fail. Both creation statuses are logged. The fork also derives
uncompressed input pixel format from the format description's media subtype
(for example BGRA), instead of the media category `vide`.

Run `zsh scripts/run_video_encoder_fallback_harness.zsh` from `apple` after
initializing the pinned vendor. `STREAM_VENDOR_ROOT` can select a clean alternate
vendor parent directory; `VIDEO_ENCODER_FALLBACK_DIR` selects the build directory.
The runner compiles the actual codec/factory/settings sources with a logging
stand-in, limits compiler parallelism to two and bounds owned runtime execution
to 30 seconds. It does not open capture devices, publish media or change settings.

The focused regression passes six refusal cases, including absent/false requests,
unrelated errors and a failed fallback. An actual software-only encoder reproduces
`-12902` for low-latency creation, succeeds with only that option removed, applies
the shipping H.264 Main/4 Mbps/25 fps settings and prepares successfully. Ten owned
BGRA red frames encode into ten H.264 frames and decode back into ten red frames.
The actual `VideoCodec` also creates a session and reports BGRA input attributes.

This demonstrates the fallback mechanism on an Apple Silicon host. It does not
prove the cause or recovery of the original hosted Intel failure in run
`39735328975`, job `119679560505` at `9881359`: that receiver correctly rejected
missing video after repeated encoder creation errors. The original log and
durable failed media artifacts remain preserved. Hosted Intel qualification and
the existing mandatory RTMP video/audio and strict decode gates remain required.

Apple documents the low-latency specification as requiring an encoder supporting
that mode: [VideoToolbox reference](https://developer.apple.com/documentation/videotoolbox/kvtvideoencoderspecification_enablelowlatencyratecontrol)
and [WWDC session](https://developer.apple.com/videos/play/wwdc2021/10158/).
