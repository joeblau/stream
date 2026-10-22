#!/usr/bin/env python3
"""Build only an owned single-arch tool, then execute the memory-only fixture.
Run through the shared native build slot wrapper. Existing derived-data may be
a private copy of a frozen dependency cache; every proof output remains unique.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--derived", type=Path, required=True)
parser.add_argument("--core-framework-dir", type=Path, required=True)
args = parser.parse_args()
apple = Path(__file__).resolve().parents[1]
args.output.mkdir(parents=True, exist_ok=False)
receipt = {"scope": "Owned actual Engine/OptionalFrameDelivery pixels only; no application or external owners"}
phase = "prepare"
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
try:
    # Xcode places BUILT_PRODUCTS_DIR ahead of explicit framework search paths.
    # Replace only this owned cache's stale Core with the immutable full build.
    source_core = args.core_framework_dir.resolve() / "StreamCore.framework"
    copied_core = args.derived.resolve() / "Build/Products/Debug/StreamCore.framework"
    assert copied_core.resolve() != source_core.resolve()
    if copied_core.exists():
        shutil.rmtree(copied_core)
    shutil.copytree(source_core, copied_core, symlinks=True)
    receipt["copiedStreamCoreBinarySHA256"] = sha(copied_core / "StreamCore")
    subprocess.run(["python3", str(apple / "scripts/prepare_optional_frame_delivery_engine.py"),
        "--output", str(args.output), "--core-framework-dir", str(args.core_framework_dir)], check=True, timeout=30)
    subprocess.run(["xcodegen", "generate", "--spec", str(args.output / "project.json"),
        "--project", str(args.output)], check=True, timeout=30)
    phase = "compile"
    subprocess.run(["xcodebuild", "-jobs", "2", "-project", str(args.output / "OptionalFrameDeliveryEngine.xcodeproj"),
        "-scheme", "OptionalFrameDeliveryEngineHarness", "-destination", "platform=macOS,arch=arm64",
        "-derivedDataPath", str(args.derived), "-skipPackageUpdates", "-disableAutomaticPackageResolution",
        "CODE_SIGNING_ALLOWED=NO", "OTHER_SWIFT_FLAGS=$(inherited) -j2 -driver-batch-count 2", "build"],
        check=True, timeout=600)
    products = args.derived / "Build/Products/Debug"
    executable = args.output / "OptionalFrameDeliveryEngineHarness"
    shutil.copy2(products / executable.name, executable)
    receipt["executableSHA256"] = sha(executable)
    phase = "runtime"
    environment = dict(os.environ, DYLD_FRAMEWORK_PATH=str(args.core_framework_dir.resolve()) + ":" + str(products.resolve()) + ":" + str((products / "PackageFrameworks").resolve()))
    subprocess.run([str(executable.resolve()), str((args.output / "observations.json").resolve())],
        check=True, timeout=45, env=environment)
    receipt["result"] = "PASS"
    receipt["observationsSHA256"] = sha(args.output / "observations.json")
except Exception as error:
    receipt.update(result="FAIL", phase=phase, failureType=type(error).__name__)
    if isinstance(error, subprocess.CalledProcessError):
        receipt["processReturnCode"] = error.returncode
    elif isinstance(error, subprocess.TimeoutExpired):
        receipt["timeoutSeconds"] = error.timeout
    raise
finally:
    receipt["runnerSHA256"] = sha(Path(__file__).resolve())
    (args.output / "result.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
