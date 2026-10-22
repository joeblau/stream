#!/usr/bin/env python3
"""Select and validate an existing receiver; never install or change tools."""

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


class ReceiverError(RuntimeError):
    pass


def probe(binary, *arguments):
    try:
        result = subprocess.run([str(binary), "-hide_banner", *arguments],
                                capture_output=True, text=True, timeout=8)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ReceiverError(f"{binary}: capability probe failed: {error}") from error
    if result.returncode:
        raise ReceiverError(f"{binary}: {' '.join(arguments)} exited {result.returncode}")
    return result.stdout + result.stderr


def missing_capabilities(reports, require_srt=False):
    inputs = set()
    in_input = False
    for line in reports["protocols"].splitlines():
        if line.strip() in ("Input:", "Output:"):
            in_input = line.strip() == "Input:"
        elif in_input:
            inputs.add(line.strip())
    decoders = set(re.findall(r"^\s*[VAS][A-Z.]{5}\s+(\S+)\s", reports["decoders"], re.M))
    encoders = set(re.findall(r"^\s*[VAS][A-Z.]{5}\s+(\S+)\s", reports["encoders"], re.M))
    def formats(text, flag):
        names = set()
        for line in text.splitlines():
            fields = line.split()
            if len(fields) > 1 and fields[0] == flag:
                names.update(fields[1].split(","))
        return names
    demuxers = formats(reports["demuxers"], "D")
    muxers = formats(reports["muxers"], "E")
    requirements = {
        "RTMP input": "rtmp" in inputs,
        "TCP input": "tcp" in inputs,
        "RTMP -listen input option": bool(re.search(r"^\s+-listen\s+<int>\s+\S*D", reports["rtmp"], re.M)),
        "FLV input demuxer": "flv" in demuxers,
        "MP4 input demuxer": "mp4" in demuxers,
        "H.264 decoder": "h264" in decoders,
        "AAC decoder": "aac" in decoders,
        "MP4 output muxer": "mp4" in muxers,
        "null output muxer": "null" in muxers,
        "null video passthrough": "wrapped_avframe" in encoders,
        "null PCM output": "pcm_s16le" in encoders,
    }
    if require_srt:
        requirements["SRT input (shared publishing fixture)"] = "srt" in inputs
        requirements["MPEG-TS input (shared publishing fixture)"] = "mpegts" in demuxers
    return [name for name, present in requirements.items() if not present]


def validate(binary, require_srt=False):
    reports = {name: probe(binary, *arguments) for name, arguments in {
        "protocols": ["-protocols"], "rtmp": ["-h", "protocol=rtmp"],
        "decoders": ["-decoders"], "encoders": ["-encoders"],
        "demuxers": ["-demuxers"], "muxers": ["-muxers"],
    }.items()}
    missing = missing_capabilities(reports, require_srt)
    if missing:
        raise ReceiverError(f"{binary}: missing " + ", ".join(missing))


def candidates(environment):
    # An explicit override is exclusive, including invalid/empty overrides.
    if "STREAM_FFMPEG_BIN" in environment:
        yield environment["STREAM_FFMPEG_BIN"]
        return
    if found := shutil.which("ffmpeg", path=environment.get("PATH")):
        yield found
    if brew := shutil.which("brew", path=environment.get("PATH")):
        for formula in ("ffmpeg", "ffmpeg-full"):
            try:
                result = subprocess.run([brew, "--prefix", formula], capture_output=True, text=True, timeout=8)
                if result.returncode == 0 and result.stdout.strip():
                    yield str(Path(result.stdout.strip()) / "bin/ffmpeg")
            except (OSError, subprocess.TimeoutExpired):
                continue
    for prefix in ("/opt/homebrew", "/usr/local"):
        for relative in ("bin/ffmpeg", "opt/ffmpeg/bin/ffmpeg", "opt/ffmpeg-full/bin/ffmpeg"):
            yield f"{prefix}/{relative}"


def select(environment, require_srt=False):
    failures, visited = [], set()
    for candidate in candidates(environment):
        try:
            binary = Path(candidate).expanduser().resolve()
        except (OSError, RuntimeError) as error:
            failures.append(f"{candidate!r}: cannot resolve executable: {error}")
            continue
        if binary in visited:
            continue
        visited.add(binary)
        if not binary.is_file() or not os.access(binary, os.X_OK):
            failures.append(f"{candidate!r}: not an executable file")
            continue
        try:
            validate(binary, require_srt)
            return binary
        except ReceiverError as error:
            failures.append(str(error))
    raise ReceiverError("No compatible FFmpeg receiver. " + "; ".join(failures)
                        + ". Set STREAM_FFMPEG_BIN to a compatible executable; an explicit override never falls back.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--require-srt", action="store_true", help="also require the shared RTMP/SRT fixture's SRT input")
    options = parser.parse_args()
    try:
        print(select(os.environ, options.require_srt))
        print("PASS: FFmpeg RTMP input/listen, FLV/MP4 input, H.264/AAC decode and MP4/null output"
              + (", SRT/MPEG-TS input" if options.require_srt else ""), file=sys.stderr)
    except ReceiverError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(2)
