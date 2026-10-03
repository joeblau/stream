#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly ISO_VIDEO_DIR="build/isolated-video-validation"
readonly ISO_VIDEO_BUILD_PATH="${ISO_VIDEO_BUILD_PATH:-$ISO_VIDEO_DIR/derived}"
mkdir -p "$ISO_VIDEO_DIR"
ruby -ryaml -rjson - "$ISO_VIDEO_DIR" <<'RUBY'
root=Dir.pwd
folder=ARGV[0]
spec=YAML.load_file('project.yml')
spec['name']='IsolatedVideoValidation'
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
target['sources'][0]={'path'=>File.join(root,'StreamMac'),'excludes'=>['StreamMacApp.swift']}
target['sources'] << File.join(root,'scripts/isolated_video_harness.swift')
target['sources'] << File.join(root,'scripts/program_recording_fixtures.swift')
spec['targets']['IsolatedVideoHarness']=target
spec['schemes']['IsolatedVideoHarness']={'build'=>{'targets'=>{'IsolatedVideoHarness'=>'all'}}}
require File.join(root, 'scripts/desktop_transport_fixture')
StreamDesktopTransportFixture.apply(target, root)
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$ISO_VIDEO_DIR/project.json" --project "$ISO_VIDEO_DIR"
xcodebuild -resolvePackageDependencies -project "$ISO_VIDEO_DIR/IsolatedVideoValidation.xcodeproj" \
  -scheme IsolatedVideoHarness -derivedDataPath "$ISO_VIDEO_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$ISO_VIDEO_BUILD_PATH"
xcodebuild -project "$ISO_VIDEO_DIR/IsolatedVideoValidation.xcodeproj" \
  -scheme IsolatedVideoHarness -destination 'platform=macOS' \
  -derivedDataPath "$ISO_VIDEO_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build
env DYLD_FRAMEWORK_PATH="${ISO_VIDEO_BUILD_PATH:A}/Build/Products/Debug" \
  "${ISO_VIDEO_BUILD_PATH:A}/Build/Products/Debug/IsolatedVideoHarness" "$ISO_VIDEO_DIR/media-$(uuidgen)"
