#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly PDF_DIR="${BROWSER_PDF_BUILD_PATH:-build/browser-widget-pdf-validation}"
mkdir -p "$PDF_DIR"
xcrun swiftc -target "$(uname -m)-apple-macos14.0" -swift-version 6 -parse-as-library -DSTREAM_NATIVE_VALIDATION -O \
  StreamMac/BrowserWidgetRasterizer.swift scripts/browser_widget_pdf_raster_harness.swift -o "$PDF_DIR/BrowserWidgetPDFRasterHarness"
"$PDF_DIR/BrowserWidgetPDFRasterHarness"
