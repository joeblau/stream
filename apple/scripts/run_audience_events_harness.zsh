#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly AUDIENCE_DIR="build/audience-events-validation"
readonly AUDIENCE_BUILD_PATH="${AUDIENCE_BUILD_PATH:-$AUDIENCE_DIR/derived}"
mkdir -p "$AUDIENCE_DIR"
ruby -ryaml -rjson - "$AUDIENCE_DIR" <<'RUBY'
root = Dir.pwd
folder = File.expand_path(ARGV[0])
spec = YAML.load_file('project.yml')
spec['name'] = 'AudienceEventsValidation'
spec['packages'].each_value do |package|
  next unless package['path']
  package['path'] = ENV['STREAM_VENDOR_ROOT'] ? File.join(ENV['STREAM_VENDOR_ROOT'], File.basename(package['path'])) : File.join(root, package['path'])
end
spec['targets'].select! { |name, _| ['StreamCore', 'StreamMac'].include?(name) }
spec['schemes'] = {}
spec['targets'].each_value do |target|
  target['dependencies']&.reject! { |dependency| dependency['target'] && !spec['targets'].key?(dependency['target']) }
  target['sources'].map! { |source| source.is_a?(String) ? File.join(root, source) : source.merge('path' => File.join(root, source['path'])) }
  target.delete('entitlements'); target.delete('info')
end
target = spec['targets'].delete('StreamMac'); target['type'] = 'tool'
require File.join(root, 'scripts/guest_fixture_boundaries')
# Owned defaults/storage, nil credentials and refused desktop transports.
# Shipping decoders/coordinator/dispatcher/renderer/persistence are unchanged.
StreamGuestFixtureBoundaries.apply(spec['targets']['StreamCore'], target, root, folder)
target['sources'] += ['audience_events_harness.swift', 'static_emote_audience_fixture.swift'].map { |file| File.join(root, 'scripts', file) }
spec['targets']['AudienceEventsHarness'] = target
spec['schemes']['AudienceEventsHarness'] = {'build' => {'targets' => {'AudienceEventsHarness' => 'all'}}}
File.write(File.join(folder, 'project.json'), JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$AUDIENCE_DIR/project.json" --project "$AUDIENCE_DIR"
xcodebuild -resolvePackageDependencies -project "$AUDIENCE_DIR/AudienceEventsValidation.xcodeproj" \
  -scheme AudienceEventsHarness -derivedDataPath "$AUDIENCE_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$AUDIENCE_BUILD_PATH" --require-relay-policy
xcodebuild -project "$AUDIENCE_DIR/AudienceEventsValidation.xcodeproj" -scheme AudienceEventsHarness \
  -destination 'platform=macOS' -derivedDataPath "$AUDIENCE_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build
readonly AUDIENCE_PRODUCTS="${AUDIENCE_BUILD_PATH:A}/Build/Products/Debug"
readonly AUDIENCE_ARTIFACTS="$AUDIENCE_DIR/artifacts-$(uuidgen)"
env DYLD_FRAMEWORK_PATH="$AUDIENCE_PRODUCTS" "$AUDIENCE_PRODUCTS/AudienceEventsHarness" --artifacts-dir "${AUDIENCE_ARTIFACTS:A}"
