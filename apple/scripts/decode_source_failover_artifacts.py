#!/usr/bin/env python3
"""Owned offline FFmpeg decoder; same source-fixture pixel/PCM/end-point limits."""
import array
import json
import math
import os
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1]).resolve()
movie = pathlib.Path(json.loads((root / 'external-decoder-input.json').read_text())['movie']).resolve()
assert movie.is_relative_to(root), 'Refusing media outside the owned fixture root'
candidates = [os.environ.get('STREAM_FFMPEG_BIN'), '/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg',
              '/usr/local/opt/ffmpeg-full/bin/ffmpeg', '/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg']
ffmpeg = next((pathlib.Path(x) for x in candidates if x and os.access(x, os.X_OK)), None)
if ffmpeg is None:
    raise SystemExit('UNQUALIFIED: owned external decode requires FFmpeg')
ffprobe = ffmpeg.with_name('ffprobe')
assert os.access(ffprobe, os.X_OK), 'Matching FFprobe is unavailable'


def probe(*args):
    return json.loads(subprocess.check_output([str(ffprobe), '-v', 'error', *args, '-of', 'json', str(movie)], timeout=20))


metadata = probe('-show_streams', '-show_format')
videos = [x for x in metadata['streams'] if x['codec_type'] == 'video']
audios = [x for x in metadata['streams'] if x['codec_type'] == 'audio']
assert len(videos) == len(audios) == 1, 'Both original Program tracks must exist'
v, a = videos[0], audios[0]
assert abs(float(v['start_time']) - float(a['start_time'])) < .04, 'Original40ms track-start limit failed'
assert abs(float(v['duration']) - float(a['duration'])) < .08, 'Original80ms track-duration limit failed'
assert int(a['sample_rate']) == 48000 and int(a['channels']) == 2, 'Original stereo48k PCM format changed'
origin = json.loads(pathlib.Path(str(movie) + '.recording.json').read_text())['sourceStartSeconds']
phases = json.loads((root / 'painted-source-windows.json').read_text())
timings = probe('-select_streams', 'v:0', '-show_frames', '-show_entries', 'frame=best_effort_timestamp_time')['frames']
assert 0 < len(timings) < 4096, 'Original bounded decoded-frame inventory exceeded'
width, height = int(v['width']), int(v['height'])
assert (width, height) == (640, 360), 'Owned pixel fixture dimensions changed'
decoded = []
command = [str(ffmpeg), '-v', 'error', '-threads', '2', '-i', str(movie), '-map', '0:v:0',
           '-an', '-threads:v', '2', '-pix_fmt', 'bgra', '-fps_mode', 'passthrough', '-f', 'rawvideo', 'pipe:1']
with subprocess.Popen(command, stdout=subprocess.PIPE) as decoder:
    try:
        for timing in timings:
            pixels = decoder.stdout.read(width * height * 4)
            assert len(pixels) == width * height * 4, 'Incomplete actual decoded frame'
    
            def rgb(x, y):
                offset = (y * width + x) * 4
                return {'red': pixels[offset + 2], 'green': pixels[offset + 1], 'blue': pixels[offset]}
    
            left_white = all_white = 0
            for y in range(0, height, 2):
                for x in range(0, width, 2):
                    offset = (y * width + x) * 4
                    if min(pixels[offset:offset + 3]) > 140:
                        all_white += 1
                        left_white += x < width // 2
            pts = origin + float(timing['best_effort_timestamp_time'])
            assert not decoded or pts > decoded[-1]['pts'], 'Decoded original timeline reset'
            decoded.append(dict(pts=pts, sequence=len(decoded) + 1, left=rgb(width // 4, height * 7 // 20),
                                right=rgb(width * 3 // 4, height * 7 // 20), leftWhite=left_white, allWhite=all_white))
        assert not decoder.stdout.read(1), 'Decoded frame count differs from timestamp inventory'
        assert decoder.wait(timeout=10) == 0, 'Actual video decode failed'
    finally:
        if decoder.poll() is None:
            decoder.kill()
            decoder.wait(timeout=5)


audio_frames = probe('-select_streams', 'a:0', '-show_frames', '-show_entries', 'frame=best_effort_timestamp_time,nb_samples')['frames']
audio_path = root / 'actual-decoded-program.f32'
subprocess.run([str(ffmpeg), '-v', 'error', '-threads', '2', '-i', str(movie), '-map', '0:a:0', '-vn',
                '-c:a', 'pcm_f32le', '-f', 'f32le', '-y', str(audio_path)], check=True, timeout=20)
assert audio_path.stat().st_size < 64 * 1024 * 1024, 'Owned PCM inventory exceeded64MB'
pcm = array.array('f', audio_path.read_bytes())
if sys.byteorder != 'little':
    pcm.byteswap()
assert len(pcm) == sum(int(x['nb_samples']) for x in audio_frames) * 2, 'PCM count differs from original decoded frame timings'


def red(p): return p['red'] > 150 and p['green'] < 65 and p['blue'] < 65
def blue(p): return p['blue'] > 150 and p['red'] < 65 and p['green'] < 65
def healthy(p): return p['green'] > 150 and p['red'] < 65
def dark(p): return max(p.values()) < 45


def matches(frame, mode):
    left, right = frame['left'], frame['right']
    if mode == 'red': return red(left) and healthy(right)
    if mode == 'blue': return blue(left) and healthy(right)
    if mode == 'blank': return abs(left['red'] - 96) < 20 and left['green'] < 20 and abs(left['blue'] - 96) < 20 and healthy(right)
    if mode == 'offline': return dark(left) and frame['leftWhite'] > 100 and healthy(right)
    if mode == 'sceneStandby': return blue(left) and blue(right)
    if mode == 'privateSlate': return dark(left) and dark(right) and frame['allWhite'] > 100
    if mode == 'allOffline': return dark(left) and dark(right) and frame['leftWhite'] > 100 and frame['allWhite'] - frame['leftWhite'] > 100
    raise AssertionError('Unknown painted phase')


results = []
for phase in phases:
    start, end = phase['startHostSeconds'], phase['endHostSeconds']
    actual = [x for x in decoded if start <= x['pts'] <= end]
    assert len(actual) >= 3 and all(matches(x, phase['mode']) for x in actual), f"Encoded pixels changed: {phase['name']}"
    if phase['mode'] not in ('sceneStandby', 'privateSlate', 'allOffline'):
        assert len({x['right']['blue'] > 100 for x in actual}) == 2, 'Healthy independent source froze'
    energy = samples = offset = 0
    for audio_frame in audio_frames:
        count = int(audio_frame['nb_samples'])
        pts = origin + float(audio_frame['best_effort_timestamp_time'])
        lower = max(0, math.ceil((start + .08 - pts) * 48000))
        upper = min(count, math.floor((end - .04 - pts) * 48000) + 1)
        if upper > lower:
            values = pcm[(offset + lower) * 2:(offset + upper) * 2:2]
            energy += math.fsum(float(value) ** 2 for value in values)
            samples += len(values)
        offset += count
    rms = math.sqrt(energy / max(1, samples))
    assert samples > 2400 and (rms > .03 if phase['expectsTone'] else rms < .002), f"Original PCM policy failed: {phase['name']}, samples={samples}, RMS={rms}"
    results.append(dict(name=phase['name'], decodedFrames=len(actual), pcmSamples=samples, pcmRMS=rms))
    print(f"Decoded phase {phase['name']}: {len(actual)} actual frames, {samples} PCM samples, RMS {rms}", flush=True)
(root / 'decoded-frame-receipts.json').write_text(json.dumps(decoded))
(root / 'external-decoder-summary.json').write_text(json.dumps(dict(decoder='ffmpeg-offline',
    durationSeconds=float(metadata['format']['duration']), videoFrames=len(decoded),
    videoStart=float(v['start_time']), audioStart=float(a['start_time']),
    videoDuration=float(v['duration']), audioDuration=float(a['duration']), phases=results), indent=2) + '\n')
print(f'PASS: actual offline H264/AAC decode; {len(phases)} painted phases, {len(decoded)} frames, original40/80ms endpoints and all original PCM tone/silence bounds; no HAL audio device', flush=True)
