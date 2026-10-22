#!/usr/bin/env python3
"""Independent consumer metadata/resource receipt for the owned ISO workload."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("artifacts", type=Path)
args = parser.parse_args()
root = args.artifacts.resolve()
if os.environ.get("ISO_SUSTAINED_DIAGNOSTIC") == "1":
    print("DIAGNOSTIC ONLY: sustained metadata acceptance is not run")
    raise SystemExit(0)
ffmpeg = os.environ.get("STREAM_FFMPEG_BIN")
candidates = ([str(Path(ffmpeg).with_name("ffprobe"))] if ffmpeg else []) + [
    "/opt/homebrew/opt/ffmpeg-full/bin/ffprobe", "/usr/local/opt/ffmpeg-full/bin/ffprobe",
    shutil.which("ffprobe"),
]
probe = next((p for p in candidates if p and os.access(p, os.X_OK)), None)
assert probe, "An actual independent ffprobe consumer is required"
evidence = json.loads((root / "evidence.json").read_text())
rows = []
for phase in evidence:
    for isolated in phase["isolated"]:
        path = Path(isolated["url"])
        result = subprocess.run([probe, "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)],
                                check=True, capture_output=True, text=True, timeout=20)
        media = json.loads(result.stdout)
        videos = [s for s in media["streams"] if s["codec_type"] == "video"]
        audios = [s for s in media["streams"] if s["codec_type"] == "audio"]
        selection = isolated["manifest"]["selection"]
        assert len(videos) == 1 and len(audios) == int(bool(selection.get("audioTargetID"))), str(path)
        video = videos[0]
        assert (video["width"], video["height"]) == (1920, 1080), video
        assert video["codec_name"] == selection["codec"], (selection, video)
        assert video["time_base"] and float(video["duration"]) > 59, video
        assert not audios or (audios[0]["codec_name"] == "aac" and audios[0]["sample_rate"] == "48000" and audios[0]["channels"] == 2), audios
        rows.append({"phase": phase["scenario"], "file": path.name, "codec": video["codec_name"],
                     "frames": int(video["nb_frames"]), "duration": float(media["format"]["duration"]),
                     "bytes": path.stat().st_size, "audioTracks": len(audios),
                     "renderDrops": isolated["progress"]["renderDrops"],
                     "missingVideoFrames": isolated["progress"]["missingVideoFrames"],
                     "missingAudioFrames": isolated["progress"]["missingAudioFrames"],
                     "droppedAudio": isolated["progress"]["droppedAudio"],
                     "probeMegabytesPerSecond": isolated["manifest"]["budget"]["measuredDiskMegabytesPerSecond"]})
health = [json.loads(p.read_text()) for p in root.glob("phase-*-health-*.json")]
assert len(health) >= 8, "Native resource observations missing"
summary = {"isolated": rows, "nativeResourceSamples": len(health)}
for field in ["resourceCPUCapacityPercent", "currentResidentBytes", "physicalFootprintBytes", "metalAllocatedBytes"]:
    values = [s[field] for s in health if s.get(field) is not None]
    assert values, "Native resource field missing: " + field
    summary[field] = {"minimum": min(values), "maximum": max(values)}
(root / "consumer-metadata.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
print("PASS: independent consumer H264/HEVC, exact track/audio policy and native resource receipts; " + str(root / "consumer-metadata.json"))
