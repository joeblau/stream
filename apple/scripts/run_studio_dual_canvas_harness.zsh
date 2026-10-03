#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly DUAL_CANVAS_DIR="build/studio-dual-canvas-validation"
readonly DUAL_CANVAS_BUILD_PATH="${DUAL_CANVAS_BUILD_PATH:-$DUAL_CANVAS_DIR/derived}"
mkdir -p "$DUAL_CANVAS_DIR"
ruby -ryaml -rjson - "$DUAL_CANVAS_DIR" <<'RUBY'
root=Dir.pwd
folder=ARGV[0]
spec=YAML.load_file('project.yml')
spec['name']='StudioDualCanvasValidation'
spec['packages'].each_value{|p| p['path']=File.join(root,p['path']) if p['path']}
if ENV['STREAM_VENDOR_ROOT']
  spec['packages'].each_value{|p| p['path']=File.join(ENV['STREAM_VENDOR_ROOT'],File.basename(p['path'])) if p['path']}
end
spec['targets'].select!{|name,_| ['StreamCore','StreamMac'].include?(name)}
# Tool fixtures exercise host code; they neither embed nor activate extensions.
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
target['sources'] << File.join(root,'scripts/studio_dual_canvas_harness.swift')
target['sources'] << File.join(root,'scripts/program_recording_fixtures.swift')
spec['targets']['StudioDualCanvasHarness']=target
spec['schemes']['StudioDualCanvasHarness']={'build'=>{'targets'=>{'StudioDualCanvasHarness'=>'all'}}}
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$DUAL_CANVAS_DIR/project.json" --project "$DUAL_CANVAS_DIR"
xcodebuild -resolvePackageDependencies -project "$DUAL_CANVAS_DIR/StudioDualCanvasValidation.xcodeproj" \
  -scheme StudioDualCanvasHarness -derivedDataPath "$DUAL_CANVAS_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$DUAL_CANVAS_BUILD_PATH"
xcodebuild -project "$DUAL_CANVAS_DIR/StudioDualCanvasValidation.xcodeproj" \
  -scheme StudioDualCanvasHarness -destination 'platform=macOS' \
  -derivedDataPath "$DUAL_CANVAS_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build
readonly DUAL_CANVAS_PRODUCTS="${DUAL_CANVAS_BUILD_PATH:A}/Build/Products/Debug"
env DYLD_FRAMEWORK_PATH="$DUAL_CANVAS_PRODUCTS" \
  "$DUAL_CANVAS_PRODUCTS/StudioDualCanvasHarness"
