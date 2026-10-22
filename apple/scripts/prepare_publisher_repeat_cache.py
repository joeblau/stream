#!/usr/bin/env python3
"""Whole production publishers; only selected SDK media effects are inert."""
import argparse
import hashlib
import json
import pathlib
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=pathlib.Path, required=True)
parser.add_argument('--mode', choices=['positive', 'entry-negative', 'future-negative'], default='positive')
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
folder = args.output.resolve()
folder.mkdir(parents=True, exist_ok=True)
sha = lambda data: hashlib.sha256(data).hexdigest()
manifest = {'mode': args.mode, 'sourceCommit': subprocess.check_output(
    ['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip(), 'sources': {}, 'generated': {},
    'scope': 'Actual whole publisher actors and their append/repeat/normalizer/admission code. Generated copies replace only selected mixer media effects, add same-file private setup/inspection, and use an inert Session stream-presence object. No start/network/encoder/device or sustained performance proof.'}

def method(source, signature):
    start = source.index(signature)
    end = source.index('\n    }\n', start) + len('\n    }')
    return source[start:end]

for name, key in [('RTMPPublisher', 'rtmp'), ('SessionPublisher', 'session')]:
    relative = 'StreamBroadcast/' + name + '.swift'
    source = (root / relative).read_text()
    video = method(source, '    func appendVideo(_ sb: CMSampleBuffer) async {')
    program = method(source, '    func appendProgram(_ sb: CMSampleBuffer) async {')
    original_video, original_program = video, program
    assert video.count('lastVideoBuffer = usesProgramAudio ? nil : sb') == 1
    assert program.count('            lastVideoBuffer = nil\n') == 1
    if args.mode == 'entry-negative':
        program = program.replace('            lastVideoBuffer = nil\n', '')
    if args.mode == 'future-negative':
        video = video.replace('lastVideoBuffer = usesProgramAudio ? nil : sb', 'lastVideoBuffer = sb')
    replacements = {
        'await mixer.append(admitted)': f'await OwnedRepeatMedia.shared.video("{key}", pts: admitted.presentationTimeStamp.seconds, duration: admitted.duration.seconds)',
        'await applyAudioMixerSettings()': f'await OwnedRepeatMedia.shared.configure("{key}", program: usesProgramAudio, cache: lastVideoBuffer != nil)',
        'await mixer.append(planar.buffer, when: planar.when, track: 0)': f'await OwnedRepeatMedia.shared.audio("{key}", pts: normalized.presentationTimeStamp.seconds, frames: normalized.numSamples, planar: true)',
        'await mixer.append(normalized, track: 0)': f'await OwnedRepeatMedia.shared.audio("{key}", pts: normalized.presentationTimeStamp.seconds, frames: normalized.numSamples, planar: false)',
    }
    for old, new in replacements.items():
        target = video if old == 'await mixer.append(admitted)' else program
        assert target.count(old) == 1, (relative, old)
        if target is video:
            video = video.replace(old, new)
        else:
            program = program.replace(old, new)
    generated = source.replace(original_video, video).replace(original_program, program)
    ready = 'streamAttached = true' if key == 'rtmp' else 'stream = RepeatCacheInertStream()'
    clear = '' if key == 'rtmp' else 'stream = nil; '
    extension = '''
extension @NAME@: RepeatCachePublisher {
    func cacheFixtureReady() {
        isRunning = true; isPaused = false; encodedInput = false; outputSizeConfigured = true
        @READY@
    }
    func cacheFixtureReject(_ reason: String) {
        if reason == "stopped" { isRunning = false }
        else if reason == "paused" { isPaused = true }
        else { encodedInput = true }
    }
    func cacheFixtureState() -> RepeatCacheState {
        .init(program: usesProgramAudio, cached: lastVideoBuffer != nil,
              lastPTS: lastVideoPTS.isNumeric ? lastVideoPTS.seconds : nil)
    }
    func cacheFixtureRepeat() async { await repeatLastFrameIfIdle(interval: 0) }
    func cacheFixtureClear() { lastVideoBuffer = nil; @CLEAR@isRunning = false }
}
'''.replace('@NAME@', name).replace('@READY@', ready).replace('@CLEAR@', clear)
    generated += extension
    (folder / (name + '.swift')).write_text(generated)
    manifest['sources'][relative] = sha(source.encode())
    manifest['generated'][name + '.swift'] = sha(generated.encode())

for relative in ['StreamBroadcast/Publisher.swift', 'scripts/publisher_repeat_cache_harness.swift']:
    manifest['sources'][relative] = sha((root / relative).read_bytes())
(folder / 'source.json').write_text(json.dumps(manifest, indent=2) + '\n')
ruby = r'''require 'yaml';require 'json';root=ARGV[0];folder=ARGV[1]
spec=YAML.load_file(File.join(root,'project.yml'));spec['name']='PublisherRepeatCache'
spec['packages'].select!{|name,_|name=='HaishinKit'}
spec['packages'].each_value{|p|p['path']=File.join(ENV.fetch('STREAM_VENDOR_ROOT',File.join(root,'Vendor')),File.basename(p['path'])) if p['path']}
spec['targets'].select!{|name,_|['StreamCore','StreamMac'].include?(name)};spec['schemes']={}
spec['targets'].each_value do |t|
 t['dependencies']&.reject!{|d| (d['target']&&!spec['targets'].key?(d['target'])) || d['package']=='Syphon'}
 t['sources'].map!{|s|s.is_a?(String) ? File.join(root,s) : s.merge('path'=>File.join(root,s['path']))};t.delete('entitlements');t.delete('info')
end
h=spec['targets'].delete('StreamMac');h['type']='tool'
h['sources']=[File.join(root,'StreamBroadcast/Publisher.swift'),File.join(folder,'RTMPPublisher.swift'),File.join(folder,'SessionPublisher.swift'),File.join(root,'scripts/publisher_repeat_cache_harness.swift')]
h['settings']['base'].delete('SWIFT_OBJC_BRIDGING_HEADER')
h['settings']['base']['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='$(inherited) STREAM_NATIVE_VALIDATION'
spec['targets']['PublisherRepeatCacheHarness']=h
spec['schemes']['PublisherRepeatCacheHarness']={'build'=>{'targets'=>{'PublisherRepeatCacheHarness'=>'all'}}}
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))'''
subprocess.run(['ruby', '-e', ruby, str(root), str(folder)], check=True)
print(folder)
