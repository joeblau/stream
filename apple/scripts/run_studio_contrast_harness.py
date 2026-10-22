#!/usr/bin/env python3
"""Build the exact production interface styles and owned contrast fixture only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--profile-reference", type=Path, required=True)
args = parser.parse_args()
apple = Path(__file__).resolve().parents[1]
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=False)
sources = output / "sources"
sources.mkdir()
images = output / "images"
images.mkdir()
sha = lambda value: hashlib.sha256(value).hexdigest()
bindings = []


def snapshot(path):
    data = path.read_bytes()
    target = sources / path.name
    target.write_bytes(data)
    bindings.append({"origin": str(path), "snapshot": str(target), "sha256": sha(data)})
    return data.decode()


def between(text, start, end):
    if text.count(start) != 1 or text.count(end) != 1:
        raise RuntimeError("Exact owned fixture boundary changed")
    return text[text.index(start):text.index(end)]


styles = apple / "StreamMac/StudioAccessibility.swift"
snapshot(styles)  # Entire unchanged production file, not replacement styles.
harness = snapshot(apple / "scripts/studio_accessibility_harness.swift")
workspace = snapshot(apple / "scripts/studio_workspace_harness.swift")
snapshot(Path(__file__).resolve())
parts = {
    "isolatedDefaults": between(workspace, "enum WorkspaceFixtureDefaults {", "enum WorkspaceFixtureStorage {"),
    "require": between(harness, "    private static func require(", "    private static func client("),
    "view": between(harness, "private struct StudioContrastPixelProbe: View {", "extension StudioAccessibilityHarness {\n    private struct ContrastRGBA:"),
    "methods": between(harness, "extension StudioAccessibilityHarness {\n    private struct ContrastRGBA:", "    private static func mixerAndUpdates("),
}
tool = "import AppKit\nimport Foundation\nimport ImageIO\nimport SwiftUI\n"
tool += parts["isolatedDefaults"]
tool += "\n@MainActor enum StudioAccessibilityHarness {\n" + parts["require"] + "\n}\n"
tool += parts["view"] + parts["methods"] + "\n}\n"
tool += '''
@main @MainActor struct OwnedStudioContrastMain {
    static func main() {
        setbuf(stdout, nil)
        guard CGSessionCopyCurrentDictionary() != nil else {
            print("UNQUALIFIED: owned contrast view needs a WindowServer session")
            exit(77)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        Task { @MainActor in
            let status: Int32
            do { try await StudioAccessibilityHarness.runContrastOnly(); status = 0 }
            catch { print("FAIL: \\(error.localizedDescription)"); status = 1 }
            WorkspaceFixtureDefaults.value.removePersistentDomain(forName: WorkspaceFixtureDefaults.name)
            exit(status)
        }
        app.run()
    }
}
'''
generated = sources / "OwnedStudioContrast.swift"
generated.write_text(tool)
reference = sources / "owned-reference.png"
shutil.copy2(args.profile_reference.resolve(), reference)
receipt = {
    "scope": "Entire actual production StudioAccessibility styles and exact contrast fixture slices; owned NSApp/window only, no Workspace/media graph/AX or VoiceOver qualification",
    "baseCommit": subprocess.check_output(["git", "-C", str(apple), "rev-parse", "HEAD"], text=True).strip(),
    "sourceBindings": bindings,
    "sliceSHA256": {name: sha(text.encode()) for name, text in parts.items()},
    "generatedSHA256": sha(generated.read_bytes()),
    "reference": {"origin": str(args.profile_reference.resolve()), "snapshot": str(reference), "sha256": sha(reference.read_bytes())},
    "checks": [],
}
executable = output / "OwnedStudioContrast"
commands = [
    ("compile", ["xcrun", "swiftc", "-j2", "-swift-version", "6", "-strict-concurrency=complete", "-parse-as-library", str(sources / styles.name), str(generated), "-o", str(executable)], 120),
    ("runtime", [str(executable)], 30),
]
environment = dict(os.environ, STREAM_ACCESSIBILITY_ARTIFACTS=str(images),
                   STREAM_ACCESSIBILITY_PROFILE_REFERENCE=str(reference))
status = 1
try:
    for label, command, deadline in commands:
        result = subprocess.run(command, capture_output=True, text=True, timeout=deadline, env=environment)
        log = output / (label + ".log")
        log.write_text(result.stdout + result.stderr)
        receipt["checks"].append({"label": label, "command": command, "exit": result.returncode, "log": str(log), "sha256": sha(log.read_bytes())})
        print(log.read_text(), end="", flush=True)
        status = result.returncode
        if status != 0:
            break
        if label == "compile":
            receipt["executableSHA256"] = sha(executable.read_bytes())
except subprocess.TimeoutExpired as failure:
    status = 1
    receipt["timeout"] = {"command": failure.cmd, "seconds": failure.timeout}
    text = b"".join(value.encode() if isinstance(value, str) else value or b""
                    for value in [failure.stdout, failure.stderr]).decode(errors="replace")
    log = output / (label + ".log")
    log.write_text(text)
    receipt["checks"].append({"label": label, "command": command, "exit": None,
                              "timeoutSeconds": failure.timeout, "log": str(log), "sha256": sha(log.read_bytes())})
    print("FAIL: owned contrast process exceeded its bounded deadline", flush=True)
finally:
    receipt["images"] = {str(path): sha(path.read_bytes()) for path in images.glob("*.png")}
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
sys.exit(status)
