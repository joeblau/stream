# Virtual microphone feasibility prototype (#173)

Decision: **continue evaluation of the public AudioServerPlugIn HAL route**.
This is Apple's documented route for a software virtual audio device. It is
distinct from the CMIO camera system extension and AudioDriverKit's hardware
driver sample. A prototype is reproducible and its actual driver callbacks
transfer PCM, but an installed, signed device has not yet been qualified in
another app. There is therefore **no supported shipping-path decision yet**;
#173 stays open and #174 remains gated.

## Studio Program producer evaluation

`StudioProgramProducer.swift` and `StudioProgramRender.{c,h}` now provide an
evaluation-only application producer for this same public HAL output route.
They are under `prototypes/`, excluded from every shipping target; no main-window
controls, settings, demand, or automatic output activation are added. An explicit
unqualified-route acknowledgement is required. The producer subscribes to the
actual `AudioMixEngine` **Program** bus with a two-chunk mailbox. It does not
start the mixer, microphones, publisher or recorder. Aux is not called clean or
mix-minus, and no conferencing client is assigned a fabricated guest lease.

The real transport implements public device lookup/identity/ASBD reads,
`AudioDeviceCreateIOProcID`, `AudioDeviceStart`, `AudioDeviceStop`, destruction
and property listeners. It selects only this prototype's exact stable UID and
refuses unavailable, non-stereo or non-48-kHz devices; it never changes device
rate, format or defaults. There is no alternate AVAudioEngine/monitor route.
The actual OS transport is implemented and compiled, but has **not** been run.

The producer preallocates 32768 timestamped stereo frames (about 683 ms) and
accepts at most 4096 frames per chunk/callback. Source conversion runs only on
the tap queue; the C IO callback has no allocation, mutex, wait or logging.
Atomic stamps and packed stereo values return the requested timestamp's whole
pair or silence during ring overwrite. Original host PTS is rounded to the
48-kHz sample grid, never rebased to arrival. A valid HAL sample/host-time pair
anchors the device clock; a backward or inconsistent clock latches silence until
an explicit fresh session. Missing/invalid/retired data produces silence.

The explicit evaluation scheduling delay is **12288 frames (256 ms)**, in
addition to the driver's **512 frames (10.667 ms)**. The controlled nominal
sum is 266.667 ms; this is not measured installed-HAL latency or A/V sync with
the camera extension. Callback output timestamps retain the HAL clock. Stop
retires the mailbox synchronously before tap removal/IO cleanup. Shared stop
callers await one captured-session barrier; restart cannot overtake it. A failed
IOProc/listener cleanup retains its context, refuses a second session and can be
retried explicitly. Already delivered driver/client buffers are not retroactively
erased; future missing producer frames follow the driver's silence behavior.

```sh
zsh apple/scripts/run_studio_program_producer_harness.zsh
```

The owned fixture compiles the whole actual mixer and producer, independently
taps Program, and paces the same C IO callback from original host-clock positions
into the actual dynamically loaded driver's WriteMix/ReadInput callbacks. It
checks sample equality, real channel/bus gain and mute, independent stop and
consumer silence, old callbacks, UID/44.1-kHz/acknowledgement refusal, clock fault,
wrap/underrun/bounds, concurrent timestamp/stereo replacement, held actual-mixer
stop/restart ordering and cleanup retry. Artifacts bind source, driver and fixture
hashes to the observed PCM error and scheduled timestamps. Both driver slices
are built; only the host architecture executes.
Cancellation while the synchronous HAL start returns is checked before the
producer can report running; the owned case starts the actual loaded driver,
cancels that request and verifies complete cleanup.

Only HAL syscalls are replaced: system UID lookup and buffer size, creation and
IO lifecycle/listener delivery are owned fixture boundaries; actual driver UID,
alive, stream/ASBD, clock and PCM callbacks are used. No OS device/session,
permission, signing, playback/capture, install or default/rate mutation occurs.
This proves the in-process Program producer, **not** installed IPC, sandbox access,
another application's input selection/audio, producer authorization against other
processes, real device hot-plug, signed activation/update/removal or target-app
sync. O07's supported-path decision remains unproven and O08 stays gated.

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
credential. The [evaluation packaging tool](../../docs/VIRTUAL_MICROPHONE_PACKAGING.md)
can prepare and audit a separate candidate using those explicit inputs, or
create a clearly labeled ad-hoc/unsigned local fixture. It never executes an
installer, activates a driver or establishes a supported distribution decision.
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
- Make an explicit supported-distribution decision from those results. The
  build-only evaluation package is not signed installation/update/removal
  qualification. #174's main-window bus/format/state controls and target-app
  compatibility remain gated by that decision.

Primary architecture references: [Apple AudioServerPlugIn sample](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in),
[Apple AudioDriverKit sample's virtual-device guidance](https://developer.apple.com/documentation/audiodriverkit/creating-an-audio-device-driver),
[Core Audio public API](https://developer.apple.com/documentation/coreaudio).
