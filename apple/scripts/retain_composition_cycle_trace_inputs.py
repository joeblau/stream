#!/usr/bin/env python3
"""Verify generated build inputs and retain bindings beside uploaded frames.

Hash/copy only: never compiles or executes the binary. Called after the existing
build succeeds and before the existing owned workload launcher runs.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def retain(inputs, binary, frames, recipe, xcode_project):
    manifest_path = inputs / "manifest.json"
    manifest_bytes = manifest_path.read_bytes()
    manifest = json.loads(manifest_bytes)
    source = Path(manifest["sourceRoot"])
    for name, expected in manifest["sourceSHA256"].items():
        if sha(source / name) != expected or sha(inputs / "source-snapshots" / name) != expected:
            raise ValueError("Original/snapshot source changed before launch: " + name)
    for name, expected in manifest["generatedSHA256"].items():
        if sha(inputs / name) != expected:
            raise ValueError("Generated build input changed before launch: " + name)
    destination = frames / "clock-cycle-inputs" / manifest["generationID"]
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(inputs, destination)
    if (destination / "manifest.json").read_bytes() != manifest_bytes:
        raise ValueError("Retained manifest differs from verified input")
    # Revalidate the copied bytes too; receipt never labels an altered copy as
    # the compiler input. No source files are rewritten in this operation.
    for name, expected in manifest["generatedSHA256"].items():
        if sha(destination / name) != expected:
            raise ValueError("Retained generated input changed: " + name)
    for name, expected in manifest["sourceSHA256"].items():
        if sha(destination / "source-snapshots" / name) != expected:
            raise ValueError("Retained source snapshot changed: " + name)
    binary_bytes = binary.read_bytes()
    recipe_bytes = recipe.read_bytes()
    project_bytes = xcode_project.read_bytes()
    if any(sha(source / name) != expected for name, expected in manifest["sourceSHA256"].items()):
        raise ValueError("Original input changed during build binding")
    if any(sha(inputs / name) != expected for name, expected in manifest["generatedSHA256"].items()):
        raise ValueError("Generated input changed during build binding")
    receipt = {"generationID": manifest["generationID"],
               "sourceSetSHA256": manifest["sourceSetSHA256"],
               "manifestSHA256": hashlib.sha256(manifest_bytes).hexdigest(),
               "binaryPath": str(binary), "binaryBytes": len(binary_bytes),
               "binarySHA256": hashlib.sha256(binary_bytes).hexdigest(),
               "projectRecipeSHA256": hashlib.sha256(recipe_bytes).hexdigest(),
               "xcodeProjectSHA256": hashlib.sha256(project_bytes).hexdigest(),
               "scope": "Post-build/pre-launch byte bindings only. Binary is not executed here. No claim of trace completeness, runtime success or performance qualification.",
               "sourceInputsReverified": True, "generatedInputsReverified": True}
    (destination / "compiled-project.json").write_bytes(recipe_bytes)
    (destination / "compiled-project.pbxproj").write_bytes(project_bytes)
    (destination / "compiled-inputs.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--frames", type=Path, required=True)
    parser.add_argument("--recipe", type=Path, required=True)
    parser.add_argument("--xcode-project", type=Path, required=True)
    args = parser.parse_args()
    retain(args.inputs, args.binary, args.frames, args.recipe, args.xcode_project)


if __name__ == "__main__":
    main()
