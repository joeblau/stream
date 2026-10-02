#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly CHAT_DIR="build/recording-chat-validation"
readonly CHAT_BUILD_PATH="${CHAT_BUILD_PATH:-$CHAT_DIR/derived}"
mkdir -p "$CHAT_DIR"
ruby -ryaml -rjson - "$CHAT_DIR" <<'RUBY'
root=Dir.pwd
folder=ARGV[0]
spec=YAML.load_file('project.yml')
spec['name']='RecordingChatValidation'
spec['packages'].each_value{|p| p['path']=File.join(root,p['path']) if p['path']}
if ENV['STREAM_VENDOR_ROOT']
  spec['packages'].each_value{|p| p['path']=File.join(ENV['STREAM_VENDOR_ROOT'],File.basename(p['path'])) if p['path']}
end
spec['targets'].select!{|name,_| ['StreamCore','StreamMac'].include?(name)}
spec['schemes']={}
spec['targets'].each_value do |target|
  target['sources'].map!{|s| s.is_a?(String) ? File.join(root,s) : s.merge('path'=>File.join(root,s['path']))}
  target.delete('entitlements')
end
target=spec['targets'].delete('StreamMac')
target['type']='tool'
target['sources'][0]={'path'=>File.join(root,'StreamMac'),'excludes'=>['StreamMacApp.swift']}
target['sources'] << File.join(root,'scripts/recording_chat_harness.swift')
target['sources'] << File.join(root,'scripts/program_recording_fixtures.swift')
spec['targets']['RecordingChatHarness']=target
spec['schemes']['RecordingChatHarness']={'build'=>{'targets'=>{'RecordingChatHarness'=>'all'}}}
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$CHAT_DIR/project.json" --project "$CHAT_DIR"
xcodebuild -resolvePackageDependencies -project "$CHAT_DIR/RecordingChatValidation.xcodeproj" \
  -scheme RecordingChatHarness -derivedDataPath "$CHAT_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$CHAT_BUILD_PATH"
xcodebuild -project "$CHAT_DIR/RecordingChatValidation.xcodeproj" \
  -scheme RecordingChatHarness -destination 'platform=macOS' \
  -derivedDataPath "$CHAT_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build
env DYLD_FRAMEWORK_PATH="${CHAT_BUILD_PATH:A}/Build/Products/Debug" \
  "${CHAT_BUILD_PATH:A}/Build/Products/Debug/RecordingChatHarness"
