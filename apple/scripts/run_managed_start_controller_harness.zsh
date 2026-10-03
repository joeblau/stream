#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly MANAGED_CONTROLLER_DIR="build/managed-start-controller-validation"
readonly MANAGED_CONTROLLER_BUILD_PATH="${MANAGED_CONTROLLER_BUILD_PATH:-$MANAGED_CONTROLLER_DIR/derived}"
mkdir -p "$MANAGED_CONTROLLER_DIR/fixtures"
ruby -ryaml -rjson - "$MANAGED_CONTROLLER_DIR" <<'RUBY'
root=Dir.pwd
folder=File.expand_path(ARGV[0])
spec=YAML.load_file('project.yml')
spec['name']='ManagedStartControllerValidation'
spec['packages'].each_value{|p| p['path']=File.join(root,p['path']) if p['path']}
if ENV['STREAM_VENDOR_ROOT']
  spec['packages'].each_value{|p| p['path']=File.join(ENV['STREAM_VENDOR_ROOT'],File.basename(p['path'])) if p['path']}
end
spec['targets'].select!{|name,_| ['StreamCore','StreamMac'].include?(name)}
spec['targets'].each_value do |target|
  target['dependencies']&.reject!{|d| d['target'] && !spec['targets'].key?(d['target'])}
  target['sources'].map!{|s| s.is_a?(String) ? File.join(root,s) : s.merge('path'=>File.join(root,s['path']))}
  target.delete('entitlements'); target.delete('info')
end
# Only credential/hardware boundaries are generated copies. The real shipping
# controller/dispatcher/coordinator/account/vault/server code compiles intact.
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
audio=File.read('StreamMac/MacAudioInput.swift')
pattern=/    private nonisolated static func requestMicrophoneAccess\(\) async -> Bool \{.*?\n    \}\n\n    private func configureAndStart/m
abort 'Microphone fixture boundary changed' unless audio.match?(pattern)
audio.sub!(pattern,"    private nonisolated static func requestMicrophoneAccess() async -> Bool { false }\n\n    private func configureAndStart")
File.write(File.join(folder,'fixtures/MacAudioInput.swift'),audio)
spec['targets']['StreamCore']['sources']=[{'path'=>File.join(root,'StreamCore'),'excludes'=>['KeychainStore.swift']},File.join(folder,'fixtures/KeychainStore.swift')]
target=spec['targets'].delete('StreamMac')
target['type']='tool'
target['settings']['base']['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='$(inherited) STREAM_NATIVE_VALIDATION'
target['sources'][0]={'path'=>File.join(root,'StreamMac'),'excludes'=>['StreamMacApp.swift','MacAudioInput.swift']}
target['sources'] += [File.join(folder,'fixtures/MacAudioInput.swift'),File.join(root,'scripts/managed_start_controller_harness.swift')]
spec['targets']['ManagedStartControllerHarness']=target
spec['schemes']={'ManagedStartControllerHarness'=>{'build'=>{'targets'=>{'ManagedStartControllerHarness'=>'all'}}}}
require File.join(root, 'scripts/desktop_transport_fixture')
StreamDesktopTransportFixture.apply(target, root)
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$MANAGED_CONTROLLER_DIR/project.json" --project "$MANAGED_CONTROLLER_DIR"
xcodebuild -resolvePackageDependencies -project "$MANAGED_CONTROLLER_DIR/ManagedStartControllerValidation.xcodeproj" \
    -scheme ManagedStartControllerHarness -derivedDataPath "$MANAGED_CONTROLLER_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$MANAGED_CONTROLLER_BUILD_PATH"
xcodebuild -project "$MANAGED_CONTROLLER_DIR/ManagedStartControllerValidation.xcodeproj" \
    -scheme ManagedStartControllerHarness -destination 'platform=macOS' \
    -derivedDataPath "$MANAGED_CONTROLLER_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build
readonly MANAGED_CONTROLLER_PRODUCTS="${MANAGED_CONTROLLER_BUILD_PATH:A}/Build/Products/Debug"
env DYLD_FRAMEWORK_PATH="$MANAGED_CONTROLLER_PRODUCTS" "$MANAGED_CONTROLLER_PRODUCTS/ManagedStartControllerHarness"
