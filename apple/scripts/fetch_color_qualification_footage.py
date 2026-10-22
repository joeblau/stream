#!/usr/bin/env python3
"""Fetch only pinned CC-BY-3.0 photographed test plates, never camera input.

Source credit: (CC) Blender Foundation | mango.blender.org
License: https://creativecommons.org/licenses/by/3.0/
Publisher license notice: https://media.xiph.org/tearsofsteel/README.txt
The exact 48 original scene-linear frames are authenticated by the checked-in
manifest. No media is bundled in the application or committed to the repository.
"""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import urllib.request

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--directory", type=Path, default=root / "build/color-transform-footage")
args = parser.parse_args()
manifest_path = root / "scripts/fixtures/color-footage-manifest.json"
manifest = json.loads(manifest_path.read_text())
assert len(manifest["frames"]) == 48
args.directory.mkdir(parents=True, exist_ok=True)

def fetch(row):
    expected = "https://media.xiph.org/tearsofsteel/tearsofsteel-footage-exr/04_2a/linear_hd/" + row["file"]
    if row["url"] != expected or Path(row["file"]).name != row["file"] or not 0 < row["bytes"] < 12 * 1024 * 1024:
        raise ValueError("Invalid bounded footage manifest")
    path = args.directory / row["file"]
    if not path.exists():
        with urllib.request.urlopen(expected, timeout=60) as response:
            data = response.read(row["bytes"] + 1)
        if len(data) != row["bytes"] or hashlib.sha256(data).hexdigest() != row["sha256"]:
            raise ValueError("Downloaded footage differs from the pinned source: " + row["file"])
        path.write_bytes(data)
    if path.stat().st_size != row["bytes"] or hashlib.sha256(path.read_bytes()).hexdigest() != row["sha256"]:
        raise ValueError("Cached footage differs from the pinned source: " + row["file"])

with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    list(pool.map(fetch, manifest["frames"]))
(args.directory / "manifest.json").write_bytes(manifest_path.read_bytes())
print("Verified48 consecutive licensed original EXR frames;", sum(row["bytes"] for row in manifest["frames"]), "bytes in", args.directory)
