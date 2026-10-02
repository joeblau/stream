#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly COLOR_DIR="build/color-transform-validation"
mkdir -p "$COLOR_DIR"
ruby -ryaml -rjson - "$COLOR_DIR" <<'RUBY'
root=Dir.pwd
folder=ARGV[0]
spec=YAML.load_file('project.yml')
spec['name']='ColorTransformValidation'
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
h['sources'] << File.join(root,'scripts/color_transform_harness.swift')
spec['targets']['ColorTransformHarness']=h
spec['schemes']['ColorTransformHarness']={'build'=>{'targets'=>{'ColorTransformHarness'=>'all'}}}
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$COLOR_DIR/project.json" --project "$COLOR_DIR"
xcodebuild -project "$COLOR_DIR/ColorTransformValidation.xcodeproj" \
    -scheme ColorTransformHarness -destination 'platform=macOS' \
    -derivedDataPath "$COLOR_DIR/derived" CODE_SIGNING_ALLOWED=NO build
env DYLD_FRAMEWORK_PATH="$PWD/$COLOR_DIR/derived/Build/Products/Debug" \
    "$COLOR_DIR/derived/Build/Products/Debug/ColorTransformHarness" "$COLOR_DIR/frames"
