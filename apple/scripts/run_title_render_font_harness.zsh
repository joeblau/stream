#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly FONT_RENDER_DIR="${TITLE_RENDER_FONT_DIR:-build/title-render-font-validation}"
readonly FONT_RENDER_BUILD_PATH="${TITLE_RENDER_FONT_BUILD_PATH:-$FONT_RENDER_DIR/derived}"
mkdir -p "$FONT_RENDER_DIR"
# Pin the measured original renderer, changing only its class name. The shared
# SceneBlend type comes from the current production source. No baseline font
# implementation or raster result is synthesized by this fixture.
python3 - "$FONT_RENDER_DIR" <<'PY'
import pathlib,subprocess,sys
source=subprocess.check_output(['git','show','44c078e2c7434ab416c1a6c56e256bd34059ffb7:apple/StreamMac/SceneRenderer.swift'],text=True)
header=source[:source.index('/// Composites')]
body=source[source.index('final class SceneRenderer'):].replace('final class SceneRenderer','final class BaselineSceneRenderer',1)
(pathlib.Path(sys.argv[1])/'BaselineSceneRenderer.swift').write_text(header+body)
cache=pathlib.Path('StreamMac/TitleRenderFontCache.swift').read_text()
needle='        let font = makeFont(requested, size)'
assert cache.count(needle)==1
cache=cache.replace(needle,needle+'\n        TitleFontEpochFixture.shared.fontBuilt()')
(pathlib.Path(sys.argv[1])/'TitleRenderFontCache.swift').write_text(cache)
PY
ruby -ryaml -rjson - "$FONT_RENDER_DIR" <<'RUBY'
root=Dir.pwd
folder=ARGV[0]
spec=YAML.load_file('project.yml')
spec['name']='TitleRenderFontValidation'
spec['packages'].each_value{|p| p['path']=File.join(ENV.fetch('STREAM_VENDOR_ROOT',File.join(root,'Vendor')),File.basename(p['path'])) if p['path']}
spec['targets'].select!{|name,_| ['StreamCore','StreamMac'].include?(name)}
spec['targets'].each_value{|t|t['dependencies']&.reject!{|d|d['target']&&!spec['targets'].key?(d['target'])}}
spec['schemes']={}
spec['targets'].each_value do |target|
  target['sources'].map!{|s|s.is_a?(String) ? File.join(root,s) : s.merge('path'=>File.join(root,s['path']))}
  target.delete('entitlements')
end
h=spec['targets'].delete('StreamMac')
h['type']='tool'
h['sources'][0]={'path'=>File.join(root,'StreamMac'),'excludes'=>['StreamMacApp.swift','TitleRenderFontCache.swift']}
h['sources'] << File.join(root,'scripts/title_render_font_harness.swift')
h['sources'] << File.join(root,folder,'BaselineSceneRenderer.swift')
h['sources'] << File.join(root,folder,'TitleRenderFontCache.swift')
spec['targets']['TitleRenderFontHarness']=h
spec['schemes']['TitleRenderFontHarness']={'build'=>{'targets'=>{'TitleRenderFontHarness'=>'all'}}}
require File.join(root,'scripts/desktop_transport_fixture')
StreamDesktopTransportFixture.apply(h,root)
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$FONT_RENDER_DIR/project.json" --project "$FONT_RENDER_DIR"
xcodebuild -jobs 2 -resolvePackageDependencies -project "$FONT_RENDER_DIR/TitleRenderFontValidation.xcodeproj" \
    -scheme TitleRenderFontHarness -derivedDataPath "$FONT_RENDER_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$FONT_RENDER_BUILD_PATH"
xcodebuild -jobs 2 -project "$FONT_RENDER_DIR/TitleRenderFontValidation.xcodeproj" \
    -scheme TitleRenderFontHarness -destination 'platform=macOS' -derivedDataPath "$FONT_RENDER_BUILD_PATH" \
    CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -j2' build
if [[ "${1:-}" == "--build-only" ]]; then exit 0; fi
env DYLD_FRAMEWORK_PATH="${FONT_RENDER_BUILD_PATH:A}/Build/Products/Debug" \
    "$FONT_RENDER_BUILD_PATH/Build/Products/Debug/TitleRenderFontHarness" \
    "${FONT_RENDER_DIR:A}/frames" "$PWD/scripts/fixtures/title-font-cache"
