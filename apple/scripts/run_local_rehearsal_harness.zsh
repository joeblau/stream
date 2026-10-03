#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly REHEARSAL_DIR="build/local-rehearsal-validation"
readonly REHEARSAL_BUILD_PATH="${REHEARSAL_BUILD_PATH:-$REHEARSAL_DIR/derived}"
mkdir -p "$REHEARSAL_DIR/fixtures"
ruby -ryaml -rjson - "$REHEARSAL_DIR" <<'RUBY'
root=Dir.pwd
folder=File.expand_path(ARGV[0])
spec=YAML.load_file('project.yml')
spec['name']='LocalRehearsalValidation'
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
# Only these generated tool copies replace hardware/secret/transport boundaries.
# The shipping rehearsal methods, real compositor, mixer and writer are intact.
keychain=File.read('StreamCore/KeychainStore.swift')
prefix=keychain.split('    private let service: String',2).first
abort 'Keychain fixture boundary changed' if prefix == keychain
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
controller=File.read('StreamMac/StreamController.swift')
anchor='    private func startAudioEngine() {'
abort 'Capture holdback fixture boundary changed' unless controller.include?(anchor)
controller.sub!(anchor, <<'SWIFT' + anchor)
    // Tool-only access to the existing opt-in timing lease. Source clocks,
    // mixer scheduling, writer and rehearsal lifecycle are shipping code.
    func fixtureReserveAudioHoldback(_ token: UUID, milliseconds: Double) async -> Bool {
        await audioEngine.reserveCaptureHoldback(token: token, milliseconds: milliseconds)
    }
SWIFT
File.write(File.join(folder,'fixtures/StreamController.swift'),controller)

spec['targets']['StreamCore']['sources']=[{'path'=>File.join(root,'StreamCore'),'excludes'=>['KeychainStore.swift']},File.join(folder,'fixtures/KeychainStore.swift')]
target=spec['targets'].delete('StreamMac')
target['type']='tool'
target['settings'] ||= {}
target['settings']['base'] ||= {}
target['settings']['base']['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='$(inherited) STREAM_NATIVE_VALIDATION'
target['sources'][0]={'path'=>File.join(root,'StreamMac'),'excludes'=>['StreamMacApp.swift','MacAudioInput.swift','StreamController.swift']}
target['sources'] << File.join(folder,'fixtures/MacAudioInput.swift')
target['sources'] << File.join(folder,'fixtures/StreamController.swift')
target['sources'] += ['local_rehearsal_harness.swift','program_recording_fixtures.swift'].map{|name| File.join(root,'scripts',name)}
spec['targets']['LocalRehearsalHarness']=target
spec['schemes']={'LocalRehearsalHarness'=>{'build'=>{'targets'=>{'LocalRehearsalHarness'=>'all'}}}}
require File.join(root, 'scripts/desktop_transport_fixture')
StreamDesktopTransportFixture.apply(target, root)
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$REHEARSAL_DIR/project.json" --project "$REHEARSAL_DIR"
xcodebuild -resolvePackageDependencies -project "$REHEARSAL_DIR/LocalRehearsalValidation.xcodeproj" \
  -scheme LocalRehearsalHarness -derivedDataPath "$REHEARSAL_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$REHEARSAL_BUILD_PATH"
xcodebuild -project "$REHEARSAL_DIR/LocalRehearsalValidation.xcodeproj" \
  -scheme LocalRehearsalHarness -destination 'platform=macOS' \
  -derivedDataPath "$REHEARSAL_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build
readonly REHEARSAL_PRODUCTS="${REHEARSAL_BUILD_PATH:A}/Build/Products/Debug"
if [[ -n "${REHEARSAL_AUDIO_HOLDBACK_MS:-}" ]]; then
  env DYLD_FRAMEWORK_PATH="$REHEARSAL_PRODUCTS" \
    "$REHEARSAL_PRODUCTS/LocalRehearsalHarness" "$PWD/$REHEARSAL_DIR/media-$(uuidgen)"
else
  # Both runs preserve actual compositor/mixer clocks. The existing opt-in
  # lease delays PCM delivery to reproduce a real capture-route boundary.
  env DYLD_FRAMEWORK_PATH="$REHEARSAL_PRODUCTS" \
    "$REHEARSAL_PRODUCTS/LocalRehearsalHarness" "$PWD/$REHEARSAL_DIR/media-$(uuidgen)"
  env REHEARSAL_AUDIO_HOLDBACK_MS=60 DYLD_FRAMEWORK_PATH="$REHEARSAL_PRODUCTS" \
    "$REHEARSAL_PRODUCTS/LocalRehearsalHarness" "$PWD/$REHEARSAL_DIR/media-$(uuidgen)"
fi
