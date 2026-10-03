#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly MANAGED_START_BUILD_PATH="${MANAGED_START_BUILD_PATH:-build/managed-start-validation}"
mkdir -p "$MANAGED_START_BUILD_PATH/project"
ruby -ryaml -rjson - <<'RUBY' "$MANAGED_START_BUILD_PATH/project"
root=Dir.pwd
folder=File.expand_path(ARGV.fetch(0))
spec=YAML.load_file('project.yml')
spec['packages']={}
spec['targets'].select!{|name,_| ['StreamCore','StreamCoreTests'].include?(name)}
spec['targets'].each_value{|t| t['sources']=t['sources'].map{|s| s.is_a?(String) ? File.join(root,s) : s.merge('path'=>File.join(root,s['path']))}}
spec['schemes'].select!{|name,_| name=='StreamCoreTests'}
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$MANAGED_START_BUILD_PATH/project/project.json" --project "$MANAGED_START_BUILD_PATH/project"
xcodebuild -project "$MANAGED_START_BUILD_PATH/project/Stream.xcodeproj" -scheme StreamCoreTests \
    -destination 'platform=macOS' -derivedDataPath "$MANAGED_START_BUILD_PATH/derived" CODE_SIGNING_ALLOWED=NO \
    test -only-testing:StreamCoreTests/YouTubeStartReviewTests > "$MANAGED_START_BUILD_PATH.log" 2>&1
readonly MANAGED_START_PRODUCTS="$MANAGED_START_BUILD_PATH/derived/Build/Products/Debug"
xcrun swiftc -swift-version 6 -parse-as-library -F "$MANAGED_START_PRODUCTS" -framework StreamCore \
    -Xlinker -rpath -Xlinker "${MANAGED_START_PRODUCTS:A}" \
    StreamMac/ManagedYouTubeStartCoordinator.swift StreamMac/ManagedYouTubeStartReviewView.swift scripts/managed_start_harness.swift \
    -o "$MANAGED_START_BUILD_PATH/managed-start-harness"
"$MANAGED_START_BUILD_PATH/managed-start-harness"
