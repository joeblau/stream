#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly BROWSER_AUDIO_DIR="build/browser-audio-validation"
readonly BROWSER_AUDIO_BUILD_PATH="${BROWSER_AUDIO_BUILD_PATH:-$BROWSER_AUDIO_DIR/derived}"
mkdir -p "$BROWSER_AUDIO_DIR"
ruby -ryaml -rjson - "$BROWSER_AUDIO_DIR" <<'RUBY'
root=Dir.pwd
folder=ARGV[0]
spec=YAML.load_file('project.yml')
spec['name']='BrowserAudioValidation'
spec['packages'].each_value{|p| p['path']=File.join(root,p['path']) if p['path']}
if ENV['STREAM_VENDOR_ROOT']
  spec['packages'].each_value{|p| p['path']=File.join(ENV['STREAM_VENDOR_ROOT'],File.basename(p['path'])) if p['path']}
end
spec['targets'].select!{|name,_| ['StreamCore','StreamMac'].include?(name)}
spec['targets'].each_value{|t| t['dependencies']&.reject!{|d| d['target'] && !spec['targets'].key?(d['target'])}}
spec['schemes']={}
spec['targets'].each_value do |target|
  target['sources'].map!{|s| s.is_a?(String) ? File.join(root,s) : s.merge('path'=>File.join(root,s['path']))}
  target.delete('entitlements')
end
target=spec['targets'].delete('StreamMac')
target['type']='tool'
target['settings'] ||= {}
target['settings']['base'] ||= {}
target['settings']['base']['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='$(inherited) STREAM_NATIVE_VALIDATION'
target['sources'][0]={'path'=>File.join(root,'StreamMac'),'excludes'=>['StreamMacApp.swift']}
target['sources'] << File.join(root,'scripts/browser_audio_helper_harness.swift')
target['sources'] << File.join(root,'scripts/browser_widget_visual_harness.swift')
target['sources'] << File.join(root,'scripts/program_recording_fixtures.swift')
spec['targets']['BrowserAudioHarness']=target
spec['schemes']['BrowserAudioHarness']={'build'=>{'targets'=>{'BrowserAudioHarness'=>'all'}}}
require File.join(root, 'scripts/desktop_transport_fixture')
StreamDesktopTransportFixture.apply(target, root)
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$BROWSER_AUDIO_DIR/project.json" --project "$BROWSER_AUDIO_DIR"
xcodebuild -resolvePackageDependencies -project "$BROWSER_AUDIO_DIR/BrowserAudioValidation.xcodeproj" \
  -scheme BrowserAudioHarness -derivedDataPath "$BROWSER_AUDIO_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$BROWSER_AUDIO_BUILD_PATH"
xcodebuild -project "$BROWSER_AUDIO_DIR/BrowserAudioValidation.xcodeproj" \
  -scheme BrowserAudioHarness -destination 'platform=macOS' \
  -derivedDataPath "$BROWSER_AUDIO_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build
scripts/build_browser_audio_helper.zsh
env DYLD_FRAMEWORK_PATH="${BROWSER_AUDIO_BUILD_PATH:A}/Build/Products/Debug" \
  "${BROWSER_AUDIO_BUILD_PATH:A}/Build/Products/Debug/BrowserAudioHarness" "${PWD}/build/browser-audio-helper" "$@"
