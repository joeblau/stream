#!/usr/bin/env python3
"""Prepare the full actual Mac source graph as a memory-only single-arch tool.
Uses an immutable, matching full StreamCore framework; never builds an App.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--core-framework-dir", type=Path, required=True)
args = parser.parse_args()
apple = Path(__file__).resolve().parents[1]
folder = args.output.resolve()
subprocess.run(["python3", str(apple / "scripts/prepare_frame_delivery_broker.py"), "--output", str(folder)], check=True)
project = json.loads((folder / "project.json").read_text())
project["name"] = "OptionalFrameDeliveryEngine"
project["targets"].pop("StreamCore")
target = project["targets"].pop("FrameDeliveryBrokerHarness")
target["dependencies"] = [
    {"framework": str(args.core_framework_dir.resolve() / "StreamCore.framework"), "embed": False}
    if dependency.get("target") == "StreamCore" else dependency
    for dependency in target["dependencies"]
]
original = apple / "scripts/frame_delivery_broker_harness.swift"
source = original.read_text()
assert source.count("@main enum FrameDeliveryBrokerHarness") == 1
helper = folder / "actual_broker_fixture_helpers.swift"
helper.write_text(source.replace("@main enum FrameDeliveryBrokerHarness", "enum FrameDeliveryBrokerHarness"))
target["sources"] = [str(helper) if item == str(original) else item for item in target["sources"]]
target["sources"].append(str(apple / "scripts/optional_frame_delivery_engine_harness.swift"))
target["settings"]["base"]["ARCHS"] = "arm64"
target["settings"]["base"]["ONLY_ACTIVE_ARCH"] = "YES"
project["targets"]["OptionalFrameDeliveryEngineHarness"] = target
project["schemes"] = {"OptionalFrameDeliveryEngineHarness": {"build": {"targets": {"OptionalFrameDeliveryEngineHarness": "all"}}}}
(folder / "project.json").write_text(json.dumps(project, indent=2) + "\n")
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
paths = [apple / "StreamMac/OptionalFrameDelivery.swift", apple / "StreamMac/OptionalMonitorImageHandoff.swift",
         apple / "StreamMac/PreviewImageConverter.swift", apple / "StreamMac/CompositionEngine.swift",
         apple / "StreamMac/SceneRenderer.swift", apple / "StreamMac/FrameDeliveryBroker.swift",
         apple / "StreamMac/FrameDeliveryConverter.swift", apple / "StreamMac/RawVideoResourceCoordinator.swift",
         apple / "StreamCore/RawVideoResourceBudget.swift", original, helper,
         apple / "scripts/composition_clock_authority_harness.swift",
         apple / "scripts/optional_frame_delivery_engine_harness.swift", Path(__file__).resolve(),
         args.core_framework_dir / "StreamCore.framework/StreamCore"]
(folder / "optional-source-receipt.json").write_text(json.dumps({
    "sourceCommit": subprocess.check_output(["git", "-C", str(apple), "rev-parse", "HEAD"], text=True).strip(),
    "scope": "Actual full Mac source graph single-arm64 tool + matching immutable full StreamCore. Runtime constructs only synthetic 16px CompositionEngine, actual OptionalFrameDelivery and owned native pixels/CGImages. No App/runtime/window/capture/device/audio/network/input/preference construction.",
    "sourceHashes": {str(path.resolve()): sha(path) for path in paths},
    "helperChanges": "Only @main removed from original retained broker fixture; its actual engine/render/probe helpers are reused. All production bytes unchanged."
}, indent=2, sort_keys=True) + "\n")
print(folder)
