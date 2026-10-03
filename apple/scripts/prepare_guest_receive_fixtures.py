#!/usr/bin/env python3
"""Owned synthetic media plus real libopus reference decoding; no devices."""
import ctypes
import ctypes.util
import json
import math
import os
from pathlib import Path
import subprocess
import sys

folder = Path(sys.argv[1])
folder.mkdir(parents=True, exist_ok=True)


def ffmpeg(*arguments):
    subprocess.run([os.environ.get("FFMPEG", "ffmpeg"), "-nostdin", "-hide_banner",
                    "-loglevel", "error", "-y", *arguments], check=True, timeout=30)


def packets(path):
    data = path.read_bytes()
    result, packet, offset = [], b"", 0
    while offset < len(data):
        assert data[offset:offset + 4] == b"OggS" and offset + 27 <= len(data)
        count = data[offset + 26]
        lengths = data[offset + 27:offset + 27 + count]
        assert len(lengths) == count
        cursor = offset + 27 + count
        for size in lengths:
            assert cursor + size <= len(data)
            packet += data[cursor:cursor + size]
            cursor += size
            if size < 255:
                result.append(packet)
                packet = b""
        offset = cursor
    assert not packet and result[0].startswith(b"OpusHead") and result[1].startswith(b"OpusTags")
    # Container pre-skip is deliberately NOT applied to raw RTP payloads.
    return result[2:]


library = os.environ.get("STREAM_GUEST_LIBOPUS") or ctypes.util.find_library("opus")
if not library:
    for candidate in ["/opt/homebrew/opt/opus/lib/libopus.dylib", "/usr/local/opt/opus/lib/libopus.dylib"]:
        if Path(candidate).is_file():
            library = candidate
            break
if not library:
    raise SystemExit("Real libopus reference decoder required: set STREAM_GUEST_LIBOPUS")
opus = ctypes.CDLL(library)
opus.opus_decoder_create.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.c_int)]
opus.opus_decoder_create.restype = ctypes.c_void_p
opus.opus_decode_float.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int,
                                  ctypes.POINTER(ctypes.c_float), ctypes.c_int, ctypes.c_int]
opus.opus_decode_float.restype = ctypes.c_int
opus.opus_decoder_destroy.argtypes = [ctypes.c_void_p]


def reference(selected):
    error = ctypes.c_int()
    decoder = opus.opus_decoder_create(48000, 2, ctypes.byref(error))
    assert decoder and error.value == 0
    total, cue, channel_rms = 0, None, []
    try:
        for payload in selected:
            assert 0 < len(payload) <= 1275
            output = (ctypes.c_float * 11520)()
            frames = opus.opus_decode_float(decoder, payload, len(payload), output, 5760, 0)
            assert 0 < frames <= 5760
            for index in range(frames):
                if cue is None and abs(output[index * 2]) > 0.025:
                    cue = total + index
            total += frames
            channel_rms.append([math.sqrt(sum(output[index * 2 + channel] ** 2 for index in range(frames)) / frames) for channel in range(2)])
    finally:
        opus.opus_decoder_destroy(decoder)
    return {"frames": total, "cueFrame": cue, "channelRMS": channel_rms}


for role, color in [("camera", "red"), ("screen", "blue")]:
    ffmpeg("-f", "lavfi", "-i", f"color=c={color}:s=320x180:r=10:d=1.4",
           "-vf", "drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='between(t,0.5,0.59)'",
           "-c:v", "libx264", "-profile:v", "baseline", "-pix_fmt", "yuv420p",
           "-tune", "zerolatency", "-x264-params", "aud=1:keyint=10:min-keyint=10:scenecut=0",
           "-f", "h264", str(folder / f"{role}.h264"))
ffmpeg("-f", "lavfi", "-i", "aevalsrc=if(gte(t\\,0.5)\\,0.4*sin(2*PI*600*t)\\,0)|if(gte(t\\,0.5)\\,0.4*sin(2*PI*600*t)\\,0):s=48000:d=1.4",
       "-c:a", "libopus", "-application", "lowdelay", "-frame_duration", "20", str(folder / "audio.opus"))
selected = packets(folder / "audio.opus")[:70]
assert len(selected) == 70
for index, payload in enumerate(selected):
    (folder / f"opus-{index:03d}.bin").write_bytes(payload)
(folder / "opus-reference.json").write_text(json.dumps(reference(selected)))

manifest = []
for label, milliseconds, channels, application, bitrate in [
    ("stereo2_5", 2.5, 2, "lowdelay", "64000"),
    ("stereo5", 5, 2, "lowdelay", "64000"),
    ("stereo10", 10, 2, "lowdelay", "64000"),
    ("stereo40", 40, 2, "audio", "64000"),
    ("stereo60", 60, 2, "audio", "64000"),
    ("mono20", 20, 1, "audio", "24000"),
    ("silk20", 20, 1, "voip", "12000"),
]:
    expression = "0.3*sin(2*PI*440*t)|0.1*sin(2*PI*880*t)" if channels == 2 else "0.2*sin(2*PI*440*t)"
    path = folder / f"{label}.opus"
    ffmpeg("-f", "lavfi", "-i", f"aevalsrc={expression}:s=48000:d=0.5",
           "-c:a", "libopus", "-application", application, "-b:a", bitrate,
           "-frame_duration", str(milliseconds), "-vbr", "off", str(path))
    selected = packets(path)[:16]
    for index, payload in enumerate(selected):
        (folder / f"{label}-{index:03d}.bin").write_bytes(payload)
    decoded = reference(selected)
    manifest.append({"label": label, "packets": len(selected), "frames": decoded["frames"], "channelRMS": decoded["channelRMS"],
                     "channels": channels, "duration": milliseconds, "config": selected[0][0] >> 3})
(folder / "opus-cases.json").write_text(json.dumps(manifest))
print("Synthetic H264/Opus fixtures + raw libopus sample/cue references prepared")
