#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
GUEST_DIR="build/guest-renderer-validation"
GUEST_RENDERER_BUILD_PATH=${GUEST_RENDERER_BUILD_PATH:-${GUEST_DIR}/derived}
mkdir -p "${GUEST_DIR}"
ruby -ryaml -rjson - "${GUEST_DIR}" <<'RUBY'
root = Dir.pwd
folder = File.expand_path(ARGV[0])
spec = YAML.load_file('project.yml')
spec['name'] = 'GuestRendererValidation'
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
target['sources'][0] = { 'path' => File.join(root, 'StreamMac'), 'excludes' => ['StreamMacApp.swift'] }
target['sources'] << File.join(root, 'scripts/guest_renderer_harness.swift')
spec['targets']['GuestRendererHarness'] = target
spec['schemes']['GuestRendererHarness'] = { 'build' => { 'targets' => { 'GuestRendererHarness' => 'all' } } }
File.write(File.join(folder, 'project.json'), JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "${GUEST_DIR}/project.json" --project "${GUEST_DIR}"
xcodebuild -resolvePackageDependencies -project "${GUEST_DIR}/GuestRendererValidation.xcodeproj" \
  -scheme GuestRendererHarness -derivedDataPath "${GUEST_RENDERER_BUILD_PATH}"
python3 scripts/repair_desktop_transport_archives.py "${GUEST_RENDERER_BUILD_PATH}"
xcodebuild -project "${GUEST_DIR}/GuestRendererValidation.xcodeproj" -scheme GuestRendererHarness \
  -destination 'platform=macOS' -derivedDataPath "${GUEST_RENDERER_BUILD_PATH}" CODE_SIGNING_ALLOWED=NO build
GUEST_PRODUCTS="${GUEST_RENDERER_BUILD_PATH:A}/Build/Products/Debug"
env DYLD_FRAMEWORK_PATH="${GUEST_PRODUCTS}" "${GUEST_PRODUCTS}/GuestRendererHarness"
