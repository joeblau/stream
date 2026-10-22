#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly DELIVERY_CONVERSION_BUILD="${STREAM_FRAME_DELIVERY_CONVERSION_BUILD:-$PWD/build/frame-delivery-conversion-validation}"
mkdir -p "$DELIVERY_CONVERSION_BUILD/module-cache"
export CLANG_MODULE_CACHE_PATH="$DELIVERY_CONVERSION_BUILD/module-cache"
typeset -a DELIVERY_CORE_FLAGS
if [[ -n "${STREAM_FRAME_DELIVERY_CORE_PRODUCTS:-}" ]]; then
  python3 - "$STREAM_FRAME_DELIVERY_CORE_PRODUCTS" <<'PY'
import hashlib,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); receipt=json.loads((p/'receipt.json').read_text())
actual={str(s):hashlib.sha256(s.read_bytes()).hexdigest() for s in pathlib.Path('StreamCore').glob('*.swift')}
assert actual==receipt['sourceSHA256'],'Immutable Core source receipt differs from current production sources'
assert hashlib.sha256((p/'StreamCore.framework/StreamCore').read_bytes()).hexdigest()==receipt['binarySHA256'],'Immutable Core binary receipt differs'
print('Verified immutable full production Core source and binary receipts')
PY
  readonly DELIVERY_CORE_COPY="$(mktemp -d "$DELIVERY_CONVERSION_BUILD/core-products.XXXXXX")"
  ditto "$STREAM_FRAME_DELIVERY_CORE_PRODUCTS/StreamCore.framework" "$DELIVERY_CORE_COPY/StreamCore.framework"
  DELIVERY_CORE_FLAGS=(-F "$DELIVERY_CORE_COPY" -framework StreamCore -Xlinker -rpath -Xlinker "$DELIVERY_CORE_COPY")
else
  xcrun swiftc -j2 -swift-version 6 -strict-concurrency=complete -parse-as-library \
    -module-cache-path "$DELIVERY_CONVERSION_BUILD/module-cache" \
    -emit-library -emit-module -module-name StreamCore StreamCore/*.swift \
    -emit-module-path "$DELIVERY_CONVERSION_BUILD/StreamCore.swiftmodule" \
    -o "$DELIVERY_CONVERSION_BUILD/libStreamCore.dylib"
  DELIVERY_CORE_FLAGS=(-I "$DELIVERY_CONVERSION_BUILD" -L "$DELIVERY_CONVERSION_BUILD" -lStreamCore -Xlinker -rpath -Xlinker "$DELIVERY_CONVERSION_BUILD")
fi
xcrun swiftc -j2 -swift-version 6 -strict-concurrency=complete -D STREAM_NATIVE_VALIDATION -parse-as-library \
  -module-cache-path "$DELIVERY_CONVERSION_BUILD/module-cache" \
  "${DELIVERY_CORE_FLAGS[@]}" \
  VirtualOutputShared/VirtualCameraContract.swift \
  StreamMac/RawVideoResourceCoordinator.swift StreamMac/FrameDeliveryBroker.swift \
  StreamMac/RecordingChatPaint.swift StreamMac/FrameDeliveryConverter.swift \
  StreamMac/ExternalDisplayOutputController.swift \
  StreamMac/VirtualCameraProducer.swift StreamMac/VirtualCameraOutputController.swift \
  scripts/frame_delivery_conversion_harness.swift \
  -o "$DELIVERY_CONVERSION_BUILD/harness"
"$DELIVERY_CONVERSION_BUILD/harness"
python3 - "$DELIVERY_CONVERSION_BUILD" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path.cwd()
build=pathlib.Path(sys.argv[1])
sources=['StreamCore/RawVideoResourceBudget.swift','StreamMac/RawVideoResourceCoordinator.swift',
 'StreamMac/FrameDeliveryBroker.swift','StreamMac/RecordingChatPaint.swift','StreamMac/FrameDeliveryConverter.swift',
 'StreamMac/VirtualCameraProducer.swift','StreamMac/VirtualCameraOutputController.swift','StreamMac/ExternalDisplayOutputController.swift',
 'VirtualOutputShared/VirtualCameraContract.swift','scripts/frame_delivery_conversion_harness.swift']
receipt={'sourceSHA256':{s:hashlib.sha256((root/s).read_bytes()).hexdigest() for s in sources},
 'harnessSHA256':hashlib.sha256((build/'harness').read_bytes()).hexdigest(),
 'installedCMIOExecuted':False,'captureExecuted':False,'networkExecuted':False,
 'actualPrivatePoolsAndBroker':True,'selectedCMIOEffectsInert':True}
(build/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('Owned receipt:',build/'receipt.json')
PY
