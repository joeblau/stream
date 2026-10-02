#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly PRIVACY_DIR="build/studio-privacy-validation"
readonly PRIVACY_BUILD_PATH="${PRIVACY_BUILD_PATH:-$PRIVACY_DIR/derived}"
mkdir -p "$PRIVACY_DIR"
ruby -ryaml -rjson - "$PRIVACY_DIR" <<'RUBY'
root=Dir.pwd
folder=ARGV[0]
spec=YAML.load_file('project.yml')
spec['name']='StudioPrivacyValidation'
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
target['sources'] << File.join(root,'scripts/studio_privacy_harness.swift')
spec['targets']['StudioPrivacyHarness']=target
spec['schemes']['StudioPrivacyHarness']={'build'=>{'targets'=>{'StudioPrivacyHarness'=>'all'}}}
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$PRIVACY_DIR/project.json" --project "$PRIVACY_DIR"
xcodebuild -resolvePackageDependencies -project "$PRIVACY_DIR/StudioPrivacyValidation.xcodeproj" \
  -scheme StudioPrivacyHarness -derivedDataPath "$PRIVACY_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$PRIVACY_BUILD_PATH"
xcodebuild -project "$PRIVACY_DIR/StudioPrivacyValidation.xcodeproj" \
  -scheme StudioPrivacyHarness -destination 'platform=macOS' \
  -derivedDataPath "$PRIVACY_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build
env DYLD_FRAMEWORK_PATH="$PWD/$PRIVACY_BUILD_PATH/Build/Products/Debug" \
  "$PRIVACY_BUILD_PATH/Build/Products/Debug/StudioPrivacyHarness"
