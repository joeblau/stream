# Stream

**Stream** is an iOS 26+ app that broadcasts your phone's **entire screen** to an
**RTMP or RTMPS** endpoint (for example [restream.io](https://restream.io)), with an
optional **camera Picture-in-Picture (facecam) overlay** and support for a
**Bluetooth microphone** such as a DJI Mic.

It uses a **ReplayKit Broadcast Upload Extension** for system-wide screen capture
and pushes the encoded stream with [HaishinKit](https://github.com/HaishinKit/HaishinKit.swift)
over RTMP/RTMPS.

---

## Features

- **System-wide screen broadcast** — captures everything on screen (other apps,
  games, the home screen), not just this app. Started via the system broadcast
  picker, so it is App Store-safe.
- **RTMP & RTMPS push** — `rtmp://` (port 1935) or `rtmps://` (TLS, port 443).
  TLS is negotiated automatically from the URL scheme; no extra flag is needed.
- **Optional facecam Picture-in-Picture** — a front or back camera feed composited
  as a rounded-corner overlay onto the screen frames *inside the extension, before
  encoding*. Toggle it on/off, pick the corner, scale it, and choose front/back.
  > This is a composited overlay, **not** `AVPictureInPictureController` (which is a
  > playback API and is the wrong tool for broadcasting).
- **Bluetooth microphone support (DJI Mic, etc.)** — the app lists the available
  audio inputs; you pick a Bluetooth input and the broadcast honors it as the mic
  route.
- **App ↔ Extension settings sharing** — non-sensitive configuration travels
  through an **App Group** (shared `UserDefaults`) as a single JSON blob.
- **Secure credential storage** — the RTMP/RTMPS **URL and stream key are stored in
  the Keychain** (a shared keychain access group), so you enter them once and the
  broadcast extension can read them at go-live. They are never written to
  `UserDefaults` in plaintext.

---

## Architecture

Three coordinated targets that never share memory at runtime — all coordination
crosses the App Group `group.com.joeblau.Stream`:

| Target | Type | Role |
| --- | --- | --- |
| **Stream** | iOS app (SwiftUI) | Edits & persists settings; lists audio inputs; presents the broadcast picker. Does **not** capture the screen. |
| **StreamBroadcast** | Broadcast Upload Extension | Hosted by `replayd`. Reads settings, configures audio, runs the optional facecam, composites + encodes, and pushes RTMP/RTMPS. |
| **StreamCore** | Dynamic framework | Shared `StreamSettings` model, `SettingsStore`, `AppGroup` constants, and enums. Single source of truth. |

**Data flow:** on every edit the app writes the non-sensitive `StreamSettings`
fields as a JSON blob to `UserDefaults(suiteName: "group.com.joeblau.Stream")`
under key `stream.settings.v1`, and writes the connection **URL + stream key to the
Keychain** (shared access group `$(AppIdentifierPrefix)com.joeblau.Stream`, service
`com.joeblau.Stream.connection`). The extension reads both in `broadcastStarted`.
Live objects cannot cross processes — only the persisted snapshot does.

---

## Requirements

- **Xcode 27 / Swift 6.4** (strict concurrency).
- **iOS 26.0+** deployment target.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the project.
- An Apple Developer account/Team ID for **device** builds (App Group + broadcast
  extension capabilities require signing on hardware).

---

## Build

```bash
# 1. Generate the Xcode project from project.yml
brew install xcodegen        # if you don't have it
xcodegen generate

# 2. Open and run, or build for the Simulator without signing:
xcodebuild \
  -project Stream.xcodeproj \
  -scheme Stream \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

On the **Simulator** the camera/facecam paths are compiled out
(`#if targetEnvironment(simulator)`) — everything else builds and runs. Actual
broadcasting and the facecam require a physical device.

---

## Signing & App Group setup (device builds)

1. Open **`project.yml`** and set `DEVELOPMENT_TEAM` to your Apple Team ID (it ships
   empty as a documented placeholder), then re-run `xcodegen generate`.
2. The App Group **`group.com.joeblau.Stream`** is declared in the generated
   entitlements for **both** the app and the extension. In the Apple Developer
   portal, register that App Group and enable the **App Groups** capability for the
   two App IDs:
   - `com.joeblau.Stream`
   - `com.joeblau.Stream.Broadcast`
   The generated entitlements also declare a shared **Keychain Sharing** group
   (`$(AppIdentifierPrefix)com.joeblau.Stream`) on both targets — with automatic
   signing Xcode enables the **Keychain Sharing** capability for you. (On the
   Simulator, an unsigned `CODE_SIGNING_ALLOWED=NO` build can't use the Keychain —
   `SecItemAdd` returns `errSecMissingEntitlement` — so use a signed build, even
   "Sign to Run Locally", to exercise credential saving.)
3. Bundle identifiers (do not change — they are wired throughout):
   - App: `com.joeblau.Stream`
   - Extension: `com.joeblau.Stream.Broadcast`
   - Framework: `com.joeblau.StreamCore`

---

## Configuring restream.io (RTMP / RTMPS)

restream.io (and most ingest services) give you a **server URL** and a
**stream key**. In Stream's **Settings**:

- **URL** — the RTMP *application* URL, e.g.
  - `rtmps://live.restream.io/live` (TLS, recommended)
  - `rtmp://live.restream.io/live` (plaintext, port 1935)
- **Stream Key** — the long publish key from your restream.io dashboard. This is
  the *publish name*; do **not** append it to the URL.

Internally the app calls `connection.connect(<URL>)` then
`stream.publish(<stream key>)`. An `rtmps://` scheme auto-negotiates TLS on port
443; `rtmp://` uses 1935. Use a custom port with `rtmps://host:PORT/app` if your
service requires it.

Other tunables: **quality** (480p / 720p / 1080p), **video bitrate**, **audio
bitrate**, **fps** (24/30/60), and **app audio** inclusion.

### Orientation & aspect ratio

The stream **follows your screen**. At the moment you start broadcasting, the app
locks the encode size to your screen's real aspect ratio in its current
orientation — **start in portrait and you stream portrait**, with no squish and no
black bars. "Quality" sets the **short edge** (e.g. 720 → a `720 × 1560`-ish
portrait frame on a modern iPhone); the long edge is derived from the screen so
the proportions are exact. The resolution is locked for the whole session
(mid-stream resolution changes break most RTMP ingests), so rotating the device
after going live keeps the original orientation rather than re-negotiating.

> **Tip:** for the broadcast extension's ~50 MB memory budget, **720p** is the
> safe default. 1080p (especially on iPad, which delivers very large frames) can
> push the extension past the limit and get it killed by jetsam.

---

## Bluetooth / DJI Mic pairing

1. Pair your Bluetooth mic in **iOS Settings → Bluetooth** (for a DJI Mic, put the
   transmitter into its **Bluetooth** mode — not the 2.4 GHz receiver mode).
2. In Stream's **Settings**, open the **Audio Input** picker. The app sets a
   record-capable audio session with Bluetooth HFP options and lists the available
   inputs; pick your Bluetooth mic. Its stable `uid` is persisted into the shared
   settings.
3. When you start the broadcast, the extension re-applies that `uid` with
   `setPreferredInput`, so the `.audioMic` buffers originate from the Bluetooth
   route.
4. In the broadcast picker, make sure the **microphone button is enabled** — the
   system only delivers mic audio (`.audioMic`) when the user turns the mic on.

### Real-world microphone caveats

- **Telephony quality.** Bluetooth HFP forces a narrowband/wideband telephony
  sample rate (typically **8–16 kHz**) for both input and output. You **cannot**
  get a DJI Mic's studio-quality 48 kHz over Bluetooth — that is only available
  via the DJI receiver over USB-C/Lightning. The Bluetooth path is inherently
  low-fidelity on iOS.
- **Audio session mode matters.** The session uses mode **`.default`**, not
  `.videoRecording` — the latter makes iOS prefer the built-in mic near the camera
  and **hides Bluetooth HFP inputs entirely** (so DJI/BT mics never appear in the
  picker). If you fork this, don't switch the recording mode back to
  `.videoRecording`.
- `.allowBluetoothA2DP` is **output-only** and does not enable a Bluetooth mic; the
  app uses `.allowBluetoothHFP` (the iOS 26 replacement for the deprecated
  `.allowBluetooth`), plus `.bluetoothHighQualityRecording` where available (an
  AirPods-tuned feature that falls back to HFP for generic mics). Options are
  applied via a fallback ladder, so an unsupported combination on a given device
  never blocks input enumeration.
- `setPreferredInput` can report success yet not actually switch when **multiple**
  Bluetooth devices are connected. If your mic isn't picked up, disconnect the
  others.
- The extension runs in a separate process and **competes for the mic**. If another
  app grabs it, `.audioMic` buffers can stop arriving and interruption recovery is
  unreliable.
- `availableInputs` is only populated **after** a record-capable category with the
  Bluetooth option is set and the session is active — which is exactly what the app
  does before listing.

---

## Facecam (PIP) usage

1. In **Settings**, toggle **Picture-in-Picture (Facecam Overlay)** on. The app
   immediately requests **camera permission** — grant it. (The broadcast extension
   cannot show the prompt itself, so it must be granted in the app first.)
2. Choose the **corner** (top/bottom × left/right), the **scale** (10%–40% of the
   frame width), and the **camera** (front or back).
3. Start the broadcast. Inside the extension, each screen frame is composited with
   the latest camera frame using a single reused Metal-backed `CIContext` and a
   `CVPixelBufferPool` (no per-frame allocations, to respect the memory budget).
   The front camera is mirrored; the overlay has rounded corners and a 24pt inset.

> The facecam requires a physical device — it is compiled out on the Simulator.

### ⚠️ Device requirement (important)

The facecam runs the camera **inside the broadcast extension**, which is active
while *another* app is in the foreground (the screen you're capturing). iOS only
permits that when the device supports **multitasking camera access**
(`AVCaptureSession.isMultitaskingCameraAccessSupported`) — the extension sets
`isMultitaskingCameraAccessEnabled = true` when it can. Otherwise the camera
session is interrupted (`...VideoDeviceNotAvailableWithMultipleForegroundApps`)
and **no facecam frames are produced — the stream falls back to screen-only**.

- **Supported:** devices with multitasking camera access (e.g. iPad Pro / iPad
  Air). There the facecam composites normally.
- **Not supported:** **most iPhones report `false`** for this capability, so the
  facecam can't run during a *system-wide* broadcast on those devices. This is an
  Apple platform limitation, not an app bug.

The **Picture in Picture** settings section shows your device's status live: a
green "Facecam ready" when it will work, or an orange warning when the device
can't run the camera during a broadcast.

> If you're on a supported device and the facecam still doesn't appear, the
> restricted entitlement `com.apple.developer.avfoundation.multitasking-camera-access`
> (requires Apple approval) may be required. It is intentionally **not** bundled,
> to avoid breaking signing for everyone else; add it to `project.yml` if Apple
> grants it to your account.
>
> For guaranteed iPhone facecam, the only alternative is **in-app** capture
> (`RPScreenRecorder.startCapture`), which records just this app's content (not
> other apps) while it stays in the foreground — a different product than the
> system-wide screen broadcast this app implements.

---

## Real-world caveats (read before shipping)

- **~50 MB hard memory limit.** Broadcast upload extensions are killed by jetsam
  past ~50 MB. ReplayKit alone can hold several large in-flight IOSurfaces, leaving
  little headroom. Mitigations baked in: 720p default, passthrough video mixing
  when PIP is off, `setVideoInputBufferCounts(5)`, one reused `CIContext` + pool,
  and dropping all but the latest camera frame.
- **RTMP lives in `RTMPHaishinKit`.** In HaishinKit 2.x, `RTMPConnection` /
  `RTMPStream` are **not** in the core module — the extension depends on both
  `HaishinKit` and `RTMPHaishinKit`.
- **No `AVCaptureSession` into the mixer.** The mixer is created with
  `captureSessionMode: .manual`; ReplayKit buffers are fed via `mixer.append(...)`
  only. The facecam capture is separate and only supplies CVPixelBuffers to the
  compositor.
- **Stream key placement.** With the low-level API the key goes to `publish()`, not
  the connect URL. Don't put it in the URL.
- **Simulator has no Bluetooth or camera.** The audio-input list may be empty and
  the facecam no-ops; both are handled gracefully so the app still builds and runs.
- **The broadcast picker is the only supported start.** `RPSystemBroadcastPickerView`
  is not deprecated in iOS 26 and remains the App Store-safe entry point.
  Auto-tapping its internal button is unsupported and risky — Stream shows the real
  button.

---

## License

This project is provided as-is as a reference implementation.
