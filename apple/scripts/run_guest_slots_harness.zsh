#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly SLOTS_DIR="build/guest-slots-validation"
readonly GUEST_SLOTS_BUILD_PATH="${GUEST_SLOTS_BUILD_PATH:-${SLOTS_DIR}/derived}"
mkdir -p "$SLOTS_DIR"
ruby -ryaml -rjson - "$SLOTS_DIR" <<'RUBY'
root = Dir.pwd
folder = File.expand_path(ARGV[0])
spec = YAML.load_file('project.yml')
spec['name'] = 'GuestSlotsValidation'
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
StreamGuestFixtureBoundaries.apply(spec['targets']['StreamCore'], target, root, folder)
target['sources'] << File.join(root, 'scripts/guest_slots_harness.swift')
spec['targets']['GuestSlotsHarness'] = target
spec['schemes']['GuestSlotsHarness'] = {'build' => {'targets' => {'GuestSlotsHarness' => 'all'}}}
File.write(File.join(folder, 'project.json'), JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$SLOTS_DIR/project.json" --project "$SLOTS_DIR"
xcodebuild -resolvePackageDependencies -project "$SLOTS_DIR/GuestSlotsValidation.xcodeproj" \
  -scheme GuestSlotsHarness -derivedDataPath "$GUEST_SLOTS_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$GUEST_SLOTS_BUILD_PATH"
xcodebuild -project "$SLOTS_DIR/GuestSlotsValidation.xcodeproj" -scheme GuestSlotsHarness \
  -destination 'platform=macOS' -derivedDataPath "$GUEST_SLOTS_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build
readonly SLOTS_PRODUCTS="${GUEST_SLOTS_BUILD_PATH:A}/Build/Products/Debug"
readonly SLOTS_ARTIFACTS="$SLOTS_DIR/artifacts-$(uuidgen)"
mkdir -p "$SLOTS_ARTIFACTS"
env DYLD_FRAMEWORK_PATH="$SLOTS_PRODUCTS" python3 - "$SLOTS_PRODUCTS/GuestSlotsHarness" "${SLOTS_ARTIFACTS:A}" <<'PY'
import subprocess,sys
try:raise SystemExit(subprocess.run(sys.argv[1:],timeout=45).returncode)
except subprocess.TimeoutExpired:
 print('FAIL: guest slot qualification exceeded its45s runtime bound',flush=True)
 raise SystemExit(1)
PY
