#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly COMMENT_DIR="build/comment-presentation-validation"
readonly COMMENT_BUILD_PATH="${COMMENT_BUILD_PATH:-$COMMENT_DIR/derived}"
mkdir -p "$COMMENT_DIR"
ruby -ryaml -rjson - "$COMMENT_DIR" <<'RUBY'
root=Dir.pwd
folder=ARGV[0]
spec=YAML.load_file('project.yml')
spec['name']='CommentPresentationValidation'
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
target['sources'] << File.join(root,'scripts/comment_presentation_harness.swift')
target['sources'] << File.join(root,'scripts/program_recording_fixtures.swift')
spec['targets']['CommentPresentationHarness']=target
spec['schemes']['CommentPresentationHarness']={'build'=>{'targets'=>{'CommentPresentationHarness'=>'all'}}}
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$COMMENT_DIR/project.json" --project "$COMMENT_DIR"
xcodebuild -resolvePackageDependencies -project "$COMMENT_DIR/CommentPresentationValidation.xcodeproj" \
  -scheme CommentPresentationHarness -derivedDataPath "$COMMENT_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$COMMENT_BUILD_PATH"
xcodebuild -project "$COMMENT_DIR/CommentPresentationValidation.xcodeproj" \
  -scheme CommentPresentationHarness -destination 'platform=macOS' \
  -derivedDataPath "$COMMENT_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build
env DYLD_FRAMEWORK_PATH="${COMMENT_BUILD_PATH:A}/Build/Products/Debug" \
  "${COMMENT_BUILD_PATH:A}/Build/Products/Debug/CommentPresentationHarness"
