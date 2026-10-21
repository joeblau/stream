#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
GUEST_DIR="build/guest-return-video-privacy-validation"
STREAM_GUEST_VIDEO_PRIVACY_BUILD_PATH=${STREAM_GUEST_VIDEO_PRIVACY_BUILD_PATH:-${GUEST_DIR}/derived}
mkdir -p "${GUEST_DIR}"
ruby -ryaml -rjson - "${GUEST_DIR}" <<'RUBY'
root = Dir.pwd
folder = File.expand_path(ARGV[0])
spec = YAML.load_file('project.yml')
spec['name'] = 'GuestReturnVideoPrivacyValidation'
spec['packages'].each_value do |package|
  next unless package['path']
  package['path'] = ENV['STREAM_VENDOR_ROOT'] ? File.join(ENV['STREAM_VENDOR_ROOT'], File.basename(package['path'])) : File.join(root, package['path'])
end
spec['targets'].select! { |name, _| ['StreamCore', 'StreamMac'].include?(name) }
spec['schemes'] = {}
spec['targets'].each_value do |target|
  target['dependencies']&.reject! { |dependency| dependency['target'] && !spec['targets'].key?(dependency['target']) }
  target['sources'].map! { |source| source.is_a?(String) ? File.join(root, source) : source.merge('path' => File.join(root, source['path'])) }
  # This raster-only tool neither embeds nor activates extensions.
  target.delete('entitlements')
  target.delete('info')
end
target = spec['targets'].delete('StreamMac')
target['type'] = 'tool'
require File.join(root, 'scripts/guest_fixture_boundaries')
StreamGuestFixtureBoundaries.apply(spec['targets']['StreamCore'], target, root, folder)
target['sources'] << File.join(root, 'scripts/native_guest_return_video_privacy_harness.swift')
spec['targets']['GuestReturnVideoPrivacyHarness'] = target
spec['schemes']['GuestReturnVideoPrivacyHarness'] = { 'build' => { 'targets' => { 'GuestReturnVideoPrivacyHarness' => 'all' } } }
File.write(File.join(folder, 'project.json'), JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "${GUEST_DIR}/project.json" --project "${GUEST_DIR}"
xcodebuild -resolvePackageDependencies -project "${GUEST_DIR}/GuestReturnVideoPrivacyValidation.xcodeproj" \
  -scheme GuestReturnVideoPrivacyHarness -derivedDataPath "${STREAM_GUEST_VIDEO_PRIVACY_BUILD_PATH}"
python3 scripts/repair_desktop_transport_archives.py "${STREAM_GUEST_VIDEO_PRIVACY_BUILD_PATH}"
xcodebuild -project "${GUEST_DIR}/GuestReturnVideoPrivacyValidation.xcodeproj" -scheme GuestReturnVideoPrivacyHarness \
  -jobs "${STREAM_NATIVE_BUILD_JOBS:-4}" -destination 'platform=macOS' -derivedDataPath "${STREAM_GUEST_VIDEO_PRIVACY_BUILD_PATH}" CODE_SIGNING_ALLOWED=NO build
GUEST_PRODUCTS="${STREAM_GUEST_VIDEO_PRIVACY_BUILD_PATH:A}/Build/Products/Debug"
env DYLD_FRAMEWORK_PATH="${GUEST_PRODUCTS}" "${GUEST_PRODUCTS}/GuestReturnVideoPrivacyHarness"
