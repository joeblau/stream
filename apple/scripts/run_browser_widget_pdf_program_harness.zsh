#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly PDF_DIR="${BROWSER_PDF_PROGRAM_BUILD_PATH:-build/browser-widget-pdf-program-validation}"
readonly PDF_DERIVED="${BROWSER_PDF_PROGRAM_DERIVED:-$PDF_DIR/derived}"
mkdir -p "$PDF_DIR"
ruby -ryaml -rjson - "$PDF_DIR" <<'RUBY'
root=Dir.pwd; folder=File.expand_path(ARGV[0]); spec=YAML.load_file('project.yml')
spec['name']='BrowserWidgetPDFProgramValidation'
spec['packages'].each_value { |package| package['path']=ENV['STREAM_VENDOR_ROOT'] ? File.join(ENV['STREAM_VENDOR_ROOT'],File.basename(package['path'])) : File.join(root,package['path']) if package['path'] }
spec['targets'].select! { |name,_| ['StreamCore','StreamMac'].include?(name) }; spec['schemes']={}
spec['targets'].each_value do |target|
  target['dependencies']&.reject! { |d| d['target'] && !spec['targets'].key?(d['target']) }
  target['sources'].map! { |s| s.is_a?(String) ? File.join(root,s) : s.merge('path'=>File.join(root,s['path'])) }
  target.delete('entitlements'); target.delete('info')
end
target=spec['targets'].delete('StreamMac'); target['type']='tool'
require File.join(root,'scripts/guest_fixture_boundaries')
StreamGuestFixtureBoundaries.apply(spec['targets']['StreamCore'],target,root,folder)
target['sources'] << File.join(root,'scripts/browser_widget_pdf_program_harness.swift')
spec['targets']['BrowserWidgetPDFProgramHarness']=target
spec['schemes']['BrowserWidgetPDFProgramHarness']={'build'=>{'targets'=>{'BrowserWidgetPDFProgramHarness'=>'all'}}}
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$PDF_DIR/project.json" --project "$PDF_DIR"
xcodebuild -resolvePackageDependencies -project "$PDF_DIR/BrowserWidgetPDFProgramValidation.xcodeproj" -scheme BrowserWidgetPDFProgramHarness -derivedDataPath "$PDF_DERIVED"
python3 scripts/repair_desktop_transport_archives.py "$PDF_DERIVED" --require-relay-policy
xcodebuild -project "$PDF_DIR/BrowserWidgetPDFProgramValidation.xcodeproj" -scheme BrowserWidgetPDFProgramHarness -destination 'platform=macOS' -jobs 4 -derivedDataPath "$PDF_DERIVED" CODE_SIGNING_ALLOWED=NO build
zsh scripts/build_browser_audio_helper.zsh
readonly PDF_PRODUCTS="${PDF_DERIVED:A}/Build/Products/Debug"
env DYLD_FRAMEWORK_PATH="$PDF_PRODUCTS" "$PDF_PRODUCTS/BrowserWidgetPDFProgramHarness" "${PDF_DIR:A}"
