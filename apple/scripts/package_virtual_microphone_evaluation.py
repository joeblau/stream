#!/usr/bin/env python3
"""Build/inspect an O07 evaluation installer. Never install or activate it.

An owned ad-hoc bundle plus unsigned package is explicitly a local fixture.
Developer ID candidate mode requires both explicit identities; it does not
establish a supported HAL distribution decision or receiving-app compatibility.
"""
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile
import xml.etree.ElementTree as ET

BUNDLE = "StreamVirtualMicrophone.driver"
EXECUTABLE = "StreamVirtualMicrophone"
IDENTIFIER = "com.joeblau.Stream.VirtualMicrophonePrototype"
PACKAGE_IDENTIFIER = IDENTIFIER + ".pkg"
INSTALL_LOCATION = "/Library/Audio/Plug-Ins/HAL"
FACTORY_UUID = "D9CE8105-A63D-45C6-AF60-00C2307B2E47"
FACTORY = "StreamVirtualMicrophone_Create"
LICENSE = pathlib.Path(__file__).resolve().parents[1] / "prototypes/VirtualMicrophone/LICENSE-Apple.txt"


def run(*arguments):
    result = subprocess.run([str(a) for a in arguments], text=True, capture_output=True)
    if result.returncode:
        raise ValueError(f"{arguments[0]} failed ({result.returncode}): {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout + result.stderr


def require(condition, message):
    if not condition:
        raise ValueError(message)


def reject_links(root):
    require(not root.is_symlink(), "Bundle/payload symlinks are unsupported")
    for path in root.rglob("*"):
        mode = path.lstat().st_mode
        require(stat.S_ISREG(mode) or stat.S_ISDIR(mode), "Bundle/payload symlinks and special entries are unsupported")


def inspect_driver(bundle, *, owned, team=None, signed=True):
    bundle = pathlib.Path(bundle)
    require(bundle.is_dir() and bundle.name == BUNDLE, "Expected the exact owned prototype driver bundle")
    reject_links(bundle)
    allowed = {"Contents/Info.plist", "Contents/Resources/LICENSE-Apple.txt", f"Contents/MacOS/{EXECUTABLE}",
               "Contents/_CodeSignature/CodeResources"}
    require({p.relative_to(bundle).as_posix() for p in bundle.rglob("*") if p.is_file()} <= allowed,
            "Unexpected files in driver bundle")
    require({p.relative_to(bundle).as_posix() for p in bundle.rglob("*") if p.is_dir()}
            <= {"Contents", "Contents/MacOS", "Contents/Resources", "Contents/_CodeSignature"}, "Unexpected directories in driver bundle")
    with (bundle / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    require(info.get("CFBundleIdentifier") == IDENTIFIER and info.get("CFBundleExecutable") == EXECUTABLE
            and info.get("CFBundlePackageType") == "BNDL", "Wrong prototype bundle identity or executable")
    version = info.get("CFBundleShortVersionString", "")
    require(isinstance(version, str) and re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", version), "Invalid package version")
    require(isinstance(info.get("CFBundleVersion"), str) and re.fullmatch(r"[0-9]+", info["CFBundleVersion"]), "Invalid bundle build version")
    require(info.get("CFPlugInFactories") == {FACTORY_UUID: FACTORY}, "Unexpected HAL factory")
    require(info.get("CFPlugInTypes") == {"443ABAB8-E7B3-491A-B985-BEB9187030DB": [FACTORY_UUID]}, "Unexpected HAL plug-in type")
    require((bundle / "Contents/Resources/LICENSE-Apple.txt").is_file(), "Missing Apple sample license in the signed resource directory; rebuild the prototype")
    require((bundle / "Contents/Resources/LICENSE-Apple.txt").read_bytes() == LICENSE.read_bytes(), "Apple sample license must be preserved exactly")
    executable = bundle / "Contents/MacOS" / EXECUTABLE
    architectures = run("xcrun", "lipo", "-archs", executable).split()
    require(set(architectures) == {"arm64", "x86_64"} and len(architectures) == 2, "Driver must contain arm64 and x86_64")
    for architecture in architectures:
        require("BUNDLE" in run("xcrun", "otool", "-arch", architecture, "-hv", executable), "Expected a Mach-O bundle")
        symbols = run("xcrun", "nm", "-arch", architecture, "-gU", executable)
        require(any(line.split()[-1:] == ["_" + FACTORY] for line in symbols.splitlines()), "Missing exported HAL factory")
    if signed:
        run("codesign", "--verify", "--strict", "--all-architectures", bundle)
        signature = run("codesign", "--display", "--verbose=4", bundle)
        if owned:
            require("Signature=adhoc" in signature and "Authority=" not in signature, "Owned mode requires an ad-hoc signature")
        else:
            require(team is not None and re.fullmatch(r"[A-Z0-9]{10}", team), "An explicit Developer ID team is required")
            require("Authority=Developer ID Application:" in signature and f"TeamIdentifier={team}\n" in signature,
                    "Candidate driver must have the requested Developer ID Application signature; ad-hoc is refused")
            requirement = f'anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "{team}" and identifier "{IDENTIFIER}"'
            run("codesign", "--verify", "--strict", "--all-architectures", "-R", requirement, bundle)
    return {"version": version, "architectures": sorted(architectures), "executableSHA256": hashlib.sha256(executable.read_bytes()).hexdigest()}


def check_installer_signature_report(report, team):
    require(team is not None and re.fullmatch(r"[A-Z0-9]{10}", team), "An explicit Developer ID team is required")
    leaves = re.findall(r"(?m)^\s*1\. Developer ID Installer: [^\r\n]+ \(([A-Z0-9]{10})\)\s*$", report)
    require(leaves == [team], "Candidate package requires the matching Developer ID Installer leaf team")


def inspect_package(package, *, owned, team=None):
    package = pathlib.Path(package)
    if not owned:
        signature = run("pkgutil", "--check-signature", package)
        check_installer_signature_report(signature, team)
    else:
        result = subprocess.run(["pkgutil", "--check-signature", str(package)], text=True, capture_output=True)
        require("Status: no signature" in result.stdout + result.stderr, "Owned fixture package must be explicitly unsigned")
    with tempfile.TemporaryDirectory(prefix="inspect-vmic-", dir=package.parent) as temporary:
        expanded = pathlib.Path(temporary) / "expanded"
        run("pkgutil", "--expand-full", package, expanded)
        reject_links(expanded)
        require({p.name for p in expanded.iterdir()} == {"Bom", "PackageInfo", "Payload"}, "Unexpected package entries or installer scripts")
        info = ET.parse(expanded / "PackageInfo").getroot()
        require(info.tag == "pkg-info" and info.get("identifier") == PACKAGE_IDENTIFIER
                and info.get("install-location") == INSTALL_LOCATION and info.get("auth") == "root", "Unexpected installer identity/location/authorization")
        relocate = info.find("relocate")
        require(info.find("scripts") is None and (relocate is None or (not relocate.attrib and len(relocate) == 0))
                and info.get("relocatable") == "false" and info.get("postinstall-action") == "none", "Installer scripts/relocation/restart are unsupported")
        payload = expanded / "Payload"
        require(payload.is_dir() and {p.name for p in payload.iterdir()} == {BUNDLE}, "Installer payload must contain only the owned driver")
        receipt = inspect_driver(payload / BUNDLE, owned=owned, team=team)
        require(info.get("version") == receipt["version"], "Installer and bundle versions differ")
        bundles = info.findall("bundle")
        require(len(bundles) == 1 and bundles[0].get("id") == IDENTIFIER
                and bundles[0].get("path") in [BUNDLE, "./" + BUNDLE], "Unexpected installer bundle target")
        for tag in ["bundle-version", "upgrade-bundle", "strict-identifier"]:
            checked = info.findall(tag + "/bundle")
            require(len(checked) == 1 and checked[0].attrib == {"id": IDENTIFIER}, "Missing exact version/upgrade/strict-identity installer policy")
        receipt["packageSHA256"] = hashlib.sha256(package.read_bytes()).hexdigest()
        return receipt


def build(args):
    require(args.acknowledge_unqualified_hal_route, "Explicit --acknowledge-unqualified-hal-route is required; O07 remains unproven")
    output = args.output.absolute()
    require(not output.exists() and not output.is_symlink(), "Output directory must not already exist")
    require(output.parent.is_dir(), "Create the owned output parent directory first")
    if args.owned_test:
        require(not any([args.application_identity, args.installer_identity, args.team_id, args.notary_profile, args.skip_notarization]),
                "Owned mode accepts no release identities or notarization options")
    else:
        require(args.application_identity and args.application_identity != "-" and args.installer_identity and args.installer_identity != "-",
                "Explicit Developer ID Application and Installer identities are required; ad-hoc is refused")
        require(args.team_id and re.fullmatch(r"[A-Z0-9]{10}", args.team_id), "An explicit Developer ID team is required")
        require(bool(args.notary_profile) != bool(args.skip_notarization), "Choose an explicit notary profile or --skip-notarization candidate")
    original = inspect_driver(args.driver, owned=args.owned_test, signed=False)
    with tempfile.TemporaryDirectory(prefix="build-vmic-", dir=output.parent) as temporary:
        work = pathlib.Path(temporary)
        staging = work / "root"; staging.mkdir()
        bundle = staging / BUNDLE
        shutil.copytree(args.driver, bundle)
        if args.owned_test:
            run("codesign", "--force", "--sign", "-", "--timestamp=none", bundle)
        else:
            run("codesign", "--force", "--options", "runtime", "--timestamp", "--sign", args.application_identity, bundle)
        receipt = inspect_driver(bundle, owned=args.owned_test, team=args.team_id)
        components = work / "components.plist"
        with components.open("wb") as stream:
            plistlib.dump([{"RootRelativeBundlePath": BUNDLE, "BundleIsRelocatable": False,
                           "BundleIsVersionChecked": True, "BundleHasStrictIdentifier": True,
                           "BundleOverwriteAction": "upgrade"}], stream)
        artifacts = work / "artifacts"; artifacts.mkdir()
        name = f"StreamVirtualMicrophone-evaluation-{receipt['version']}-" + ("UNSIGNED-OWNED-TEST.pkg" if args.owned_test else "DeveloperID-candidate.pkg")
        package = artifacts / name
        unsigned = package if args.owned_test else work / "unsigned.pkg"
        run("pkgbuild", "--root", staging, "--component-plist", components, "--install-location", INSTALL_LOCATION,
            "--identifier", PACKAGE_IDENTIFIER, "--version", receipt["version"], "--ownership", "recommended", unsigned)
        if not args.owned_test:
            run("productsign", "--timestamp", "--sign", args.installer_identity, unsigned, package)
        receipt = inspect_package(package, owned=args.owned_test, team=args.team_id)
        if args.notary_profile:
            result = json.loads(run("xcrun", "notarytool", "submit", package, "--keychain-profile", args.notary_profile, "--wait", "--output-format", "json"))
            require(result.get("status") == "Accepted", "Notarization was not accepted")
            run("xcrun", "stapler", "staple", package)
            run("xcrun", "stapler", "validate", package)
            run("spctl", "--assess", "--type", "install", package)
            receipt = inspect_package(package, owned=False, team=args.team_id)
        receipt.update({"evaluationOnly": True, "supportedHALDecision": False, "installedOrActivated": False,
                        "deviceConsumerQualified": False, "installLocation": INSTALL_LOCATION,
                        "runtimeCallbackQualified": False, "sourceProvenanceQualified": False,
                        "inputExecutableSHA256": original["executableSHA256"],
                        "bundleSigning": "ad-hoc" if args.owned_test else "Developer ID Application",
                        "installerSigning": "unsigned owned test" if args.owned_test else "Developer ID Installer",
                        "notarized": bool(args.notary_profile), "installerScripts": False})
        (artifacts / "evaluation-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        artifacts.rename(output)
    print(f"Built evaluation artifact: {output / name}; never installed or activated. O07/O08 remain unqualified.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--driver", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--owned-test", action="store_true")
    mode.add_argument("--developer-id-candidate", action="store_true")
    parser.add_argument("--acknowledge-unqualified-hal-route", action="store_true")
    parser.add_argument("--application-identity")
    parser.add_argument("--installer-identity")
    parser.add_argument("--team-id")
    parser.add_argument("--notary-profile")
    parser.add_argument("--skip-notarization", action="store_true")
    args = parser.parse_args()
    try:
        build(args)
    except (ValueError, OSError, ET.ParseError, plistlib.InvalidFileException, json.JSONDecodeError) as error:
        parser.exit(1, f"Evaluation packaging refused: {error}\n")


if __name__ == "__main__":
    main()
