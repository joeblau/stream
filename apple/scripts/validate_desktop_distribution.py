#!/usr/bin/env python3
"""Audit declared desktop sandbox and built bundle without requiring signing secrets."""
import pathlib
import plistlib
import re
import subprocess
import sys

app = pathlib.Path(sys.argv[1])
source = pathlib.Path(__file__).resolve().parents[1]
with (source / "StreamMac/StreamMac.entitlements").open("rb") as file:
    entitlements = plistlib.load(file)
required = ["app-sandbox", "device.camera", "device.microphone", "network.client", "network.server",
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
architectures = subprocess.check_output(["lipo", "-archs", str(executable)], text=True).strip()
print("Desktop bundle and sandbox declarations validated:", architectures)
print("Embedded CMIO camera, matching team/App Group namespace and sandbox declarations validated.")
print("Embedded browser helper and sandbox declarations validated; production audio route remains gated.")
print("Developer ID signature, hardened runtime and notarization require the release workflow.")
