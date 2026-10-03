#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly LOCAL_SHORTCUT_DIR="build/local-shortcut-validation"
readonly LOCAL_SHORTCUT_BUILD_PATH="${LOCAL_SHORTCUT_BUILD_PATH:-$LOCAL_SHORTCUT_DIR/derived}"
mkdir -p "$LOCAL_SHORTCUT_DIR/fixtures"
ruby -ryaml -rjson - "$LOCAL_SHORTCUT_DIR" <<'RUBY'
root=Dir.pwd
folder=File.expand_path(ARGV[0])
def fixture_write(path, value)
  File.write(path,value) unless File.exist?(path) && File.read(path)==value
end
spec=YAML.load_file('project.yml')
spec['name']='LocalShortcutValidation'
spec['packages'].each_value{|p| p['path']=File.join(root,p['path']) if p['path']}
if ENV['STREAM_VENDOR_ROOT']
  spec['packages'].each_value{|p| p['path']=File.join(ENV['STREAM_VENDOR_ROOT'],File.basename(p['path'])) if p['path']}
end
spec['targets'].select!{|name,_| ['StreamCore','StreamMac'].include?(name)}
spec['targets'].each_value do |target|
  target['dependencies']&.reject!{|d| d['target'] && !spec['targets'].key?(d['target'])}
  target['sources'].map!{|s| s.is_a?(String) ? File.join(root,s) : s.merge('path'=>File.join(root,s['path']))}
  target.delete('entitlements')
end
# Generated tool-only boundaries: no operator credentials, capture requests or
# direct-live preferences. Shortcut/router/catalog/dispatcher code is unchanged.
keychain=File.read('StreamCore/KeychainStore.swift')
prefix=keychain.split('    private let service: String',2).first
abort 'Keychain fixture boundary changed' if prefix == keychain
fixture_write(File.join(folder,'fixtures/KeychainStore.swift'),prefix + <<'SWIFT')
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
fixture_write(File.join(folder,'fixtures/MacAudioInput.swift'),audio)
preview=File.read('StreamMac/PreviewProgramModel.swift')
abort 'Preview preference boundary changed' unless preview.include?('UserDefaults.standard')
preview.gsub!('UserDefaults.standard','ShortcutFixtureDefaults.value')
fixture_write(File.join(folder,'fixtures/PreviewProgramModel.swift'),preview)
spec['targets']['StreamCore']['sources']=[{'path'=>File.join(root,'StreamCore'),'excludes'=>['KeychainStore.swift']},File.join(folder,'fixtures/KeychainStore.swift')]
target=spec['targets'].delete('StreamMac')
target['type']='tool'
target['settings'] ||= {}
target['settings']['base'] ||= {}
target['settings']['base']['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='$(inherited) STREAM_NATIVE_VALIDATION'
target['sources'][0]={'path'=>File.join(root,'StreamMac'),'excludes'=>['StreamMacApp.swift','MacAudioInput.swift','PreviewProgramModel.swift']}
target['sources'] += ['MacAudioInput.swift','PreviewProgramModel.swift'].map{|name| File.join(folder,'fixtures',name)}
target['sources'] << File.join(root,'scripts/local_shortcut_harness.swift')
spec['targets']['LocalShortcutHarness']=target
spec['schemes']={'LocalShortcutHarness'=>{'build'=>{'targets'=>{'LocalShortcutHarness'=>'all'}}}}
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$LOCAL_SHORTCUT_DIR/project.json" --project "$LOCAL_SHORTCUT_DIR"
xcodebuild -resolvePackageDependencies -project "$LOCAL_SHORTCUT_DIR/LocalShortcutValidation.xcodeproj" \
  -scheme LocalShortcutHarness -derivedDataPath "$LOCAL_SHORTCUT_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$LOCAL_SHORTCUT_BUILD_PATH"
xcodebuild -project "$LOCAL_SHORTCUT_DIR/LocalShortcutValidation.xcodeproj" \
  -scheme LocalShortcutHarness -destination 'platform=macOS' \
  -derivedDataPath "$LOCAL_SHORTCUT_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build
readonly LOCAL_SHORTCUT_PRODUCTS="${LOCAL_SHORTCUT_BUILD_PATH:A}/Build/Products/Debug"
env DYLD_FRAMEWORK_PATH="$LOCAL_SHORTCUT_PRODUCTS" python3 - "$LOCAL_SHORTCUT_PRODUCTS/LocalShortcutHarness" <<'PY'
import subprocess,sys
try:
    raise SystemExit(subprocess.run([sys.argv[1]],timeout=45).returncode)
except subprocess.TimeoutExpired:
    print('FAIL: owned AppKit event/focus qualification exceeded its 45-second bound',flush=True)
    raise SystemExit(1)
PY
