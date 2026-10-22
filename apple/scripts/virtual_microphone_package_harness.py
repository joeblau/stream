#!/usr/bin/env python3
"""Owned actual pkgbuild/codesign fixture; never execute an installer."""
import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import platform
import plistlib
import shutil
import subprocess
import sys

SCRIPT = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("evaluation", SCRIPT / "package_virtual_microphone_evaluation.py")
evaluation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evaluation)


def execute(*arguments, success=True, timeout=30):
    result = subprocess.run([str(a) for a in arguments], capture_output=True, text=True, timeout=timeout)
    if (result.returncode == 0) != success:
        raise AssertionError(result.stdout + result.stderr)
    return result.stdout + result.stderr


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--driver", type=pathlib.Path, required=True)
    parser.add_argument("--artifacts", type=pathlib.Path, required=True)
    parser.add_argument("--callback-harness", type=pathlib.Path, required=True)
    args = parser.parse_args()
    args.driver = args.driver.resolve()
    root = args.artifacts.resolve(); root.mkdir()
    results = []
    def refused(label, operation):
        try:
            operation()
        except ValueError as error:
            results.append({"case": label, "refused": True, "reason": str(error)})
            return
        raise AssertionError("Accepted invalid evaluation artifact: " + label)
    original = hashlib.sha256((args.driver / "Contents/MacOS/StreamVirtualMicrophone").read_bytes()).hexdigest()
    output = root / "owned"
    base = [sys.executable, SCRIPT / "package_virtual_microphone_evaluation.py", "--driver", args.driver]
    execute(*base, "--output", output, "--owned-test", "--acknowledge-unqualified-hal-route")
    package = next(output.glob("*.pkg"))
    receipt = json.loads((output / "evaluation-receipt.json").read_text())
    assert receipt["inputExecutableSHA256"] == original
    assert all(receipt[k] is False for k in ["supportedHALDecision", "installedOrActivated", "deviceConsumerQualified", "runtimeCallbackQualified", "sourceProvenanceQualified", "notarized", "installerScripts"])
    assert receipt["architectures"] == ["arm64", "x86_64"]
    assert receipt["bundleSigning"] == "ad-hoc" and receipt["installerSigning"] == "unsigned owned test"
    verified = evaluation.inspect_package(package, owned=True)
    assert verified["packageSHA256"] == receipt["packageSHA256"]
    expanded = root / "expanded"
    execute("pkgutil", "--expand-full", package, expanded)
    signed = expanded / "Payload" / evaluation.BUNDLE
    binary = signed / "Contents/MacOS/StreamVirtualMicrophone"
    assert hashlib.sha256(binary.read_bytes()).hexdigest() == receipt["executableSHA256"]
    callback_log = execute(args.callback_harness.resolve(), binary)
    (root / "packaged-driver-callbacks.log").write_text(callback_log)
    results.append({"case": "actual-extracted-signed-factory-and-callbacks", "passed": True,
                    "executableSHA256": receipt["executableSHA256"], "packageSHA256": receipt["packageSHA256"]})
    assert hashlib.sha256((args.driver / "Contents/MacOS/StreamVirtualMicrophone").read_bytes()).hexdigest() == original, "Packaging changed the source bundle"
    refused("ad-hoc-driver-refused-as-Developer-ID", lambda: evaluation.inspect_driver(signed, owned=False, team="AAAAAAAAAA"))
    refused("unsigned-package-refused-as-Developer-ID", lambda: evaluation.inspect_package(package, owned=False, team="AAAAAAAAAA"))
    evaluation.check_installer_signature_report("Package: /tmp/candidate.pkg\nCertificate Chain:\n  1. Developer ID Installer: Owned fixture (AAAAAAAAAA)\n", "AAAAAAAAAA")
    for report in [
        "Package: /tmp/(AAAAAAAAAA)/candidate.pkg\n  1. Developer ID Installer: Foreign team (BBBBBBBBBB)\n",
        "Package: /tmp/candidate.pkg\n  1. Developer ID Installer: Company (AAAAAAAAAA) (BBBBBBBBBB)\n",
        "  1. Developer ID Installer: Expected (AAAAAAAAAA)\n  1. Developer ID Installer: Foreign (BBBBBBBBBB)\n",
    ]:
        refused("installer-leaf-team-bound-to-certificate", lambda: evaluation.check_installer_signature_report(report, "AAAAAAAAAA"))
    for label, options in [
        ("explicit-ack-required", ["--owned-test"]),
        ("owned-mode-refuses-release-options", ["--owned-test", "--team-id", "AAAAAAAAAA", "--acknowledge-unqualified-hal-route"]),
        ("candidate-refuses-ad-hoc-identities", ["--developer-id-candidate", "--application-identity", "-", "--installer-identity", "-", "--team-id", "AAAAAAAAAA", "--skip-notarization", "--acknowledge-unqualified-hal-route"]),
    ]:
        destination = root / label
        execute(*base, "--output", destination, *options, success=False)
        assert not destination.exists()
        results.append({"case": label, "refused": True})
    sentinel = output / "retain.txt"; sentinel.write_text("owned original")
    execute(*base, "--output", output, "--owned-test", "--acknowledge-unqualified-hal-route", success=False)
    assert sentinel.read_text() == "owned original"
    results.append({"case": "existing-output-preserved", "refused": True})

    def clone(label):
        parent = root / label; parent.mkdir()
        bundle = parent / evaluation.BUNDLE
        shutil.copytree(signed, bundle)
        return bundle
    unsafe = clone("symlink")
    (unsafe / "Contents/Resources/foreign").symlink_to(sentinel)
    refused("symlink-payload", lambda: evaluation.inspect_driver(unsafe, owned=True))
    assert sentinel.read_text() == "owned original"
    special = clone("special")
    os.mkfifo(special / "Contents/Resources/special")
    refused("special-payload-entry", lambda: evaluation.inspect_driver(special, owned=True))
    extra = clone("empty-directory")
    (extra / "Contents/Unexpected").mkdir()
    refused("unexpected-empty-directory", lambda: evaluation.inspect_driver(extra, owned=True))
    license = clone("changed-license")
    (license / "Contents/Resources/LICENSE-Apple.txt").write_text("not the preserved sample license")
    refused("changed-Apple-license", lambda: evaluation.inspect_driver(license, owned=True))
    tampered = clone("tampered")
    info_path = tampered / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes()); info["CFBundleName"] = "Tampered signed resource"
    info_path.write_bytes(plistlib.dumps(info))
    refused("actual-signature-seal-tamper", lambda: evaluation.inspect_driver(tampered, owned=True))
    thin = clone("thin")
    thin_binary = thin / "Contents/MacOS/StreamVirtualMicrophone"
    execute("xcrun", "lipo", binary, "-thin", "arm64", "-output", thin_binary)
    refused("missing-x86_64-slice", lambda: evaluation.inspect_driver(thin, owned=True, signed=False))

    def raw_package(label, *, location=evaluation.INSTALL_LOCATION, foreign=False, relocatable=False, version_checked=True):
        directory = root / label; directory.mkdir()
        staging = directory / "root"; staging.mkdir()
        shutil.copytree(signed, staging / evaluation.BUNDLE)
        if foreign:
            (staging / "foreign.driver").mkdir()
            (staging / "foreign.driver/unrelated").write_text("must never be included")
        components = directory / "components.plist"
        components.write_bytes(plistlib.dumps([{"RootRelativeBundlePath": evaluation.BUNDLE,
            "BundleIsRelocatable": relocatable, "BundleIsVersionChecked": version_checked,
            "BundleHasStrictIdentifier": True, "BundleOverwriteAction": "upgrade"}]))
        candidate = directory / "rejected.pkg"
        execute("pkgbuild", "--root", staging, "--component-plist", components, "--install-location", location,
                "--identifier", evaluation.PACKAGE_IDENTIFIER, "--version", receipt["version"], "--ownership", "recommended", candidate)
        return candidate
    for label, changes in [
        ("foreign-payload", {"foreign": True}), ("foreign-install-location", {"location": "/tmp/foreign"}),
        ("relocatable-bundle", {"relocatable": True}), ("unchecked-downgrade", {"version_checked": False}),
    ]:
        candidate = raw_package(label, **changes)
        refused(label, lambda: evaluation.inspect_package(candidate, owned=True))

    # The actual builder must refuse a legacy FIFO before cmp can wait on it.
    legacy = root / "legacy-fifo-cache" / evaluation.BUNDLE / "Contents"
    legacy.mkdir(parents=True)
    os.mkfifo(legacy / "LICENSE-Apple.txt")
    environment = os.environ.copy(); environment["STREAM_VMIC_BUILD_DIR"] = str(legacy.parents[1])
    result = subprocess.run(["zsh", str(SCRIPT / "build_virtual_microphone_prototype.zsh")],
                            env=environment, capture_output=True, text=True, timeout=15)
    assert result.returncode != 0 and "Unexpected legacy license entry" in result.stderr
    assert (legacy / "LICENSE-Apple.txt").is_fifo()
    results.append({"case": "builder-refuses-and-preserves-legacy-FIFO", "refused": True})
    report = {"evaluationOnly": True, "installedHALQualified": False, "receivingAppQualified": False,
              "inProcessPackagedDriverCallbacksPassed": True, "executedArchitectures": [platform.machine()],
              "compiler": execute("xcrun", "clang", "--version").splitlines()[0],
              "sdkVersion": execute("xcrun", "--sdk", "macosx", "--show-sdk-version").strip(),
              "sourceSHA256": {name: hashlib.sha256((SCRIPT.parent / name).read_bytes()).hexdigest() for name in [
                  "prototypes/VirtualMicrophone/StreamVirtualMicrophone.c", "prototypes/VirtualMicrophone/StreamLoopback.c",
                  "prototypes/VirtualMicrophone/StreamLoopback.h", "prototypes/VirtualMicrophone/Info.plist",
                  "prototypes/VirtualMicrophone/LICENSE-Apple.txt", "scripts/studio_virtual_microphone_harness.c",
                  "scripts/build_virtual_microphone_prototype.zsh", "scripts/package_virtual_microphone_evaluation.py"]},
              "packageReceipt": receipt, "cases": results}
    (root / "package-validation-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"PASS: real ad-hoc universal driver, actual unsigned fixed-HAL package, expanded exact signed payload and native factory/PCM/lifecycle callbacks; {len(results)-1} refusal/immutability cases. No installer execution, identity use, notarization, HAL install/activation, CoreAudio restart or default-device mutation. Artifacts: {root}")


if __name__ == "__main__":
    main()
