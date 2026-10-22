# Virtual microphone evaluation packaging

O07 (#173) has no supported shipping-path decision. This tool prepares a
separate **evaluation** installer for the existing public AudioServerPlugIn
prototype; it does not promote that prototype to O08 (#174), implement shipping
bus controls or establish installed-device/client compatibility.

The tool never executes an installer, changes HAL/default devices, restarts
Core Audio, installs/activates/removes a driver or changes security settings.
Its output contains no installer scripts. Installation, updates, restart and
removal remain separately authorized operator qualification work on test Macs.

## Owned local reproduction

```sh
zsh apple/scripts/run_virtual_microphone_package_harness.zsh
```

Each run uses a fresh build/artifact directory. It builds the actual universal
arm64/x86_64 driver, copies it to staging, signs only that copy ad hoc with no
timestamp/identity, and creates an **unsigned owned test** package. The builder
preserves Apple's sample license under `Contents/Resources`; the earlier
`Contents/LICENSE-Apple.txt` placement caused real `codesign` to refuse the
license as unsigned nested code. Existing legacy cache cleanup removes only
that exact unchanged regular license; symlinks/special/changed entries refuse.
`STREAM_VMIC_BUILD_DIR` selects a fresh standalone driver build directory.

The package has one fixed payload, `StreamVirtualMicrophone.driver`, targeting
`/Library/Audio/Plug-Ins/HAL`. The component is nonrelocatable, version checked,
strict about its bundle identifier and configured for an atomic bundle upgrade.
The inspector expands the actual package locally, checks those policies and
rejects foreign payloads, scripts, restart actions, symlinks, special entries,
unknown files/directories, malformed identities, missing CPU slices, absent
factory exports, changed licenses and invalid signatures. Existing output
directories are refused; input bundles are preserved.

The fixture dynamically loads the **exact extracted ad-hoc signed executable**
and runs the existing actual AudioServerPlugIn factory/PCM/lifecycle callbacks.
Its report links input executable, signed extracted executable, package and
source hashes, compiler/SDK and executed host architecture. Both CPU slices are
inspected; only the host slice executes. Controlled native host callbacks are
in process, with no installed HAL device or receiving application. This is not
measured sandbox IPC, cross-process audio, system CPU/latency, A/V sync, or Intel
execution on an Apple-silicon host.

The 2026-10-22 owned run passed actual extracted-driver callbacks (energy
48.25474, 512-frame delay, 44.1/48 kHz, malformed/NaN/underrun handling,
independent stop, clock/session reset and concurrent ring-wrap integrity) and
20 refusal/immutability cases. Those include real signature-seal tampering,
thin architecture, foreign payload/location, relocation/version policy,
special/empty-directory/symlink entries, preserved license, FIFO cache refusal,
explicit-mode gates and ad-hoc/unsigned candidate refusal. Installer team
parsing binds the actual unique leaf certificate line; an expected team in a
path or company name cannot satisfy a different leaf's team.

## Explicit Developer ID evaluation candidate

The candidate path is implemented but has **not** been exercised with a real
identity, notarization service, installation or receiving client. It requires
both explicit signing identities and their team. It refuses ad-hoc application
signatures and unsigned or differently teamed installer signatures. No signing
identity is discovered or selected automatically, and no application release
script silently includes this package.

After the normal driver build, an authorized release operator can run:

```sh
python3 apple/scripts/package_virtual_microphone_evaluation.py \
  --driver apple/build/virtual-microphone-prototype/StreamVirtualMicrophone.driver \
  --output /path/to/new-evaluation-output \
  --developer-id-candidate --acknowledge-unqualified-hal-route \
  --application-identity "$STREAM_VMIC_APPLICATION_IDENTITY" \
  --installer-identity "$STREAM_VMIC_INSTALLER_IDENTITY" \
  --team-id "$STREAM_VMIC_TEAM_ID" --notary-profile "$STREAM_VMIC_NOTARY_PROFILE"
```

Only this explicit candidate mode may use the supplied identities and notary
profile. `--skip-notarization` is an explicit alternative to a profile for an
incomplete signed candidate; the receipt marks it unnotarized. The notarizing
path requires acceptance, staples/validates the package and assesses it as an
installer before publishing the artifact. Developer ID application signatures
are checked against Apple's certificate requirement and exact team; installer
verification uses the actual leaf certificate team. Artifact construction does
not prove a supported update/removal process or Mac App Store compatibility.

Every receipt states `evaluationOnly`, `supportedHALDecision: false`,
`installedOrActivated: false` and `deviceConsumerQualified: false`. Package
inspection alone also states `runtimeCallbackQualified: false` and
`sourceProvenanceQualified: false`: symbol/plist/signature checks do not execute
the code or attest its source. The separate owned fixture's linked callback and
build evidence has the narrower in-process scope above. O07 and O08 remain open
until their original installed/signed/client acceptance and decision are met.
