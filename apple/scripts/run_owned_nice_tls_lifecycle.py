#!/usr/bin/env python3
"""Exercise the real owned libnice callback with an inaccessible retired identity."""
import argparse
import json
from pathlib import Path
import subprocess

from build_owned_nice_transport import archive_floor, digest, run

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--backend-build-dir", type=Path, required=True)
parser.add_argument("--output-dir", type=Path, required=True)
args = parser.parse_args()
root, output = args.backend_build_dir.resolve(), args.output_dir.resolve()
receipt = json.loads((root / "nice-transport-build.json").read_text())
archive = root / "libdatachannel-nice-complete.a"
if not receipt.get("ownedTLSImplementation") or digest(archive) != receipt["archiveSHA256"]:
    raise RuntimeError("Expected the exact recorded optional TLS backend")
prefix = next(Path(entry["path"]).parent.parent for entry in receipt["dependencies"] if entry["path"].endswith("/libglib-2.0.a"))
output.mkdir(parents=True, exist_ok=True)
binary, object_ = output / "tls-lifecycle", output / "tls-lifecycle.o"
sdk = run("xcrun", "--sdk", "macosx", "--show-sdk-path", capture=True).strip()
common = ["-arch", receipt["architecture"], "-mmacosx-version-min=" + receipt["requestedDeploymentTarget"], "-isysroot", sdk]
includes = [root / "libnice-source", root / "libnice-source/agent", root / "libnice-source/socket", root / "libnice-source/random", root / "libnice-build",
            root / "libnice-build/nice", prefix / "include/glib-2.0", prefix / "lib/glib-2.0/include"]
run("xcrun", "clang", *common, *["-I" + str(path) for path in includes], "-c", Path(__file__).with_name("owned_nice_tls_lifecycle.c"), "-o", object_)
run("xcrun", "clang++", *common, object_, archive, "-framework", "Security", "-framework", "CoreFoundation", *receipt["additionalSystemLinkFlags"], "-o", binary)
result = subprocess.run([str(binary)], check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10).stdout.strip()
proof = {"architecture": receipt["architecture"], "backendSHA256": digest(archive), "binarySHA256": digest(binary),
         "binaryMinOS": archive_floor(binary, receipt["architecture"]), "result": result,
         "scope": "deterministic inaccessible retired identity; not a general upstream race or sanitizer qualification"}
(output / "lifecycle-result.json").write_text(json.dumps(proof, indent=2) + "\n")
print(json.dumps(proof))
