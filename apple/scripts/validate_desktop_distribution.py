#!/usr/bin/env python3
"""Audit bundle declarations; --require-signed also audits the shipped signatures."""
import argparse
import pathlib
import plistlib
import re
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", type=pathlib.Path)
parser.add_argument("--require-signed", action="store_true", help="Require Developer ID, timestamp, hardened runtime, and actual entitlements")
args = parser.parse_args()
app = args.app
source = pathlib.Path(__file__).resolve().parents[1]
with (source / "StreamMac/StreamMac.entitlements").open("rb") as file:
    entitlements = plistlib.load(file)
required = ["app-sandbox", "device.camera", "device.microphone", "device.audio-input", "network.client", "network.server",
            "files.user-selected.read-write", "files.bookmarks.app-scope"]
for suffix in required:
    assert entitlements.get("com.apple.security." + suffix) is True, suffix
assert not entitlements.get("com.apple.security.get-task-allow"), "Debug entitlement in distribution declaration"
with (app / "Contents/Info.plist").open("rb") as file:
    info = plistlib.load(file)
assert info["CFBundleIdentifier"] == "com.joeblau.StreamMac"
for key in ["NSCameraUsageDescription", "NSMicrophoneUsageDescription"]:
    assert info.get(key), key
executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
assert executable.is_file(), executable
assert entitlements.get("com.apple.developer.system-extension.install") is True
camera = app / "Contents/Library/SystemExtensions/com.joeblau.StreamMac.CameraExtension.systemextension"
with (camera / "Contents/Info.plist").open("rb") as file:
    camera_info = plistlib.load(file)
assert camera_info["CFBundleIdentifier"] == "com.joeblau.StreamMac.CameraExtension"
team = info.get("StreamVirtualOutputTeam", "")
assert re.fullmatch(r"[A-Z0-9]{10}", team), "Unexpanded or invalid virtual-output team"
group = team + ".com.joeblau.Stream.VirtualOutputs"
assert info.get("StreamVirtualOutputAppGroup") == group
assert camera_info.get("StreamVirtualOutputTeam") == team
assert camera_info.get("StreamVirtualOutputAppGroup") == group
assert camera_info.get("CMIOExtension", {}).get("CMIOExtensionMachServiceName") == group + ".CameraExtension"
assert (camera / "Contents/MacOS" / camera_info["CFBundleExecutable"]).is_file()
with (source / "StreamCameraExtension/StreamCameraExtension.entitlements").open("rb") as file:
    camera_entitlements = plistlib.load(file)
assert camera_entitlements.get("com.apple.security.app-sandbox") is True
assert camera_entitlements.get("com.apple.security.application-groups") == ["$(DEVELOPMENT_TEAM).com.joeblau.Stream.VirtualOutputs"]
assert "$(DEVELOPMENT_TEAM).com.joeblau.Stream.VirtualOutputs" in entitlements.get("com.apple.security.application-groups", [])
assert not camera_entitlements.get("com.apple.security.get-task-allow")
helper = app / "Contents/Helpers/StreamBrowserAudioHelper.app"
with (helper / "Contents/Info.plist").open("rb") as file:
    helper_info = plistlib.load(file)
assert helper_info["CFBundleIdentifier"] == "com.joeblau.StreamBrowserAudioHelper"
assert (helper / "Contents/MacOS" / helper_info["CFBundleExecutable"]).is_file()
with (source / "BrowserAudioHelper/BrowserAudioHelper.entitlements").open("rb") as file:
    helper_entitlements = plistlib.load(file)
for suffix in ["app-sandbox", "network.client", "network.server"]:
    assert helper_entitlements.get("com.apple.security." + suffix) is True
assert helper_entitlements.get("com.apple.security.application-groups") == ["group.com.joeblau.Stream"]
assert not helper_entitlements.get("com.apple.security.get-task-allow")
if args.require_signed:
    # Checking the source plist alone cannot establish what was signed into an
    # exported archive. Inspect every executable bundle independently as well as
    # verifying the complete nested-code seal.
    subprocess.run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)], check=True)

    def expanded(value):
        if isinstance(value, str):
            return value.replace("$(DEVELOPMENT_TEAM)", team).replace("$(AppIdentifierPrefix)", team + ".")
        if isinstance(value, list):
            return [expanded(item) for item in value]
        return value

    for bundle, declared in [(app, entitlements), (camera, camera_entitlements), (helper, helper_entitlements)]:
        actual = plistlib.loads(subprocess.check_output(
            ["codesign", "--display", "--entitlements", ":-", str(bundle)], stderr=subprocess.PIPE))
        assert not actual.get("com.apple.security.get-task-allow"), f"Debug entitlement in {bundle}"
        for key, value in declared.items():
            assert actual.get(key) == expanded(value), f"Signed entitlement mismatch in {bundle}: {key}"
        signature = subprocess.run(["codesign", "--display", "--verbose=4", str(bundle)],
                                   check=True, capture_output=True, text=True).stderr
        assert f"TeamIdentifier={team}" in signature, f"Signing team mismatch in {bundle}"
        assert re.search(r"^Authority=Developer ID Application:", signature, re.MULTILINE), f"Developer ID missing in {bundle}"
        assert re.search(r"^CodeDirectory .*flags=.*\bruntime\b", signature, re.MULTILINE), f"Hardened runtime missing in {bundle}"
        assert re.search(r"^Timestamp=.+", signature, re.MULTILINE), f"Secure timestamp missing in {bundle}"
architectures = subprocess.check_output(["lipo", "-archs", str(executable)], text=True).strip()
print("Desktop bundle and sandbox declarations validated:", architectures)
print("Embedded CMIO camera, matching team/App Group namespace and sandbox declarations validated.")
print("Embedded browser helper and sandbox declarations validated; production audio route remains gated.")
if args.require_signed:
    print("Developer ID, secure timestamps, hardened runtime, and embedded signed entitlements validated.")
    print("Notarization and Gatekeeper acceptance require the release workflow's subsequent checks.")
else:
    print("Developer ID signature, hardened runtime and notarization require the release workflow.")
