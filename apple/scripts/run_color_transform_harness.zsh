#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly COLOR_DIR="build/color-transform-validation"
readonly COLOR_BUILD_PATH="${COLOR_BUILD_PATH:-$COLOR_DIR/derived}"
mkdir -p "$COLOR_DIR"
ruby -ryaml -rjson - "$COLOR_DIR" <<'RUBY'
root=Dir.pwd
folder=ARGV[0]
spec=YAML.load_file('project.yml')
spec['name']='ColorTransformValidation'
spec['packages'].each_value{|p| p['path']= ENV['STREAM_VENDOR_ROOT'] ? File.join(ENV['STREAM_VENDOR_ROOT'],File.basename(p['path'])) : File.join(root,p['path']) if p['path']}
spec['targets'].select!{|name,_| ['StreamCore','StreamCoreTests','StreamMac'].include?(name)}
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
h['sources'] << File.join(root,'scripts/color_transform_gpu_harness.swift')
spec['targets']['ColorTransformHarness']=h
spec['schemes']['ColorTransformHarness']={'build'=>{'targets'=>{'ColorTransformHarness'=>'all'}}}
spec['schemes']['ColorTransformCoreTests']={'build'=>{'targets'=>{'StreamCoreTests'=>['test','build']}},'test'=>{'config'=>'Debug','targets'=>['StreamCoreTests']}}
require File.join(root, 'scripts/desktop_transport_fixture')
StreamDesktopTransportFixture.apply(h, root)
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$COLOR_DIR/project.json" --project "$COLOR_DIR"
xcodebuild -resolvePackageDependencies -project "$COLOR_DIR/ColorTransformValidation.xcodeproj" \
    -scheme ColorTransformHarness -derivedDataPath "$COLOR_BUILD_PATH" -jobs 2
python3 scripts/repair_desktop_transport_archives.py "$COLOR_BUILD_PATH"
# Build tests first: a tests-only Xcode plan can prune app package frameworks.
if [[ "${COLOR_CORE_TESTS:-0}" == "1" ]]; then
    xcodebuild -project "$COLOR_DIR/ColorTransformValidation.xcodeproj" \
        -scheme ColorTransformCoreTests -destination 'platform=macOS' \
        -derivedDataPath "$COLOR_BUILD_PATH" -jobs 2 OTHER_SWIFT_FLAGS='-j2' \
        CODE_SIGNING_ALLOWED=NO -only-testing:StreamCoreTests/ColorTransformTests test
fi
xcodebuild -project "$COLOR_DIR/ColorTransformValidation.xcodeproj" \
    -scheme ColorTransformHarness -destination 'platform=macOS' \
    -derivedDataPath "$COLOR_BUILD_PATH" -jobs 2 OTHER_SWIFT_FLAGS='-j2' CODE_SIGNING_ALLOWED=NO build

readonly COLOR_PRODUCTS="${COLOR_BUILD_PATH:A}/Build/Products/Debug"
env DYLD_FRAMEWORK_PATH="$COLOR_PRODUCTS" \
    "$COLOR_PRODUCTS/ColorTransformHarness" "$COLOR_DIR/frames"
