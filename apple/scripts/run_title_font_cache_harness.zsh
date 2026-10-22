#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly FONT_CACHE_DIR="${TITLE_FONT_CACHE_DIR:-build/title-font-cache-validation}"
mkdir -p "$FONT_CACHE_DIR"
# TextLayout is the production shared Core Text implementation; this focused
# probe needs no app/device graph, GPU, microphone, camera or font installation.
xcrun swiftc -j2 -parse-as-library -emit-module -emit-library -module-name StreamCore \
    StreamCore/TextLayout.swift -emit-module-path "$FONT_CACHE_DIR/StreamCore.swiftmodule" \
    -o "$FONT_CACHE_DIR/libStreamCore.dylib"
xcrun swiftc -j2 -parse-as-library -I "$FONT_CACHE_DIR" -L "$FONT_CACHE_DIR" -lStreamCore \
    StreamMac/TitleRenderFontCache.swift scripts/title_font_cache_harness.swift \
    -o "$FONT_CACHE_DIR/title-font-cache-harness"
env DYLD_LIBRARY_PATH="${FONT_CACHE_DIR:A}" "$FONT_CACHE_DIR/title-font-cache-harness" \
    scripts/fixtures/title-font-cache/owned-a.ttf scripts/fixtures/title-font-cache/owned-b.ttf
