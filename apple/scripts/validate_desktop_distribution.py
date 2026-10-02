#!/usr/bin/env python3
"""Audit declared desktop sandbox and built bundle without requiring signing secrets."""
import pathlib
import plistlib
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
architectures = subprocess.check_output(["lipo", "-archs", str(executable)], text=True).strip()
print("Desktop bundle and sandbox declarations validated:", architectures)
print("Developer ID signature, hardened runtime and notarization require the release workflow.")
