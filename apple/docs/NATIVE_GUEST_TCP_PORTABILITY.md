# Optional TCP backend: pinned macOS 14 build closure

The optional libnice backend now has owned ARM64 and x86_64 build artifacts
whose **14 merged static archives all declare macOS 14.0 minimums**. Their
GLib dependencies are built from pinned source, rather than the host's macOS 27
Homebrew archives. The shipping SDK and compile-time UDP-only guard remain
unchanged. These artifacts have not been adopted as release dependencies.

This advances the earlier [current-host TCP qualification](NATIVE_GUEST_TCP_QUALIFICATION.md).
The subsequent [optional TURN/TLS proof](NATIVE_GUEST_TLS_QUALIFICATION.md)
adds actual verified TLS control and certificate negatives, with a retained
full-media failure; it does not adopt TLS into the shipping SDK.
It establishes build floors and actual current-host TCP behavior; it does not
establish execution on macOS 14 or Intel hardware.

## Pinned source closure

`build_owned_glib_dependencies.py` builds these dependencies separately for
each requested architecture, with at most two jobs and an owned install prefix.
The source helper uses Python 3.12 or newer, plus existing Meson/Ninja/CMake
and Xcode build tools; it installs no global tools:

| Component | Exact source |
| --- | --- |
| GLib 2.84.4 | `41eca60845d3fc309af361f5e7f801ba339099aa` |
| GVDB | `2b42fc75f09dbe1cd1057580b5782b08f2dcb400` |
| PCRE2 10.46 | `b2bd4254b379b9d7dc9a3dda060a7e27009ccdff` |
| proxy-libintl | `33934de09af6a6627eb44e310a8079df009abdbb` |
| libffi 3.4.8 release archive | SHA-256 `bc9842a18898bfacb0ed1252c4febcc7e78fa139fd27fdc7a3e30d9d9356119b` |
| OpenSSL, supplied owned build | `c8bd5a57108599ac650bbae77fcabe3109dab2e8` |

The [GLib build requirements](https://github.com/GNOME/glib/blob/2.84.4/INSTALL.md)
and [libffi release](https://github.com/libffi/libffi/releases/tag/v3.4.8)
identify the upstream components. The
[proxy-libintl implementation](https://github.com/frida/proxy-libintl/tree/33934de09af6a6627eb44e310a8079df009abdbb)
uses its upstream `STUB_ONLY` mode, with GLib NLS disabled. Transport dependency
messages remain untranslated. PCRE2 JIT is disabled. Runtime libraries come
from the owned prefix or public Apple SDK, with pkg-config searches restricted
to owned dependency prefixes. Host build tools are version-recorded separately.

SDK 27 introduced a concrete compatibility trap: GLib's unprototyped
`has_function('pipe2')` probe succeeds, although `pipe2` cannot be called below
macOS 27. An exact-hash-guarded source patch probes a real call with availability
warnings treated as errors. Below 27, GLib retains its existing pipe/fcntl
fallback. The full GLib build also treats new unguarded availability as an
error. Archive floor checks alone would not catch an unguarded weak import.

Tracked source/index/submodule changes, altered extracted libffi source,
dependency artifact digest changes, architecture mismatch and newer runtime
floors are refused without deleting the caller's files. GLib source archives
retain the unmodified upstream tree, with the reviewed patch supplied separately.

```sh
python3 apple/scripts/build_owned_glib_dependencies.py \
  --build-dir /absolute/owned/dependencies \
  --tools-prefix /absolute/owned/meson-venv \
  --architecture arm64 --deployment-target 14.0

python3 apple/scripts/build_owned_nice_transport.py \
  --build-dir /absolute/owned/backend-arm64 \
  --glib-prefix /absolute/owned/dependencies/arm64/prefix \
  --openssl-prefix /absolute/owned/openssl-arm64 \
  --openssl-source /absolute/owned/openssl-source \
  --tools-prefix /absolute/owned/meson-venv \
  --architecture arm64 --deployment-target 14.0 --source-bundle
```

Repeat with `x86_64` and the matching owned OpenSSL slice. Do not use these
commands to overwrite the shipping vendor archive or SDK cache.

The backend source bundle retains 13 component source archives, upstream license
texts, patch files, build recipes, exact pins and per-archive digests. It includes
the SDK's pinned submodule source closure. This is corresponding-source material
for review; a release still needs its distribution/license decision. No signed
or distributable application is produced by these scripts.

## Actual results on 2026-10-21

Both dependency builds and both optional libnice/public SDK builds passed.
All 14 archives in each backend reported minOS 14.0. Actual SDK relay-only
bidirectional control exchanges passed through a TCP-only Coturn endpoint:

| Artifact | Observed execution | Selected transport evidence |
| --- | --- | --- |
| ARM64 | native on macOS 27.2 | both local candidates relay; 4 established TCP connections; no UDP TURN listener |
| x86_64 | Rosetta on macOS 27.2 | both local candidates relay; 4 established TCP connections; no UDP TURN listener |

`run_owned_nice_tcp_smoke.py` builds and runs that bounded public-SDK smoke.
Its result explicitly records process translation. Intel link output retained
upstream libffi assembly alignment warnings; the actual Rosetta exchange passed.
This is not an Intel hardware/media result.

The exact production baseline `40d0737` native Manager/controller CLI was then
built with the ARM64 backend. `package_owned_native_relink.py` retained **236
application object files**, the replaceable static transport archive, runtime
frameworks, source materials, hashes and a standalone `relink.py` recipe.
Relinking succeeded from those retained objects. The relinked CLI, StreamCore
and Syphon framework binaries all declared minOS 14.0, and the CLI linked no
Homebrew runtime dylibs.

The full actual TCP `--video-flow-only` fixture passed using that **packaged,
relinked executable**. It exercised the real Manager, Dispatcher, receiver
factory, controller sink and mixer with camera/screen H264, Opus, screen
approval/chooser denial/stop/retry/revoke, Program/Secondary/Clean return video,
stereo own-signal exclusion and mute/nonunity restore, private controls, full
rejoin and removal/end. Before and after rejoin, selected TCP TURN socket
receipts passed with no UDP TURN listener. The UDP relay allocation retained
its separate correct label. The ordinary guest HTML player preserved its clock
from 7.526 to 12.508 seconds through source/mute controls and replaced its stream
on the fresh lease.

Measured archive SHA-256 values:

| Artifact | SHA-256 |
| --- | --- |
| ARM64 optional backend | `af13ee4c331ddcc21338ffddeb7bd472b10996ad6b99509bf8d0f6acd5be10cd` |
| x86_64 optional backend | `ad69564eebd2d45b852f2d60965af173352ebbcfff479a7aaeec7c4ee1040358` |
| Packaged full-media ARM64 CLI | `3a87b8a785813549a6bf7a3a58635ec0f218e671288f7363dd85bd5e30613f5d` |

The host was macOS 27.2 (26B118), ARM64, Xcode 27.2 (27B5038j), Chrome
155.0.8059.85. Fixtures used synthetic capture and owned local Worker/Coturn
processes. No TCC, system network, trust-store, account or SDK defaults changed.

This proves pinned build inputs and usable relink materials, not byte-identical
clean rebuilds across directories/toolchains. A warm merge exposed archive
header timestamp differences despite identical member payloads. The helper now
sets `ZERO_AR_DATE=1`; two independent archive assemblies from the same compiled
inputs produced the identical SHA-256
`eec6ec7c9534ef7e10af49306cd1513a9e94316a2bc46b7923851c61b09056ef`.
Their member payload digest matched the measured full-media archive, and the
retained standalone recipe successfully relinked a separate copy with that
replacement archive. The original measured executable remained untouched.

An additional `lipo -create` and `xcodebuild -create-xcframework` packaging check
produced an owned optional `libdatachannel-nice.xcframework` containing ARM64
and x86_64. Extracted slices matched their corresponding input archive hashes,
and both slices reported minOS 14.0. The universal archive SHA-256 was
`6b54738c241ad0236f603011d6cfec12af29ec954a27454a069da1a603ed0abd`.
Its ARM input was the separately receipted warm archive with identical measured
member payloads; this packaging check does not substitute it for the full-media
artifact or adopt it into the shipping cache.

macOS 14 execution, Intel hardware
full media, Internet/mobile/Safari qualification, measured rendered A/V sync,
physical capture/playout/AEC and release adoption remain outside this evidence.
TLS remains disabled: the pinned libnice path does not construct a true RFC5245
TURN TLS stream. Neither an enum nor this TCP proof establishes TLS capability.
The original remaining issue criteria cannot be closed by adopting these local
artifacts implicitly.
