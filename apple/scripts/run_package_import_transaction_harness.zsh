#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly output="${PACKAGE_TRANSACTION_BUILD_PATH:-$PWD/build/package-import-transaction-validation}"
python3 scripts/generate_package_read_methods.py "$output/generated" --transaction
if [[ "${1:-}" == --generate-only ]]; then exit 0; fi
: "${PACKAGE_METHODS_CORE_PRODUCTS:?Set already-built StreamCore products directory}"
readonly products="${PACKAGE_METHODS_CORE_PRODUCTS:A}"
[[ -f "$products/StreamCore.framework/StreamCore" ]]
readonly sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -j2 -swift-version 6 -parse-as-library -sdk "$sdk" \
  -F "$products" -framework StreamCore -Xlinker -rpath -Xlinker "$products" \
  StreamMac/LayerGraph.swift StreamMac/LayerStyle.swift StreamMac/SourceEffects.swift \
  StreamMac/TextLayer.swift StreamMac/SecondaryCanvasLayout.swift \
  StreamMac/SceneMigration.swift StreamMac/SceneDocumentMigration.swift StreamMac/ShowPackage.swift \
  "$output/generated/WorkspacePackageMethods.swift" \
  "$output/generated/PackageDependencies.swift" "$output/generated/PackageReadHarness.swift" \
  -o "$output/PackageImportTransactionHarness"
python3 - "$output/PackageImportTransactionHarness" "$output" <<'PY'
import pathlib, subprocess, sys, uuid
folder = pathlib.Path(sys.argv[2]) / ('owned-transaction-' + str(uuid.uuid4()))
folder.mkdir(mode=0o700)
try:
    raise SystemExit(subprocess.run([sys.argv[1], str(folder)], timeout=45).returncode)
except subprocess.TimeoutExpired:
    print('FAIL: owned actual package import transactions exceeded 45 seconds', flush=True)
    raise SystemExit(1)
PY
