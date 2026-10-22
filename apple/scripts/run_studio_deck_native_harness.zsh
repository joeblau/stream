#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Validate dependencies before the expensive build. Ordinary FFmpeg is enough
# for this RTMP-only branch; CI separately requires SRT for shared publishing.
if [[ "${STREAM_DECK_VALIDATE_TRANSPORT:-0}" == "1" ]]; then
  STREAM_FFMPEG_BIN="$(python3 scripts/ffmpeg_receiver.py)"
  export STREAM_FFMPEG_BIN
fi
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
target['settings']['base']['OTHER_SWIFT_FLAGS']='$(inherited) -j2'
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
# Deny physical microphone capture in this generated tool. Composition,
# audio mixing, real native publishers and recording writers remain shipping code.
mic=File.read('StreamMac/MacAudioInput.swift')
start=mic.index('    private nonisolated static func requestMicrophoneAccess() async -> Bool {')
finish=mic.index('    private func configureAndStart(device:',start)
abort 'Microphone fixture boundary changed' unless start && finish
File.write(File.join(folder,'fixtures/MacAudioInput.swift'),mic[0...start] + "    private nonisolated static func requestMicrophoneAccess() async -> Bool { false }\n\n" + mic[finish..])
controller=File.read('StreamMac/StreamController.swift')
constructor='DesktopResilienceCoordinator(url: DesktopStorage.projectDirectory.appendingPathComponent("resilience.json"))'
abort 'Owned lifecycle constructor boundary changed' unless controller.scan(constructor).length == 1
# This generated workload explicitly simulates an unlocked session and later
# injects lifecycle events. Production still samples the real login session.
controller.sub!(constructor, 'DesktopResilienceCoordinator(url: DesktopStorage.projectDirectory.appendingPathComponent("resilience.json"), observeSystem: false, initialSessionState: .unlocked)')
File.write(File.join(folder,'fixtures/StreamController.swift'),controller)
target['sources'][0]={'path'=>File.join(root,'StreamMac'),'excludes'=>['StreamMacApp.swift','MacAudioInput.swift','StreamController.swift']}
target['sources'] << File.join(root,folder,'fixtures/MacAudioInput.swift')
target['sources'] << File.join(root,folder,'fixtures/StreamController.swift')
target['sources'] << File.join(root,'scripts/studio_deck_native_harness.swift')
wire=File.read('scripts/studio_local_control_harness.swift')
wire_start=wire.index('@MainActor final class MemoryCredentials:')
wire_end=wire.index('/// Actual loopback peers')
abort 'Wire fixture extraction boundary changed' unless wire_start && wire_end && wire_end>wire_start
File.write(File.join(folder,'fixtures/VisualWireClient.swift'), "import Foundation\nimport Network\nimport Security\n" + wire[wire_start...wire_end])
target['sources'] << File.join(root,folder,'fixtures/VisualWireClient.swift')
target['sources'] << File.join(root,'scripts/studio_deck_transport_fixtures.swift')
target['sources'] << File.join(root,'scripts/studio_deck_process_diagnostics.swift')
spec['targets']['StudioDeckNativeHarness']=target
spec['schemes']['StudioDeckNativeHarness']={'build'=>{'targets'=>{'StudioDeckNativeHarness'=>'all'}}}
require File.join(root, 'scripts/desktop_transport_fixture')
StreamDesktopTransportFixture.apply(target, root)
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$DECK_NATIVE_DIR/project.json" --project "$DECK_NATIVE_DIR"
xcodebuild -resolvePackageDependencies -project "$DECK_NATIVE_DIR/StudioDeckNativeValidation.xcodeproj" \
  -scheme StudioDeckNativeHarness -derivedDataPath "$DECK_NATIVE_BUILD_PATH" -jobs 2
python3 scripts/repair_desktop_transport_archives.py "$DECK_NATIVE_BUILD_PATH"
xcodebuild -project "$DECK_NATIVE_DIR/StudioDeckNativeValidation.xcodeproj" \
  -scheme StudioDeckNativeHarness -destination 'platform=macOS' \
  -derivedDataPath "$DECK_NATIVE_BUILD_PATH" -jobs 2 SWIFT_MAXIMUM_CONCURRENT_COMPILE_TASKS=2 OTHER_SWIFT_FLAGS='-j2' CODE_SIGNING_ALLOWED=NO build
readonly DECK_NATIVE_PRODUCTS="${DECK_NATIVE_BUILD_PATH:A}/Build/Products/Debug"
env DYLD_FRAMEWORK_PATH="$DECK_NATIVE_PRODUCTS" STREAM_DECK_NATIVE_ARTIFACT_ROOT="${DECK_NATIVE_DIR:A}" \
  "$DECK_NATIVE_PRODUCTS/StudioDeckNativeHarness"
