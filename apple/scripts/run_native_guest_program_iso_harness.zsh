#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly GUEST_PROGRAM_DIR="${STREAM_GUEST_PROGRAM_DIR:-build/native-guest-program-iso-validation}"
readonly GUEST_PROGRAM_BUILD_PATH="${STREAM_GUEST_PROGRAM_BUILD_PATH:-$GUEST_PROGRAM_DIR/derived}"
: ${STREAM_GUEST_RTC_INCLUDE:?Set public pinned libdatachannel0.24 include directory containing rtc/}
: ${STREAM_GUEST_RTC_LIBRARY:?Set repaired pinned libdatachannel0.24 static library path}
[[ -f ${STREAM_GUEST_RTC_INCLUDE}/rtc/version.h && -f ${STREAM_GUEST_RTC_LIBRARY} ]]
mkdir -p "$GUEST_PROGRAM_DIR"
python3 scripts/prepare_guest_receive_fixtures.py "$GUEST_PROGRAM_DIR/fixtures"
ruby -ryaml -rjson - "$GUEST_PROGRAM_DIR" <<'RUBY'
root=Dir.pwd
folder=ARGV[0]
spec=YAML.load_file('project.yml')
spec['name']='NativeGuestProgramISOValidation'
spec['packages'].each_value{|p| p['path']=File.join(root,p['path']) if p['path']}
if ENV['STREAM_VENDOR_ROOT']
  spec['packages'].each_value{|p| p['path']=File.join(ENV['STREAM_VENDOR_ROOT'],File.basename(p['path'])) if p['path']}
end
spec['targets'].select!{|name,_| ['StreamCore','StreamMac'].include?(name)}
spec['targets'].each_value{|t| t['dependencies']&.reject!{|d| d['target'] && !spec['targets'].key?(d['target'])}}
spec['schemes']={}
spec['targets'].each_value do |target|
  target['sources'].map!{|s| s.is_a?(String) ? File.join(root,s) : s.merge('path'=>File.join(root,s['path']))}
  target.delete('entitlements')
end
target=spec['targets'].delete('StreamMac')
target['type']='tool'
target.delete('info')
require File.join(root, 'scripts/guest_fixture_boundaries')
StreamGuestFixtureBoundaries.apply(spec['targets']['StreamCore'], target, root, folder)
target['sources'] << {'path'=>File.join(root,'NativeGuestReceivePrototype'),'excludes'=>['README.md']}
target['sources'] << File.join(root,'scripts/guest_receive_peer_fixture.cpp')
target['sources'] << File.join(root,'scripts/native_guest_program_iso_harness.swift')
settings=target['settings']['base']
settings['SWIFT_OBJC_BRIDGING_HEADER']=File.join(root,'scripts/guest_receive_peer_fixture.h')
settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='$(inherited) STREAM_NATIVE_VALIDATION'
settings['CLANG_CXX_LANGUAGE_STANDARD']='c++17'
settings['HEADER_SEARCH_PATHS']=['$(inherited)',ENV.fetch('STREAM_GUEST_RTC_INCLUDE')]
settings['OTHER_LDFLAGS']=['$(inherited)',ENV.fetch('STREAM_GUEST_RTC_LIBRARY'),'-lc++','-lz']
spec['targets']['NativeGuestProgramISOHarness']=target
spec['schemes']['NativeGuestProgramISOHarness']={'build'=>{'targets'=>{'NativeGuestProgramISOHarness'=>'all'}}}
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$GUEST_PROGRAM_DIR/project.json" --project "$GUEST_PROGRAM_DIR"
xcodebuild -resolvePackageDependencies -project "$GUEST_PROGRAM_DIR/NativeGuestProgramISOValidation.xcodeproj" \
  -scheme NativeGuestProgramISOHarness -derivedDataPath "$GUEST_PROGRAM_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$GUEST_PROGRAM_BUILD_PATH"
xcodebuild -project "$GUEST_PROGRAM_DIR/NativeGuestProgramISOValidation.xcodeproj" \
  -scheme NativeGuestProgramISOHarness -destination 'platform=macOS' \
  -derivedDataPath "$GUEST_PROGRAM_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build
env DYLD_FRAMEWORK_PATH="${GUEST_PROGRAM_BUILD_PATH:A}/Build/Products/Debug" \
  "${GUEST_PROGRAM_BUILD_PATH:A}/Build/Products/Debug/NativeGuestProgramISOHarness" \
  "$GUEST_PROGRAM_DIR/fixtures" "$GUEST_PROGRAM_DIR/media-$(uuidgen)" "$@"
