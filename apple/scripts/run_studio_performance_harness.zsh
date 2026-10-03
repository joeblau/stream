#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly WORKSPACE_DIR="build/studio-performance-validation"
mkdir -p "$WORKSPACE_DIR"
ruby -ryaml -rjson - "$WORKSPACE_DIR" <<'RUBY'
root=Dir.pwd
folder=ARGV[0]
spec=YAML.load_file('project.yml')
spec['name']='StudioPerformanceValidation'
spec['packages'].each_value{|p| p['path']=File.join(root,p['path']) if p['path']}
spec['targets'].select!{|name,_| ['StreamCore','StreamMac'].include?(name)}
# Tool fixtures exercise host code; they neither embed nor activate extensions.
spec['targets'].each_value{|t| t['dependencies']&.reject!{|d| d['target'] && !spec['targets'].key?(d['target'])}}
spec['schemes']={}
spec['targets'].each_value do |target|
  target['sources'].map!{|s| s.is_a?(String) ? File.join(root,s) : s.merge('path'=>File.join(root,s['path']))}
  target.delete('entitlements')
end
h=spec['targets'].delete('StreamMac')
h['type']='tool'
h['sources'][0]={'path'=>File.join(root,'StreamMac'),'excludes'=>['StreamMacApp.swift']}
h['sources'] << File.join(root,'scripts/studio_performance_harness.swift')
h['sources'] << File.join(root,'scripts/program_recording_fixtures.swift')
spec['targets']['StudioPerformanceHarness']=h
spec['schemes']['StudioPerformanceHarness']={'build'=>{'targets'=>{'StudioPerformanceHarness'=>'all'}}}
require File.join(root, 'scripts/desktop_transport_fixture')
StreamDesktopTransportFixture.apply(h, root)
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$WORKSPACE_DIR/project.json" --project "$WORKSPACE_DIR"
xcodebuild -project "$WORKSPACE_DIR/StudioPerformanceValidation.xcodeproj" \
    -scheme StudioPerformanceHarness -destination 'platform=macOS' \
    -derivedDataPath "$WORKSPACE_DIR/derived" CODE_SIGNING_ALLOWED=NO build
env DYLD_FRAMEWORK_PATH="$PWD/$WORKSPACE_DIR/derived/Build/Products/Debug" \
    "$WORKSPACE_DIR/derived/Build/Products/Debug/StudioPerformanceHarness" "$WORKSPACE_DIR/frames"
