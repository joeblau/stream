#!/bin/zsh
# Build an owned fixture executable. Never install or start a system service.
set -euo pipefail
: ${STREAM_INTERVIEW_TURN_BUILD_DIR:?Set an owned temporary build directory}
: ${STREAM_TURN_OPENSSL_ROOT:?Set an existing OpenSSL development prefix}
: ${STREAM_TURN_LIBEVENT_ROOT:?Set an existing libevent development prefix}
readonly TURN_SOURCE_PIN=23c6c1d32a3d2b21a56cee65d3203bcc4ea82d2b
readonly TURN_ROOT=${STREAM_INTERVIEW_TURN_BUILD_DIR:A}
readonly TURN_SOURCE=${TURN_ROOT}/source
readonly TURN_BUILD=${TURN_ROOT}/build
[[ ! -L ${TURN_ROOT} && ! -L ${TURN_SOURCE} && ! -L ${TURN_BUILD} ]]
mkdir -p "${TURN_ROOT}"
if [[ ! -d ${TURN_SOURCE}/.git ]]; then
  git clone --filter=blob:none --no-checkout https://github.com/coturn/coturn.git "${TURN_SOURCE}"
else
  [[ -z $(git -C "${TURN_SOURCE}" status --porcelain) ]] || { print -u2 'Owned Coturn source contains changes; preserve them and choose a fresh build directory.'; exit 1; }
fi
git -C "${TURN_SOURCE}" checkout --detach "${TURN_SOURCE_PIN}"
[[ $(git -C "${TURN_SOURCE}" rev-parse HEAD) == ${TURN_SOURCE_PIN} ]]
readonly TURN_SDK=$(xcrun --sdk macosx --show-sdk-path)
PKG_CONFIG_PATH="${STREAM_TURN_OPENSSL_ROOT}/lib/pkgconfig:${STREAM_TURN_LIBEVENT_ROOT}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}" \
cmake -S "${TURN_SOURCE}" -B "${TURN_BUILD}" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$(xcrun --find clang)" -DCMAKE_CXX_COMPILER="$(xcrun --find clang++)" \
  -DCMAKE_OSX_SYSROOT="${TURN_SDK}" -DBUILD_TESTING=OFF -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$(sw_vers -productVersion)" \
  -DWITH_MYSQL=OFF -DCMAKE_DISABLE_FIND_PACKAGE_PostgreSQL=TRUE \
  -DCMAKE_DISABLE_FIND_PACKAGE_mongoc-1.0=TRUE \
  -DOPENSSL_ROOT_DIR="${STREAM_TURN_OPENSSL_ROOT}" \
  -DCMAKE_PREFIX_PATH="${STREAM_TURN_OPENSSL_ROOT};${STREAM_TURN_LIBEVENT_ROOT}" \
  -DCMAKE_INSTALL_PREFIX="${TURN_ROOT}/unused-install"
cmake --build "${TURN_BUILD}" --target turnserver --parallel 4
[[ -x ${TURN_BUILD}/bin/turnserver ]]
python3 - "${TURN_ROOT}" "${TURN_SOURCE_PIN}" "${TURN_SDK}" <<'PY'
from pathlib import Path
import hashlib,json,platform,shutil,sys
root=Path(sys.argv[1]);binary=root/'build/bin/turnserver'
notices=root/'licenses';notices.mkdir(exist_ok=True)
for path in list((root/'source').glob('LICENSE*'))+list((root/'source').glob('COPYING*')):
 if path.is_file():shutil.copyfile(path,notices/path.name)
(root/'build-provenance.json').write_text(json.dumps({'repository':'https://github.com/coturn/coturn.git','sourceCommit':sys.argv[2],'architecture':platform.machine(),'sdk':sys.argv[3],'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest()},indent=2)+'\n')
print('Owned pinned Coturn fixture executable: '+str(binary))
PY
