#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly WORKSPACE_DIR="build/studio-workspace-validation"
readonly WORKSPACE_BUILD_PATH="${WORKSPACE_BUILD_PATH:-$WORKSPACE_DIR/derived}"
mkdir -p "$WORKSPACE_DIR/fixtures"
ruby -ryaml -rjson - "$WORKSPACE_DIR" <<'RUBY'
root=Dir.pwd
folder=File.expand_path(ARGV[0])
def fixture_write(path,value)
  File.write(path,value) unless File.exist?(path) && File.read(path)==value
end
spec=YAML.load_file('project.yml')
spec['name']='StudioWorkspaceValidation'
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
# These generated tool-only dependencies never read or write operator secrets.
# Runtime/Workspace switching logic stays shipping code; legacy migration and
# permission acquisition are intentionally outside this fixture's qualification.
keychain=File.read('StreamCore/KeychainStore.swift')
prefix=keychain.split('    private let service: String',2).first
abort 'Keychain fixture boundary changed' if prefix==keychain
fixture_write(File.join(folder,'fixtures/KeychainStore.swift'),prefix + <<'SWIFT')
    public init(service: String = AppGroup.keychainService) {}
    @discardableResult public func set(_ value: String, for item: Item) -> Bool { true }
    public func string(for item: Item) -> String? { nil }
    public func remove(_ item: Item) {}
}
SWIFT
spec['targets']['StreamCore']['sources']=[{'path'=>File.join(root,'StreamCore'),'excludes'=>['KeychainStore.swift']},File.join(folder,'fixtures/KeychainStore.swift')]
excluded=['StreamMacApp.swift']
generated=[]
Dir.glob('StreamMac/**/*.swift').each do |path|
  next if path.end_with?('/StreamMacApp.swift')
  source=File.read(path)
  original=source.dup
  source.gsub!('UserDefaults.standard','WorkspaceFixtureDefaults.value')
  source.gsub!(/UserDefaults\s*=\s*\.standard/,'UserDefaults = WorkspaceFixtureDefaults.value')
  if path=='StreamMac/MacAudioInput.swift'
    pattern=/    private nonisolated static func requestMicrophoneAccess\(\) async -> Bool \{.*?\n    \}\n\n    private func configureAndStart/m
    abort 'Microphone fixture boundary changed' unless source.match?(pattern)
    source.sub!(pattern,"    private nonisolated static func requestMicrophoneAccess() async -> Bool { false }\n\n    private func configureAndStart")
  elsif path=='StreamMac/DesktopStorage.swift'
    machine=/    static let machineDirectory: URL = \{.*?\n    \}\(\)/m
    migration=/    func migrateLegacyIfNeeded\(\) \{.*?\n    \}/m
    abort 'Desktop storage fixture boundary changed' unless source.match?(machine) && source.match?(migration)
    source.sub!(machine,'    static let machineDirectory: URL = WorkspaceFixtureStorage.machineDirectory')
    source.sub!(migration,"    func migrateLegacyIfNeeded() {\n        if !FileManager.default.fileExists(atPath: url.path) { saveNonSecret(.default) }\n    }")
  elsif path=='StreamMac/ProviderAccountSession.swift'
    transport='transport: @escaping ProviderTokenVault.Transport = ProviderTokenVault.network'
    abort 'Provider fixture transport boundary changed' unless source.include?(transport)
    source.sub!(transport,'transport: @escaping ProviderTokenVault.Transport = { _ in throw ProviderFailure(.unavailable) }')
  elsif path=='StreamMac/RecordingController.swift'
    directory='defaultDirectory: URL? = nil'
    abort 'Recording directory fixture boundary changed' unless source.include?(directory)
    source.sub!(directory,'defaultDirectory: URL? = WorkspaceFixtureStorage.recordingsDirectory')
  end
  next if source==original
  name=path.delete_prefix('StreamMac/').tr('/','_')
  output=File.join(folder,'fixtures',name)
  fixture_write(output,source)
  excluded << path.delete_prefix('StreamMac/')
  generated << output
end
h=spec['targets'].delete('StreamMac')
h['type']='tool'
h['settings'] ||= {}
h['settings']['base'] ||= {}
h['settings']['base']['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='$(inherited) STREAM_NATIVE_VALIDATION'
h['sources'][0]={'path'=>File.join(root,'StreamMac'),'excludes'=>excluded}
h['sources'] += generated
h['sources'] << File.join(root,'scripts/studio_workspace_harness.swift')
spec['targets']['StudioWorkspaceHarness']=h
spec['schemes']['StudioWorkspaceHarness']={'build'=>{'targets'=>{'StudioWorkspaceHarness'=>'all'}}}
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$WORKSPACE_DIR/project.json" --project "$WORKSPACE_DIR"
xcodebuild -resolvePackageDependencies -project "$WORKSPACE_DIR/StudioWorkspaceValidation.xcodeproj" \
    -scheme StudioWorkspaceHarness -derivedDataPath "$WORKSPACE_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$WORKSPACE_BUILD_PATH"
xcodebuild -project "$WORKSPACE_DIR/StudioWorkspaceValidation.xcodeproj" \
    -scheme StudioWorkspaceHarness -destination 'platform=macOS' \
    -derivedDataPath "$WORKSPACE_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build
readonly WORKSPACE_PRODUCTS="${WORKSPACE_BUILD_PATH:A}/Build/Products/Debug"
env DYLD_FRAMEWORK_PATH="$WORKSPACE_PRODUCTS" python3 - "$WORKSPACE_PRODUCTS/StudioWorkspaceHarness" <<'PY'
import subprocess,sys
try:
    raise SystemExit(subprocess.run([sys.argv[1]],timeout=90).returncode)
except subprocess.TimeoutExpired:
    print('FAIL: shipping workspace fixture exceeded its 90-second bound',flush=True)
    raise SystemExit(1)
PY
