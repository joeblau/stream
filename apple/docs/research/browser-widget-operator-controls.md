# Browser helper mixer and ISO qualification

The production helper selector remains disabled. An explicitly installed `BrowserOverlayHelperBackend.qualificationSession` must own the exact runtime `AudioMixEngine`. A different runtime reports the helper unavailable and cannot reuse its mixer, page demand or isolated audio capability. No saved source, mixer value, ISO selection or UI action installs a qualification session or requests capture permission.

While that session has actual page demand, the existing Mixer panel exposes one **Browser Widgets (shared helper)** application channel with a Qualification badge. All audible Program pages share it; Preview-only pages stay silent. Its normal dispatcher controls persist gain, mute, monitor-only solo and Aux send through the existing settings session. Aux retains the mixer’s existing independent pre-fader send semantics; the channel fader/mute controls Program and Monitor. The strip disappears after last-page retirement while those saved values remain available for the next explicitly qualified demand.

The final helper route gate remains closed while the engine installs the current saved gain/mute, solo and Aux values without carrying an old gain ramp across the boundary. Preparation rechecks the current settings after the actor await, retries at most eight times, and supplies a live synchronous validator immediately before the session opens its gate. Stale source revisions, cancellation, retired owners or sustained settings churn leave the helper unavailable. This does not change persisted settings or reset unrelated mixer channels.

Recording Options discovers the same shared application identity before its first PCM buffer and marks it unavailable until the engine actually receives current route audio. The ordinary eight-track ISO selection, Before/After Inserts processing, formats and capacity-16 tap infrastructure apply. An ISO track cannot demand a helper page or keep capture alive. After last page retirement, old selections become unavailable; resolving the old helper target cannot install a new tap. An already registered tap remains fenced by the synchronous route gate and original timestamps.

The controlled regression extends the existing lifecycle runner:

```sh
cd apple
STREAM_VENDOR_ROOT=/path/to/clean/vendor \
BROWSER_LIFECYCLE_BUILD_PATH=/path/to/owned/derived \
  scripts/run_browser_widget_lifecycle_harness.zsh
```

It uses the real LaunchServices helper, public WebKit load/suspend/resume acknowledgments, actual Controller demand and Take, the shipping SwiftUI Mixer and Recording Options, the real command dispatcher, owned settings files and the native audio mixer/taps. A separate public AX client addresses only its parent fixture PID; it never requests accessibility trust. An unavailable WindowServer or owned AX interface exits 77. Its PCM driver supplies generated stereo audio through the actual bounded inlet, so this proof does **not** qualify physical ScreenCaptureKit attribution, live widget sound, speaker playback, signed/sandboxed IPC, permissions, capture exclusions, arbitrary remote media or sustained operation.

The operator fixture holds the old mixer seed before its actor call, applies newer live gain/mute/solo/Aux commands, allows those newer writes to reach the engine, then releases the stale seed. First admitted Program audio must still honor the newer mute. Actual native fader, mute, solo and Aux actions then verify the resulting PCM, and the Recording Options checkbox selects the same real ISO target. Last-demand retirement, unavailable stale selections, exact source ownership, preserved settings and a fresh-demand saved-mute restoration are checked through those same runtime paths. The runner requires an explicit completion marker after all assertions, so a premature clean process exit cannot count as a pass.

On 2026-10-21, this complete native runner passed on the local Mac with Xcode 27.2 beta 3. Measured steady-state sample means were Program **0.350032**, Monitor **0.150015**, Aux **0.075007**, and isolated **0.300031**, matching the generated helper input 0.3, independent microphone input 0.2, helper fader 0.5, monitor solo and independent Aux send 0.25. The fixture uses the real driver’s existing bounded 80 ms holdback and independent generated-source workers; it preserves their original host timestamps. It also retired a source while final mixer preparation was held, released that late completion and verified the route stayed closed. Existing queued-ISO, old-generation/original-PTS, held insert/delay-tail, exclusion-conflict and Controller Take lifecycle cases passed in the same run. No new capture, trust or permission was requested.

The remaining A12 production gates in [browser-widget-audio.md](browser-widget-audio.md) still apply.
