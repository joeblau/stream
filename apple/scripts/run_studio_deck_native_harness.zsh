#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly DECK_NATIVE_DIR="build/studio-deck-native-validation"
mkdir -p "$DECK_NATIVE_DIR"
ruby -ryaml -rjson - "$DECK_NATIVE_DIR" <<'RUBY'
root=Dir.pwd
folder=ARGV[0]
spec=YAML.load_file('project.yml')
spec['name']='StudioDeckNativeValidation'
spec['packages'].each_value{|p| p['path']=File.join(root,p['path']) if p['path']}
spec['targets'].select!{|name,_| ['StreamCore','StreamMac'].include?(name)}
spec['schemes']={}
spec['targets'].each_value do |target|
  target['sources'].map!{|s| s.is_a?(String) ? File.join(root,s) : s.merge('path'=>File.join(root,s['path']))}
  target.delete('entitlements')
end
target=spec['targets'].delete('StreamMac')
target['type']='tool'
target['sources'][0]={'path'=>File.join(root,'StreamMac'),'excludes'=>['StreamMacApp.swift']}
target['sources'] << File.join(root,'scripts/studio_deck_native_harness.swift')
spec['targets']['StudioDeckNativeHarness']=target
spec['schemes']['StudioDeckNativeHarness']={'build'=>{'targets'=>{'StudioDeckNativeHarness'=>'all'}}}
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$DECK_NATIVE_DIR/project.json" --project "$DECK_NATIVE_DIR"
xcodebuild -project "$DECK_NATIVE_DIR/StudioDeckNativeValidation.xcodeproj" \
  -scheme StudioDeckNativeHarness -destination 'platform=macOS' \
  -derivedDataPath "$DECK_NATIVE_DIR/derived" CODE_SIGNING_ALLOWED=NO build
env DYLD_FRAMEWORK_PATH="$PWD/$DECK_NATIVE_DIR/derived/Build/Products/Debug" \
  "$DECK_NATIVE_DIR/derived/Build/Products/Debug/StudioDeckNativeHarness"
