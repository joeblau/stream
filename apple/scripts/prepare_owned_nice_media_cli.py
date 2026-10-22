#!/usr/bin/env python3
"""Prepare a fresh owned full-source guest CLI with an explicit optional backend.

The existing derived tree is read-only cache input. No shipping archive,
package checkout, global SDK cache, credential store or production spec changes.
Build the generated project separately with the shared native build-slot helper.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess

from build_owned_nice_transport import archive_floor, digest, version

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--backend-build-dir", type=Path, required=True)
parser.add_argument("--reference-derived", type=Path, required=True)
parser.add_argument("--output-dir", type=Path, required=True)
parser.add_argument("--vendor-root", type=Path, required=True)
parser.add_argument("--tls", action="store_true")
args = parser.parse_args()
os.umask(0o077)
repository = Path(__file__).resolve().parents[2]
backend, reference, output = args.backend_build_dir.resolve(), args.reference_derived.resolve(), args.output_dir.resolve()
receipt = json.loads((backend / "nice-transport-build.json").read_text())
archive = backend / "libdatachannel-nice-complete.a"
if digest(archive) != receipt["archiveSHA256"] or version(archive_floor(archive, receipt["architecture"])) > version("14.0"):
    raise RuntimeError("Optional backend digest or macOS 14 build floor differs")
if args.tls and not receipt.get("ownedTLSImplementation"):
    raise RuntimeError("Explicit TLS preparation requires the recorded owned TLS implementation")
if output.exists():
    raise RuntimeError("Choose a fresh owned output directory; existing files are preserved")
if output.is_relative_to(reference):
    raise RuntimeError("Owned output must be outside the read-only reference tree")
if not (reference / "SourcePackages/workspace-state.json").is_file():
    raise RuntimeError("Reference must be an existing qualified derived cache")
output.mkdir(parents=True, mode=0o700)
project, derived = output / "project", output / "derived"
project.mkdir(mode=0o700)
script = (repository / "apple/scripts/run_native_interview_return_audio_harness.zsh").read_text()
ruby = script.split("<<'RUBY'\n", 1)[1].split("\nRUBY", 1)[0]
env = os.environ.copy()
env.update(STREAM_VENDOR_ROOT=str(args.vendor_root.resolve()), STREAM_INTERVIEW_RETURN_VIDEO_VALIDATION="1",
           STREAM_INTERVIEW_RETURN_CLI_SOURCE="native_interview_return_video_cli.swift")
subprocess.run(["ruby", "-ryaml", "-rjson", "-", str(project)], cwd=repository / "apple", env=env, input=ruby, text=True, check=True)
controller = project / "fixtures/InterviewProgramController.swift"
source = controller.read_text()
original = 'DesktopResilienceCoordinator(url: DesktopStorage.projectDirectory.appendingPathComponent("resilience.json"))'
owned = original[:-1] + ', observeSystem: false, initialSessionState: .unlocked)'
if source.count(original) == 1:
    source = source.replace(original, owned)
elif source.count(owned) != 1:
    raise RuntimeError("Owned headless session boundary changed")
controller.write_text(source)
spec_path = project / "project.json"
spec = json.loads(spec_path.read_text())
for target in spec["targets"].values():
    settings = target["settings"]["base"]
    settings.update(OTHER_SWIFT_FLAGS="$(inherited) -j2", SWIFT_ENABLE_BATCH_MODE="NO", ARCHS=receipt["architecture"])
settings = spec["targets"]["NativeInterviewReturnAudioCLI"]["settings"]["base"]
settings["GCC_PREPROCESSOR_DEFINITIONS"] = "$(inherited) STREAM_GUEST_VALIDATION STREAM_NATIVE_NICE_TURN_TCP" + (" STREAM_NATIVE_NICE_TURN_TLS" if args.tls else "")
flags = settings.get("OTHER_LDFLAGS", [])
settings["OTHER_LDFLAGS"] = ([flags] if isinstance(flags, str) else flags) + receipt["additionalSystemLinkFlags"]
spec_path.write_text(json.dumps(spec, indent=2) + "\n")
subprocess.run(["xcodegen", "generate", "--spec", str(spec_path), "--project", str(project)], check=True)
subprocess.run(["cp", "-cR", str(reference), str(derived)], check=True)
workspace = derived / "SourcePackages/workspace-state.json"
workspace.write_text(workspace.read_text().replace(str(reference), str(derived)).replace(str(args.reference_derived), str(derived)))
replaced = 0
for info in (derived / "SourcePackages/artifacts").glob("**/libdatachannel.xcframework/Info.plist"):
    value = plistlib.loads(info.read_bytes())
    for library in value["AvailableLibraries"]:
        if library["SupportedPlatform"] != "macos":
            continue
        library["SupportedArchitectures"] = [receipt["architecture"]]
        destination = info.parent / library["LibraryIdentifier"] / library["LibraryPath"]
        destination.write_bytes(archive.read_bytes())
        replaced += 1
    info.write_bytes(plistlib.dumps(value))
if not replaced:
    raise RuntimeError("Reference has no owned macOS transport artifact to overlay")
(derived / "Build/Products/Debug/libdatachannel.a").write_bytes(archive.read_bytes())
proof = {"backendSHA256": digest(archive), "architecture": receipt["architecture"], "tlsExplicitlyEnabled": args.tls,
         "repositoryHEAD": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository, text=True).strip(),
         "shippingControllerSHA256": digest(repository / "apple/StreamMac/StreamController.swift"),
         "generatedControllerSHA256": digest(controller), "projectSHA256": digest(spec_path),
         "scope": "prepared owned full-source fixture; not build/runtime qualification or shipping adoption"}
(output / "prepared-project.json").write_text(json.dumps(proof, indent=2) + "\n")
print(json.dumps(proof))
