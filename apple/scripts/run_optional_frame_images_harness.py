#!/usr/bin/env python3
"""Owned private-CV/CGImage and memory-surface proof; never constructs a studio.
Use a matching ALL-source StreamCore framework. Source overrides are read-only
peer snapshots for integration review; their exact bytes are retained and hashed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def definition(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    return source[start:end]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--core-framework-dir", type=Path, required=True)
    parser.add_argument("--broker-source", type=Path)
    parser.add_argument("--converter-source", type=Path)
    parser.add_argument("--resource-source", type=Path)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    args = parser.parse_args()
    apple = Path(__file__).resolve().parents[1]
    # Separate immutable histories, including compile/runtime failures.
    args.artifacts.mkdir(parents=True, exist_ok=False)
    paths = {
        "FrameDeliveryBroker.swift": args.broker_source or apple / "StreamMac/FrameDeliveryBroker.swift",
        "FrameDeliveryConverter.swift": args.converter_source or apple / "StreamMac/FrameDeliveryConverter.swift",
        "RawVideoResourceCoordinator.swift": args.resource_source or apple / "StreamMac/RawVideoResourceCoordinator.swift",
        **{name: apple / "StreamMac" / name for name in ["PreviewImageConverter.swift",
            "ExternalProgramImageConverter.swift", "ExternalDisplayOutputController.swift", "OptionalMonitorImageHandoff.swift"]},
        "optional_frame_images_harness.swift": apple / "scripts/optional_frame_images_harness.swift",
    }
    sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    receipt = {"scope": "Owned pixels, private bank/CGImage lifecycle, bounded handoff and memory-only external controller; no real windows/displays/devices/capture/AX/input/preferences/network", "sourceHashes": {}}
    phase = "snapshot"
    try:
        inputs = []
        for name, path in paths.items():
            copy = args.artifacts / name
            shutil.copy2(path, copy)
            receipt["sourceHashes"][name] = sha(copy)
            inputs.append(copy)
        paint = apple / "StreamMac/RecordingChatTypes.swift"
        generated = args.artifacts / "OwnedRecordingChatPaint.swift"
        generated.write_text("import CoreMedia\nimport CryptoKit\nimport Foundation\n" + definition(paint.read_text(), "struct RecordingChatPaint:") + "\n")
        receipt["sourceHashes"]["RecordingChatTypes.swift"] = sha(paint)
        receipt["sourceHashes"]["OwnedRecordingChatPaint.swift"] = sha(generated)
        receipt["runnerSHA256"] = sha(Path(__file__).resolve())
        receipt["streamCoreBinarySHA256"] = sha(args.core_framework_dir / "StreamCore.framework/StreamCore")
        inputs.append(generated)
        executable = args.artifacts / "OptionalFrameImagesHarness"
        phase = "compile"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-strict-concurrency=complete", "-j2", "-parse-as-library",
            "-F", str(args.core_framework_dir), "-framework", "StreamCore", "-Xlinker", "-rpath", "-Xlinker", str(args.core_framework_dir.resolve()),
            *map(str, inputs), "-o", str(executable)], check=True, timeout=120)
        receipt["executableSHA256"] = sha(executable)
        phase = "runtime"
        args.report.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([str(executable.resolve()), str(args.report.resolve())], check=True, timeout=30)
        receipt["result"] = "PASS"
        receipt["reportSHA256"] = sha(args.report)
    except Exception as error:
        failure = {"result": "FAIL", "phase": phase, "failureType": type(error).__name__}
        if isinstance(error, subprocess.CalledProcessError):
            failure["processReturnCode"] = error.returncode
        elif isinstance(error, subprocess.TimeoutExpired):
            failure["timeoutSeconds"] = error.timeout
        receipt.update(failure)
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(failure, indent=2, sort_keys=True) + "\n")
        raise
    finally:
        (args.artifacts / "receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
