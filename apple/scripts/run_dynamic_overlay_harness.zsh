#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly OVERLAY_DIR="build/dynamic-overlay-validation"
mkdir -p "$OVERLAY_DIR"
ruby -ryaml -rjson - "$OVERLAY_DIR" <<'RUBY'
root=Dir.pwd
folder=ARGV[0]
spec=YAML.load_file('project.yml')
spec['name']='DynamicOverlayValidation'
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
h['sources'] << File.join(root,'scripts/dynamic_overlay_harness.swift')
spec['targets']['DynamicOverlayHarness']=h
spec['schemes']['DynamicOverlayHarness']={'build'=>{'targets'=>{'DynamicOverlayHarness'=>'all'}}}
require File.join(root, 'scripts/desktop_transport_fixture')
StreamDesktopTransportFixture.apply(h, root)
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$OVERLAY_DIR/project.json" --project "$OVERLAY_DIR"
xcodebuild -project "$OVERLAY_DIR/DynamicOverlayValidation.xcodeproj" \
    -scheme DynamicOverlayHarness -destination 'platform=macOS' \
    -derivedDataPath "$OVERLAY_DIR/derived" CODE_SIGNING_ALLOWED=NO build
env DYLD_FRAMEWORK_PATH="$PWD/$OVERLAY_DIR/derived/Build/Products/Debug" \
    "$OVERLAY_DIR/derived/Build/Products/Debug/DynamicOverlayHarness" "$OVERLAY_DIR/frames"
