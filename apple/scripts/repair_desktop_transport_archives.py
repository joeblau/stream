#!/usr/bin/env python3
"""Rebuild missing macOS transport symbols in this build's package artifacts.

The pinned upstream fat archives contain OpenSSL on Intel but omit the SRT/
WebRTC implementation. Preserve working slices and rebuild the exact transport
versions with static dependencies. No vendor checkout or global cache is edited.
"""
import argparse
import json
import platform
from pathlib import Path
import subprocess
import tempfile


def run(*args, capture=False):
    return subprocess.run(args, check=True, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def has_symbol(path, arch, symbol):
    result = subprocess.run(["nm", "-arch", arch, "-g", str(path)],
                            capture_output=True, text=True)
    return result.returncode == 0 and any(
        line.strip().endswith(" T " + symbol) for line in result.stdout.splitlines())


def checkout(directory, repository, commit, recursive=False):
    if not directory.exists():
        run("git", "clone", "--filter=blob:none", "--no-checkout", repository, str(directory))
    run("git", "-C", str(directory), "checkout", "--detach", commit)
    actual = run("git", "-C", str(directory), "rev-parse", "HEAD", capture=True).strip()
    if actual != commit:
        raise RuntimeError("Transport source revision mismatch")
    if recursive:
        run("git", "-C", str(directory), "submodule", "update", "--init", "--recursive")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("derived_data", type=Path)
    parser.add_argument("--architecture", choices=["arm64", "x86_64"], default=platform.machine())
    parser.add_argument("--openssl-prefix", type=Path)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    root = args.derived_data.resolve()
    artifacts = root / "SourcePackages/artifacts/haishinkit.swift"
    specifications = [
        ("libsrt", "_srt_startup", "https://github.com/Haivision/srt.git",
         "a8c6b65520f814c5bd8f801be48c33ceece7c4a6", "1.5.4"),
        ("libdatachannel", "_rtcCreatePeerConnection", "https://github.com/paullouisageneau/libdatachannel.git",
         "8c31097ea78f051e857d0aa1b2f6efb26cd12b7e", "0.24.0"),
    ]
    paths = {name: artifacts / name / (name + ".xcframework") / "macos-arm64_x86_64" / (name + ".a")
             for name, *_ in specifications}
    for path in paths.values():
        if not path.is_file():
            raise RuntimeError(f"Resolve StreamMac packages in this derived-data directory first: {path}")
    needed = [spec for spec in specifications if args.force or not has_symbol(paths[spec[0]], args.architecture, spec[1])]
    if not needed:
        print(f"macOS {args.architecture} transport implementations are present.")
        return
    openssl = args.openssl_prefix or Path(run("brew", "--prefix", "openssl@3", capture=True).strip())
    crypto = openssl / "lib/libcrypto.a"
    ssl = openssl / "lib/libssl.a"
    for library in [crypto, ssl]:
        run("lipo", str(library), "-verify_arch", args.architecture)
    work = root / "TransportSourceBuild" / args.architecture
    work.mkdir(parents=True, exist_ok=True)
    receipt = {"architecture": args.architecture, "openssl": run(str(openssl / "bin/openssl"), "version", capture=True).strip(), "transports": []}
    for name, symbol, repository, commit, version in needed:
        source = work / (name + "-source")
        checkout(source, repository, commit, recursive=name == "libdatachannel")
        build = work / (name + "-build")
        common = ["-DCMAKE_POLICY_VERSION_MINIMUM=3.5", "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0",
                  "-DCMAKE_OSX_ARCHITECTURES=" + args.architecture,
                  "-DOPENSSL_ROOT_DIR=" + str(openssl), "-DOPENSSL_USE_STATIC_LIBS=ON"]
        options = (["-DENABLE_SHARED=OFF", "-DENABLE_STATIC=ON", "-DENABLE_APPS=OFF",
                    "-DENABLE_TESTING=OFF", "-DUSE_OPENSSL_PC=OFF"] if name == "libsrt" else
                   ["-DBUILD_SHARED_LIBS=OFF", "-DBUILD_SHARED_DEPS_LIBS=OFF", "-DNO_EXAMPLES=ON",
                    "-DNO_TESTS=ON", "-DUSE_SYSTEM_SRTP=OFF", "-DUSE_SYSTEM_JUICE=OFF",
                    "-DUSE_SYSTEM_USRSCTP=OFF"])
        run("cmake", "-S", str(source), "-B", str(build), *common, *options)
        run("cmake", "--build", str(build), "--parallel", "4")
        libraries = sorted(build.rglob("*.a"))
        if not libraries:
            raise RuntimeError("The source build produced no static libraries")
        thin = work / (name + "-complete.a")
        run("libtool", "-static", "-o", str(thin), *map(str, libraries), str(ssl), str(crypto))
        if not has_symbol(thin, args.architecture, symbol):
            raise RuntimeError("Built archive is missing its required transport entry point")
        original = paths[name]
        architectures = run("lipo", "-archs", str(original), capture=True).split()
        with tempfile.TemporaryDirectory(dir=original.parent) as temporary:
            folder = Path(temporary)
            slices = [thin]
            for arch in architectures:
                if arch == args.architecture:
                    continue
                retained = folder / (arch + ".a")
                run("lipo", str(original), "-thin", arch, "-output", str(retained))
                slices.append(retained)
            replacement = folder / "universal.a"
            run("lipo", "-create", *map(str, slices), "-output", str(replacement))
            for arch in architectures:
                run("lipo", str(replacement), "-verify_arch", arch)
            replacement.replace(original)
        if not has_symbol(original, args.architecture, symbol):
            raise RuntimeError("Installed archive lost its transport implementation")
        receipt["transports"].append({"name": name, "version": version, "repository": repository, "commit": commit})
    (work / "sources.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"Rebuilt and verified {len(needed)} static macOS {args.architecture} transport archives.")


if __name__ == "__main__":
    main()
