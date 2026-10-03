#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly BROWSER_DIR="build/browser-lifecycle-validation"
mkdir -p "$BROWSER_DIR"
ruby -ryaml -rjson - "$BROWSER_DIR" <<'RUBY'
root=Dir.pwd
folder=ARGV[0]
spec=YAML.load_file('project.yml')
spec['name']='BrowserLifecycleValidation'
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
h=spec['targets'].delete('StreamMac')
h['type']='tool'
h['settings'] ||= {}; h['settings']['base'] ||= {}
h['settings']['base']['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='$(inherited) STREAM_NATIVE_VALIDATION'
h['sources'][0]={'path'=>File.join(root,'StreamMac'),'excludes'=>['StreamMacApp.swift']}
h['sources'] << File.join(root,'scripts/browser_lifecycle_harness.swift')
spec['targets']['BrowserLifecycleHarness']=h
spec['schemes']['BrowserLifecycleHarness']={'build'=>{'targets'=>{'BrowserLifecycleHarness'=>'all'}}}
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$BROWSER_DIR/project.json" --project "$BROWSER_DIR"
xcodebuild -resolvePackageDependencies -project "$BROWSER_DIR/BrowserLifecycleValidation.xcodeproj" \
    -scheme BrowserLifecycleHarness -derivedDataPath "$BROWSER_DIR/derived"
python3 scripts/repair_desktop_transport_archives.py "$BROWSER_DIR/derived"
xcodebuild -project "$BROWSER_DIR/BrowserLifecycleValidation.xcodeproj" \
    -scheme BrowserLifecycleHarness -destination 'platform=macOS' \
    -derivedDataPath "$BROWSER_DIR/derived" CODE_SIGNING_ALLOWED=NO build
env DYLD_FRAMEWORK_PATH="$PWD/$BROWSER_DIR/derived/Build/Products/Debug" \
    "$BROWSER_DIR/derived/Build/Products/Debug/BrowserLifecycleHarness" "$PWD/StreamMac/BrowserFixtures/audio-widget.html"
