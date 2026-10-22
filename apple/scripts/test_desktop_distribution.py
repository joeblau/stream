#!/usr/bin/env python3
"""Deterministic bundle/signature fixtures for the distribution audit, not signing qualification."""
import os
import json
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

SOURCE = pathlib.Path(__file__).resolve().parents[1]
TEAM = "K78G42H4U2"
GROUP = TEAM + ".com.joeblau.Stream.VirtualOutputs"
LEAF = b"synthetic-public-leaf-certificate"


class DistributionAuditTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="stream-distribution-")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.app = self.root / "StreamMac.app"
        self.bundle(self.app, "com.joeblau.StreamMac", "StreamMac", {
            "NSCameraUsageDescription": "Camera", "NSMicrophoneUsageDescription": "Audio",
            "StreamVirtualOutputTeam": TEAM, "StreamVirtualOutputAppGroup": GROUP})
        self.bundle(self.app / "Contents/Library/SystemExtensions/com.joeblau.StreamMac.CameraExtension.systemextension",
                    "com.joeblau.StreamMac.CameraExtension", "CameraExtension", {
                        "StreamVirtualOutputTeam": TEAM, "StreamVirtualOutputAppGroup": GROUP,
                        "CMIOExtension": {"CMIOExtensionMachServiceName": GROUP + ".CameraExtension"}})
        self.bundle(self.app / "Contents/Helpers/StreamBrowserAudioHelper.app",
                    "com.joeblau.StreamBrowserAudioHelper", "BrowserHelper", {})
        self.helper = self.app / "Contents/Helpers/StreamBrowserAudioHelper.app"
        self.camera = self.app / "Contents/Library/SystemExtensions/com.joeblau.StreamMac.CameraExtension.systemextension"
        # Synthetic decoded metadata only: no Apple signature or CMS evidence.
        # The TEAM-only camera deliberately has no embedded profile.
        self.profile(self.app, "com.joeblau.StreamMac")
        self.profile(self.helper, "com.joeblau.StreamBrowserAudioHelper")
        metadata = self.app / "Contents/Resources/Metadata.appintents/extract.actionsdata"
        metadata.parent.mkdir(parents=True)
        metadata.write_text(json.dumps({
            "actions": dict.fromkeys([
                "OpenStreamStudioIntent", "GetStreamStudioStateIntent", "SelectStreamStudioSceneIntent",
                "ApplyStreamStudioStagedSceneIntent", "SetStreamStudioLocalOutputIntent",
                "SetStreamStudioLayerVisibilityIntent"], {}),
            "entities": dict.fromkeys([
                "StudioAutomationProfileEntity", "StudioAutomationSceneEntity", "StudioAutomationLayerEntity"], {})}))
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        lipo = bin_dir / "lipo"
        lipo.write_text("#!/bin/sh\nprintf 'arm64\\n'\n")
        lipo.chmod(0o755)
        # Signature fixtures use empty payloads; model only their symbol output.
        # The actual built bundle is independently checked with the real nm.
        nm = bin_dir / "nm"
        nm.write_text("#!/bin/sh\ncase \"$STREAM_FIXTURE_FAULT:$2\" in\n"
                      "  injection:*|dylib:*.dylib) printf '_SGReceiverValidationFixture\\n' ;;\nesac\n")
        nm.chmod(0o755)
        codesign = bin_dir / "codesign"
        codesign.write_text("#!" + sys.executable + "\n" + '''
import os, pathlib, plistlib, sys
args = sys.argv[1:]
if "--verify" in args:
    raise SystemExit(0)
bundle = pathlib.Path(args[-1])
role = "camera" if bundle.suffix == ".systemextension" else "helper" if bundle.name == "StreamBrowserAudioHelper.app" else "host"
paths = {"host": "StreamMac/StreamMac.entitlements", "camera": "StreamCameraExtension/StreamCameraExtension.entitlements", "helper": "BrowserAudioHelper/BrowserAudioHelper.entitlements"}
fault = os.environ.get("STREAM_FIXTURE_FAULT", "")
if "--entitlements" in args:
    content = (pathlib.Path(os.environ["STREAM_FIXTURE_SOURCE"]) / paths[role]).read_bytes()
    prefix = os.environ.get("STREAM_FIXTURE_PREFIX", "K78G42H4U2")
    content = content.replace(b"$(DEVELOPMENT_TEAM)", b"K78G42H4U2").replace(b"$(AppIdentifierPrefix)", (prefix + ".").encode())
    values = plistlib.loads(content)
    identifier = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
    values["com.apple.application-identifier"] = prefix + "." + identifier
    values["com.apple.developer.team-identifier"] = "K78G42H4U2"
    if fault == "entitlement" and role == "host": values["com.apple.security.network.server"] = False
    if fault == "debug" and role == "helper": values["com.apple.security.get-task-allow"] = True
    sys.stdout.buffer.write(plistlib.dumps(values))
elif "--extract-certificates" in args:
    prefix = args[args.index("--extract-certificates") + 1]
    pathlib.Path(prefix + "0").write_bytes(b"synthetic-public-leaf-certificate")
else:
    team = "AAAAAAAAAA" if fault == "team" and role == "helper" else "K78G42H4U2"
    authority = "Apple Development: Fixture" if fault == "authority" else "Developer ID Application: Fixture"
    runtime = "0x0(none)" if fault == "runtime" and role == "camera" else "0x10000(runtime)"
    print(f"CodeDirectory v=20500 size=100 flags={runtime} hashes=1+7 location=embedded", file=sys.stderr)
    print(f"Authority={authority}\\nTeamIdentifier={team}", file=sys.stderr)
    if fault != "timestamp": print("Timestamp=Oct 21, 2026 at 12:00:00", file=sys.stderr)
''')
        codesign.chmod(0o755)
        security = bin_dir / "security"
        security.write_text("#!" + sys.executable + "\n" + '''
# Test-only stand-in for decoding owned synthetic metadata, not CMS validation.
import pathlib, sys
assert sys.argv[1:4] == ["cms", "-D", "-i"] and len(sys.argv) == 5
sys.stdout.buffer.write(pathlib.Path(sys.argv[4]).read_bytes())
''')
        security.chmod(0o755)
        self.env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"], STREAM_FIXTURE_SOURCE=str(SOURCE))

    def bundle(self, path, identifier, executable, extra):
        (path / "Contents/MacOS").mkdir(parents=True)
        (path / "Contents/MacOS" / executable).touch()
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps(dict(
            CFBundleIdentifier=identifier, CFBundleExecutable=executable, **extra)))

    def profile(self, bundle, identifier, prefix=TEAM):
        now = datetime.now(timezone.utc).replace(tzinfo=None)
        values = {"Platform": ["OSX"], "TeamIdentifier": [TEAM], "ApplicationIdentifierPrefix": [prefix],
                  "DeveloperCertificates": [LEAF], "CreationDate": now - timedelta(days=1),
                  "ExpirationDate": now + timedelta(days=1), "Entitlements": {
                      "com.apple.application-identifier": prefix + "." + identifier,
                      "com.apple.developer.team-identifier": TEAM,
                      "com.apple.developer.system-extension.install": True,
                      "com.apple.security.application-groups": ["group.com.joeblau.Stream", TEAM + ".*"],
                      "keychain-access-groups": [prefix + ".*"]}}
        (bundle / "Contents/embedded.provisionprofile").write_bytes(plistlib.dumps(values))

    def audit(self, fault="", signed=True):
        command = [sys.executable, str(SOURCE / "scripts/validate_desktop_distribution.py"), str(self.app)]
        if signed:
            command.append("--require-signed")
        return subprocess.run(command, env=dict(self.env, STREAM_FIXTURE_FAULT=fault), capture_output=True, text=True)

    def test_signed_bundle_contract(self):
        result = self.audit()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("embedded signed entitlements validated", result.stdout)
        self.assertIn("provisioning-profile metadata matches", result.stdout)
        self.assertFalse((self.camera / "Contents/embedded.provisionprofile").exists())

    def test_historical_non_team_app_prefix(self):
        self.env["STREAM_FIXTURE_PREFIX"] = "OLDPREFIX1"
        self.profile(self.app, "com.joeblau.StreamMac", prefix="OLDPREFIX1")
        self.profile(self.helper, "com.joeblau.StreamBrowserAudioHelper", prefix="OLDPREFIX1")
        result = self.audit()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_actual_restricted_and_registered_claims_require_matching_profiles(self):
        for bundle in [self.app, self.helper]:
            with self.subTest(bundle=bundle):
                path = bundle / "Contents/embedded.provisionprofile"
                original = path.read_bytes()
                path.unlink()
                result = self.audit()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Missing embedded provisioning profile", result.stderr)
                path.write_bytes(original)

    def test_embedded_profile_certificate_and_claim_mismatches(self):
        path = self.app / "Contents/embedded.provisionprofile"
        original = path.read_bytes()
        for key, value, message in [
            ("DeveloperCertificates", [b"different-public-leaf-same-team"], "leaf certificate"),
            ("Platform", ["iOS"], "not for macOS"),
            ("TeamIdentifier", ["AAAAAAAAAA"], "team mismatch"),
            ("ApplicationIdentifierPrefix", ["OLDPREFIX1"], "prefix mismatch"),
        ]:
            with self.subTest(key=key):
                profile = plistlib.loads(original)
                profile[key] = value
                path.write_bytes(plistlib.dumps(profile))
                result = self.audit()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
        path.write_bytes(original)
        profile = plistlib.loads(original)
        profile["Entitlements"]["com.apple.developer.system-extension.install"] = False
        path.write_bytes(plistlib.dumps(profile))
        result = self.audit()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not authorize system-extension installation", result.stderr)

    def test_optional_camera_profile_must_match_actual_identity(self):
        self.profile(self.camera, "com.other.CameraExtension")
        result = self.audit()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("application identifier mismatch", result.stderr)

    def test_rejects_each_signature_gate(self):
        for fault, message in [("entitlement", "Signed entitlement mismatch"), ("debug", "Debug entitlement"),
                               ("team", "Signing team mismatch"), ("authority", "Developer ID missing"),
                               ("runtime", "Hardened runtime missing"), ("timestamp", "Secure timestamp missing")]:
            with self.subTest(fault=fault):
                result = self.audit(fault)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)

    def test_unsigned_ci_audit_remains_available(self):
        (self.app / "Contents/embedded.provisionprofile").unlink()
        (self.helper / "Contents/embedded.provisionprofile").unlink()
        result = self.audit("authority", signed=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("require the release workflow", result.stdout)

    def test_rejects_transport_hooks_in_executable_and_debug_dylib(self):
        (self.app / "Contents/MacOS/StreamMac.debug.dylib").touch()
        for fault in ["injection", "dylib"]:
            with self.subTest(fault=fault):
                result = self.audit(fault, signed=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Guest transport fault injection", result.stderr)

    def test_rejects_missing_automation_action(self):
        metadata = self.app / "Contents/Resources/Metadata.appintents/extract.actionsdata"
        values = json.loads(metadata.read_text())
        del values["actions"]["SelectStreamStudioSceneIntent"]
        metadata.write_text(json.dumps(values))
        result = self.audit(signed=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing studio App Intents metadata", result.stderr)


if __name__ == "__main__":
    unittest.main()
