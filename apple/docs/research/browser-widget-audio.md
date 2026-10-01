# Browser widget audio and interaction

A12 #124 remains open. The independent audio route is not implemented or qualified.

G07's measured snapshot path is retained for visual widgets. The previous `helperApp` option silently played inside the studio WebKit process through system output, despite being labeled an independent channel. That substitution is removed. Persisted helper-route widgets stay silent with an inline unavailable message, and the picker disables new selection of that route. Explicit System Mix remains available through the existing A06 routing controls.

Muted/unavailable routes use [WebKit's public media suspension API](https://developer.apple.com/documentation/webkit/wkwebview/setallmediaplaybacksuspended(_:completionhandler:)) in addition to autoplay restrictions and media-element muting. Apple documents that page/user playback cannot resume until the host lifts suspension. This also suspends video-element playback; CSS/DOM animations continue. Stop suspends and unloads the page. Snapshot generations reject late completions after Stop/Reload, avoiding restarted capture and negative in-flight accounting.

Frame identity now hashes the complete normalized configuration. Widgets with the same URL but different viewport/audio/interaction/CSS settings cannot overwrite one another; legacy URL-only payloads still resolve correctly. A bounded identity cache avoids encoding full CSS every render tick and does not put widget URL credentials in the frame-store key.

Interactive pages now reparent into an embedded inspector scroll view. The same WKWebView keeps its original viewport and context; it is not duplicated into another page. Closing the inspector restores the hidden click-through render host. No visible floating interaction window is created. Reload and Replay stay in the inspector.

The actual sources compile in the native app and `scripts/run_browser_lifecycle_harness.zsh`. The harness checks reparenting, absence of a floating interaction window, route warnings, and stopped-page/output state on a logged-in Mac. This restricted workspace has no accessible WindowServer session, so runtime checks are explicitly skipped.

## Independent audio gate

The remaining route needs a dedicated, signed helper app with its own bundle identity, owning both widget page execution and audio. A shared channel for all helper widgets is an acceptable initial identity if explicitly labeled. Validate ScreenCaptureKit attribution of that app and its WebKit audio before committing the helper architecture: a distinct bundle ID alone is not evidence that child-process sound is correctly attributed.

Then wire helper PCM through the existing mixer conversion path, exclude the helper from system capture, and verify gain, mute, monitoring, recording, refresh/stop/hide lifecycle, and timestamps. Use two named tone/speech widgets plus an unrelated application and program monitor return. Record program/isolated/monitor buses to prove no duplicate capture and no unintended muting. This needs an unrestricted signed-app session with Screen Recording access; neither a missing helper nor failed capture may fall back to whole-system audio.
