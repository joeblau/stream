#!/usr/bin/env python3
"""Exercise the actual native diagnostic with temporary libraries, never SDKs.

These fixtures prove diagnostic boundaries only. No vendor media is generated.
"""
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import sys
import tempfile


binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="stream-pro-prerequisites-") as directory:
    root = Path(directory)
    missing = str(root / "missing")
    environment = os.environ.copy()
    for name in ("STREAM_NDI_RUNTIME", "STREAM_NDI_SDK_ROOT", "STREAM_DECKLINK_RUNTIME",
                 "STREAM_DECKLINK_SDK_ROOT", "STREAM_ZOOM_SDK_ROOT", "STREAM_ZOOM_FRAMEWORK"):
        environment[name] = missing

    def probe(**overrides):
        result = subprocess.run([binary], env={**environment, **overrides},
                                capture_output=True, check=True, timeout=15)
        report = json.loads(result.stdout)
        assert report["schemaVersion"] == 2
        for key in ("ndi", "deckLink", "zoom"):
            assert report[key]["captureValidated"] is False
        assert report["zoom"]["returnValidated"] is False
        assert {number for gate in report["qualificationGates"] for number in gate["issues"]} == {160, 161, 167, 168, 176, 177}
        assert all(gate["qualified"] is False and gate["bridgeImplemented"] is False
                   for gate in report["qualificationGates"])
        return report

    absent = probe()
    assert all(absent[key]["status"] == "missing" for key in ("ndi", "deckLink", "zoom"))
    assert absent["ndi"]["checkedPaths"] == [missing]
    assert absent["ndi"]["receiveSymbolsPresent"] is False
    assert absent["ndi"]["sendSymbolsPresent"] is False

    invalid = root / "invalid.dylib"
    invalid.write_bytes(b"not a Mach-O library\n")
    failed = probe(STREAM_NDI_RUNTIME=str(invalid))
    assert failed["ndi"]["status"] == "loadFailed"
    assert failed["ndi"]["artifact"]["architectures"] == []
    assert failed["ndi"]["artifact"]["sha256"] == hashlib.sha256(invalid.read_bytes()).hexdigest()

    def library(name, symbols, universal=False):
        source = root / f"{name}.c"
        source.write_text('const char *NDIlib_version(void) { return "diagnostic-fixture-only"; }\n' +
                          "\n".join(f"void {symbol}(void) {{}}" for symbol in symbols))
        output = root / f"{name}.dylib"
        architectures = ["-arch", "arm64", "-arch", "x86_64"] if universal else []
        subprocess.run(["xcrun", "clang", *architectures, "-dynamiclib", str(source), "-o", str(output)],
                       capture_output=True, check=True, timeout=30)
        return str(output)

    partial_path = library("partial", ["NDIlib_initialize"])
    partial = probe(STREAM_NDI_RUNTIME=partial_path)
    assert partial["ndi"]["status"] == "loadable"
    assert partial["ndi"]["version"] == "diagnostic-fixture-only"
    assert partial["ndi"]["receiveSymbolsPresent"] is False
    assert partial["ndi"]["sendSymbolsPresent"] is False
    artifact = partial["ndi"]["artifact"]
    assert artifact["sha256"] == hashlib.sha256(Path(partial_path).read_bytes()).hexdigest()
    assert platform.machine() in artifact["architectures"]
    universal_path = library("universal", [], universal=True)
    universal = probe(STREAM_NDI_RUNTIME=universal_path)
    assert set(universal["ndi"]["artifact"]["architectures"]) == {"arm64", "x86_64"}

    # A library that exports every requested name still cannot qualify media,
    # ABI compatibility, permission, license, driver, or physical hardware.
    names = list(partial["ndi"]["symbols"])
    complete_path = library("complete", names)
    sdk = root / "sdk"
    sdk.mkdir()
    (sdk / "Processing.NDI.Lib.h").write_text("/* diagnostic fixture, no SDK */")
    (sdk / "DeckLinkAPI.h").write_text("/* diagnostic fixture, no SDK */")
    complete = probe(STREAM_NDI_RUNTIME=complete_path, STREAM_NDI_SDK_ROOT=str(sdk),
                     STREAM_DECKLINK_RUNTIME=partial_path, STREAM_DECKLINK_SDK_ROOT=str(sdk))
    assert complete["ndi"]["receiveSymbolsPresent"] is True
    assert complete["ndi"]["sendSymbolsPresent"] is True
    assert complete["ndi"]["sdkHeader"] == str(sdk / "Processing.NDI.Lib.h")
    assert complete["deckLink"]["symbols"]["CreateDeckLinkIteratorInstance"] is False
    assert complete["deckLink"]["sdkHeader"] == str(sdk / "DeckLinkAPI.h")

    framework = sdk / "ZoomSDK.framework"
    (framework / "Headers").mkdir(parents=True)
    (framework / "Resources").mkdir()
    (framework / "Headers" / "ZoomSDK.h").write_text("/* diagnostic fixture */")
    (framework / "ZoomSDK").write_bytes(Path(partial_path).read_bytes())
    with (framework / "Resources" / "Info.plist").open("wb") as handle:
        plistlib.dump({"CFBundleExecutable": "ZoomSDK", "CFBundlePackageType": "FMWK",
                       "CFBundleIdentifier": "test.stream.diagnostic",
                       "CFBundleShortVersionString": "fixture-only"}, handle)
    zoom = probe(STREAM_ZOOM_FRAMEWORK=str(framework), STREAM_ZOOM_SDK_ROOT=str(sdk))
    assert zoom["zoom"]["status"] == "presentNotLoaded"
    assert zoom["zoom"]["version"] == "fixture-only"
    assert zoom["zoom"]["sdkHeader"] == str(framework / "Headers" / "ZoomSDK.h")
    assert zoom["zoom"]["artifact"]["sha256"] == artifact["sha256"]

print("PASS: actual native missing/invalid/partial/complete/universal-runtime and Zoom-framework diagnostics; all media qualification gates remain closed")
