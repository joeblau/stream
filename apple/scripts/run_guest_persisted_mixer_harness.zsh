#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
GUEST_MIXER_DIR="build/guest-persisted-mixer-validation"
GUEST_PERSISTED_MIXER_BUILD_PATH=${GUEST_PERSISTED_MIXER_BUILD_PATH:-${GUEST_MIXER_DIR}/derived}
mkdir -p "${GUEST_MIXER_DIR}"
ruby -ryaml -rjson - "${GUEST_MIXER_DIR}" <<'RUBY'
root = Dir.pwd
folder = File.expand_path(ARGV[0])
spec = YAML.load_file('project.yml')
spec['name'] = 'GuestPersistedMixerValidation'
spec['packages'].each_value do |package|
  next unless package['path']
  package['path'] = ENV['STREAM_VENDOR_ROOT'] ? File.join(ENV['STREAM_VENDOR_ROOT'], File.basename(package['path'])) : File.join(root, package['path'])
end
spec['targets'].select! { |name, _| ['StreamCore', 'StreamMac'].include?(name) }
spec['schemes'] = {}
spec['targets'].each_value do |target|
  target['dependencies']&.reject! { |dependency| dependency['target'] && !spec['targets'].key?(dependency['target']) }
  target['sources'].map! { |source| source.is_a?(String) ? File.join(root, source) : source.merge('path' => File.join(root, source['path'])) }
  target.delete('entitlements')
  target.delete('info')
end
target = spec['targets'].delete('StreamMac')
target['type'] = 'tool'
require File.join(root, 'scripts/guest_fixture_boundaries')
StreamGuestFixtureBoundaries.apply(spec['targets']['StreamCore'], target, root, folder)
target['sources'] << File.join(root, 'scripts/guest_persisted_mixer_harness.swift')
target['sources'] << File.join(root, 'scripts/program_recording_fixtures.swift')
spec['targets']['GuestPersistedMixerHarness'] = target
spec['schemes']['GuestPersistedMixerHarness'] = { 'build' => { 'targets' => { 'GuestPersistedMixerHarness' => 'all' } } }
File.write(File.join(folder, 'project.json'), JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "${GUEST_MIXER_DIR}/project.json" --project "${GUEST_MIXER_DIR}"
xcodebuild -resolvePackageDependencies -project "${GUEST_MIXER_DIR}/GuestPersistedMixerValidation.xcodeproj" \
  -scheme GuestPersistedMixerHarness -derivedDataPath "${GUEST_PERSISTED_MIXER_BUILD_PATH}"
python3 scripts/repair_desktop_transport_archives.py "${GUEST_PERSISTED_MIXER_BUILD_PATH}"
xcodebuild -project "${GUEST_MIXER_DIR}/GuestPersistedMixerValidation.xcodeproj" -scheme GuestPersistedMixerHarness \
  -destination 'platform=macOS' -derivedDataPath "${GUEST_PERSISTED_MIXER_BUILD_PATH}" CODE_SIGNING_ALLOWED=NO build
GUEST_MIXER_PRODUCTS="${GUEST_PERSISTED_MIXER_BUILD_PATH:A}/Build/Products/Debug"
env DYLD_FRAMEWORK_PATH="${GUEST_MIXER_PRODUCTS}" "${GUEST_MIXER_PRODUCTS}/GuestPersistedMixerHarness" "$@"
