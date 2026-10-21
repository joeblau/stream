#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly MEDIA_DIR="${BROWSER_PDF_MEDIA_BUILD_PATH:-build/browser-widget-pdf-media-validation}"
mkdir -p "$MEDIA_DIR"
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=red:s=80x80:r=15:d=1 \
  -f lavfi -i color=c=blue:s=80x80:r=15:d=1 -filter_complex '[0:v][1:v]concat=n=2:v=1:a=0[v]' \
  -map '[v]' -c:v libx264 -pix_fmt yuv420p -movflags +faststart -y "$MEDIA_DIR/owned.mp4"
xcrun swiftc -swift-version 6 -parse-as-library -O StreamMac/BrowserWidgetRasterizer.swift \
  scripts/browser_widget_pdf_media_harness.swift -o "$MEDIA_DIR/BrowserWidgetPDFMediaHarness"
"$MEDIA_DIR/BrowserWidgetPDFMediaHarness" "${MEDIA_DIR:A}"
