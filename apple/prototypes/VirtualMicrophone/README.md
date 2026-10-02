# Virtual microphone feasibility prototype (#173)

Decision: **continue evaluation of the public AudioServerPlugIn HAL route**.
This is Apple's documented route for a software virtual audio device. It is
distinct from the CMIO camera system extension and AudioDriverKit's hardware
driver sample. A prototype is reproducible and its actual driver callbacks
transfer PCM, but an installed, signed device has not yet been qualified in
another app. There is therefore **no supported shipping-path decision yet**;
#173 stays open and #174 remains gated.

## Source and bounds

`StreamVirtualMicrophone.c` adapts Apple's 2024 NullAudio sample, downloaded
from the official [Creating an Audio Server Driver Plug-in](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in)
sample attachment. Its original permissive license is preserved in
`LICENSE-Apple.txt`. The upstream object/property/COM interface remains the
base; modifications marked `STREAM_PROTOTYPE` add actual audio and lifecycle
behavior. This file is a prototype, excluded from all application targets.
The upstream archive is `https://docs-assets.developer.apple.com/published/430ad6501f6f/CreatingAnAudioServerDriverPlugIn.zip`;
SHA-256: `860334dfa9e83f2afb749a890ca5a79fc7d3d572d4e116ff9242bec458be4cb0`.
The original `NullAudio.c` SHA-256 is
`8b61fb9f96c12356c7da6696a6c1bee5da73222dfb4e831aa9487244e7bf5dfc`.

The `.driver` publishes **Stream Studio Microphone Prototype**, a stable-UID
duplex device: two interleaved Float32 channels at 44.1 or 48 kHz. Default rate
is 48 kHz. A producer writes its output side; conferencing apps read its input
side. A 16384-frame ring is indexed by absolute device sample time, with a
512-frame input delay (10.667 ms at 48 kHz, 11.610 ms at 44.1 kHz). Capacity is
fixed, so old slots cannot replay as fresh audio after wrap or producer loss.
Callbacks are bounded to 4096 frames. Non-finite samples become silence and
values clip to [-1, 1]. Input/output volume and mute apply to actual PCM. There
is one PCM data source; the prototype does not pretend to offer multiple buses.

IO uses lock-free atomic stamps and packed stereo samples, with no allocation, file/IPC
operation, sleep, logging or mutex in `DoIOOperation`. Overlapping read/write
cannot create C data races. Duplicate/backward writes and malformed callback
timing are rejected; underruns return zeros. Client starts/stops are independent.
Once all clients stop, the ring clears. A new session clears it again and
changes the zero-timestamp seed. The host-clock calculation catches up after
missed callbacks rather than advancing one period per invocation.

## Build and reproduce measurements

```sh
apple/scripts/run_studio_virtual_microphone_harness.zsh
DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer \
  apple/scripts/run_studio_virtual_microphone_harness.zsh
```

The build creates a universal **arm64 + x86_64** `.driver` under
`apple/build/virtual-microphone-prototype/`. The harness dynamically loads that
actual bundle executable, discovers its exported AudioServerPlugIn factory,
initializes the real interface against an isolated host-storage fixture, reads
the input format and runs real IO callbacks. It checks sample equality and
nonzero PCM energy, advertised format, timing/mute/malformed input, deterministic
silence, callback bounds, independent stop, rate rejection and session reset.
Concurrent actual driver read/write callbacks also check ring-wrap timestamp
and stereo integrity: a replaced frame becomes silence rather than another
timestamp's samples or a partly updated stereo pair.
The fixture's host only provides Core Audio's persistence/notification hooks;
it does not replace the driver or PCM loopback implementation.

The build also creates `installed-device-probe`. Running it with no arguments
only checks for the prototype's stable HAL UID. After an authorized signed
installation, pass **`--test`** explicitly to create separate public Core Audio
producer/consumer IO callbacks, send a 440 Hz signal for three seconds, measure
input/output frame counts and peak level, and verify silence after producer
stop. This uses normal microphone consent and does not install anything or
change default devices. Its installed-device test has **not** been run here;
the read-only probe reports that the device is unavailable.

On the development Apple-silicon Mac with Xcode 27.2, 1024 stereo frames of a
440 Hz fixture plus a constant second channel produced summed squared sample
energy **48.25474** with sample error below **0.000001**. The 512000-frame
write-and-read callback benchmark reports its wall time each run (one run:
**1.407 ms**). These are in-process callback measurements, not installed HAL
latency, system CPU, application A/V sync or Intel execution measurements.

## Installation, signing and distribution gate

Apple's sample installation path is `/Library/Audio/Plug-Ins/HAL`, followed by a
restart. Installation is global and requires administrator authorization. It
does not use camera-extension activation, and no SIP changes are needed or
requested. Build scripts never copy into this directory, restart Core Audio,
change default devices, install a package or change security settings.

Before an operator-controlled prototype installation, sign the **bundle** with
the intended Developer ID Application identity. Build a separate installer
package with `pkgbuild` rooted at that HAL destination and sign it with Developer
ID Installer; notarize/staple and verify the package through the release
process. The repository does not infer a signing identity or notarization
credential, and it does not produce a signed artifact without those inputs.
The driver needs no App Group or DriverKit entitlement: Core Audio loads it
into its audio-server process, rather than running a sandboxed app extension.
Its higher process privilege and crash impact require careful qualification.
The camera's matching-team App Group and activation request are unrelated.

For the sandboxed studio, the proposed host connection is the **public Core
Audio output-device API**, explicitly targeting this driver's stable UID. A
read-only program/aux bus tap would feed a bounded converter/render mailbox;
the device's input side is selected explicitly by receiving apps with normal
microphone consent. No custom Mach service, global socket, hidden monitor-to-mic
conversion or CMIO audio stream is assumed. Sample-rate conversion, driver
clock drift, producer authorization policy, feedback detection and program vs
clean/mix-minus routing must be proven in that real path before #174 proceeds.

HAL drivers are not embedded camera extensions. Distribution requires a
separate signed installer/update/removal process and a supported standalone
distribution route. No Mac App Store driver-install compatibility is asserted.
Updates/removal require closing clients, replacing/removing only this bundle,
and the documented Core Audio/system restart. Preserve existing driver bundles
and default device selections. Client apps may require relaunch after changes.

## Remaining evidence required for #173

- Sign/notarize and authorize installation of the prototype on a disposable
  Apple-silicon and Intel test system; inspect Audio MIDI Setup and device UID,
  formats, clock and properties through public HAL APIs.
- Feed real studio program audio through its sandboxed Core Audio output path;
  select this input in a separate recorder, current Zoom, Safari/Chromium and
  FaceTime, then inspect captured PCM, timestamps, channels, duration, A/V sync,
  actual latency, CPU, drift, underruns and disconnect/reconnect.
- Test stop, producer crash, sleep/wake, client restart, ring exhaustion, format
  changes, signed update/removal and coexistence with existing HAL drivers.
- Prevent selecting the virtual microphone as the studio's own mic, additional
  input or monitoring device. Validate app/system audio capture and conferencing
  return paths; a read-only bus tap alone does not prevent every feedback loop.
- Make an explicit supported-distribution decision from those results. Until
  then #174's signed packaging, main-window bus/format/state controls and target
  app compatibility remain unimplemented acceptance gates.

Primary architecture references: [Apple AudioServerPlugIn sample](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in),
[Apple AudioDriverKit sample's virtual-device guidance](https://developer.apple.com/documentation/audiodriverkit/creating-an-audio-device-driver),
[Core Audio public API](https://developer.apple.com/documentation/coreaudio).
