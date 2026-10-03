#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly DECK_NATIVE_DIR="build/studio-deck-native-validation"
readonly DECK_NATIVE_BUILD_PATH="${DECK_NATIVE_BUILD_PATH:-$DECK_NATIVE_DIR/derived}"
mkdir -p "$DECK_NATIVE_DIR/fixtures"
ruby -ryaml -rjson - "$DECK_NATIVE_DIR" <<'RUBY'
root=Dir.pwd
folder=ARGV[0]
spec=YAML.load_file('project.yml')
spec['name']='StudioDeckNativeValidation'
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
target['settings']['base']['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='$(inherited) STREAM_NATIVE_VALIDATION'
keychain=File.read('StreamCore/KeychainStore.swift')
prefix=keychain.split('    private let service: String',2).first
abort 'Keychain fixture boundary changed' if prefix==keychain
File.write(File.join(folder,'fixtures/KeychainStore.swift'),prefix + <<'SWIFT')
    public init(service: String = AppGroup.keychainService) {}
    @discardableResult public func set(_ value: String, for item: Item) -> Bool { true }
    public func string(for item: Item) -> String? { nil }
    public func remove(_ item: Item) {}
}
SWIFT
spec['targets']['StreamCore']['sources']=[{'path'=>File.join(root,'StreamCore'),'excludes'=>['KeychainStore.swift']},File.join(root,folder,'fixtures/KeychainStore.swift')]
target['sources'][0]={'path'=>File.join(root,'StreamMac'),'excludes'=>['StreamMacApp.swift']}
target['sources'] << File.join(root,'scripts/studio_deck_native_harness.swift')
spec['targets']['StudioDeckNativeHarness']=target
spec['schemes']['StudioDeckNativeHarness']={'build'=>{'targets'=>{'StudioDeckNativeHarness'=>'all'}}}
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$DECK_NATIVE_DIR/project.json" --project "$DECK_NATIVE_DIR"
xcodebuild -resolvePackageDependencies -project "$DECK_NATIVE_DIR/StudioDeckNativeValidation.xcodeproj" \
  -scheme StudioDeckNativeHarness -derivedDataPath "$DECK_NATIVE_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$DECK_NATIVE_BUILD_PATH"
xcodebuild -project "$DECK_NATIVE_DIR/StudioDeckNativeValidation.xcodeproj" \
  -scheme StudioDeckNativeHarness -destination 'platform=macOS' \
  -derivedDataPath "$DECK_NATIVE_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build
readonly DECK_NATIVE_PRODUCTS="${DECK_NATIVE_BUILD_PATH:A}/Build/Products/Debug"
env DYLD_FRAMEWORK_PATH="$DECK_NATIVE_PRODUCTS" "$DECK_NATIVE_PRODUCTS/StudioDeckNativeHarness"
