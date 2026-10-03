#!/usr/bin/env python3
"""Rebuild missing macOS transport symbols in this build's package artifacts.

The pinned upstream fat archives contain OpenSSL on Intel but omit the SRT/
WebRTC implementation. Preserve working slices and rebuild the exact transport
versions with static dependencies. No vendor checkout or global cache is edited.
"""
import argparse
import hashlib
import json
import platform
import shutil
from pathlib import Path
import subprocess
import tempfile

RELAY_SOURCE = "8c31097ea78f051e857d0aa1b2f6efb26cd12b7e"
RELAY_JUICE_SOURCE = "5948a4162d37bc213d6051b67ee2876ccc5a99a6"
RELAY_MARKER = "_stream_rtc_relay_policy_20261002_v1"
RELAY_PATCH = Path(__file__).parent / "patches/libdatachannel-0.24-relay-policy.patch"


def slice_digest(path, arch):
    with tempfile.TemporaryDirectory() as temporary:
        thin = Path(temporary) / "slice.a"
        architectures = run("lipo", "-archs", str(path), capture=True).split()
        if architectures == [arch]:
            shutil.copyfile(path, thin)
        else:
            run("lipo", str(path), "-thin", arch, "-output", str(thin))
        return hashlib.sha256(thin.read_bytes()).hexdigest()


def relay_receipt(path, arch):
    return path.with_name(path.name + ".stream-relay-policy-" + arch + ".json")


def has_relay_policy(path, arch):
    if not RELAY_PATCH.is_file() or not has_symbol(path, arch, RELAY_MARKER):
        return False
    try:
        receipt = json.loads(relay_receipt(path, arch).read_text())
        return (receipt.get("sourceCommit") == RELAY_SOURCE
                and receipt.get("juiceCommit") == RELAY_JUICE_SOURCE
                and receipt.get("patchSHA256") == hashlib.sha256(RELAY_PATCH.read_bytes()).hexdigest()
                and receipt.get("archiveSliceSHA256") == slice_digest(path, arch))
    except (OSError, ValueError, subprocess.CalledProcessError):
        return False


def apply_relay_policy(source):
    juice = source / "deps/libjuice"
    if run("git", "-C", str(juice), "rev-parse", "HEAD", capture=True).strip() != RELAY_JUICE_SOURCE:
        raise RuntimeError("Pinned libjuice source revision mismatch")
    patch = RELAY_PATCH.resolve()
    if subprocess.run(["git", "-C", str(source), "apply", "--reverse", "--check", str(patch)],
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
        run("git", "-C", str(source), "apply", "--check", str(patch))
        run("git", "-C", str(source), "apply", str(patch))
    actual = run("git", "-C", str(source), "diff", "--ignore-submodules=all", capture=True)
    actual += run("git", "-C", str(juice), "diff", "--src-prefix=a/deps/libjuice/",
                  "--dst-prefix=b/deps/libjuice/", capture=True)
    if actual.encode() != patch.read_bytes():
        raise RuntimeError("Owned relay source differs from the exact reviewed patch")


def run(*args, capture=False, cwd=None):
    return subprocess.run(args, check=True, text=True, cwd=cwd,
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
    parser.add_argument("--require-relay-policy", action="store_true",
                        help="Require the owned pinned-source ICE relay implementation and verified build receipt")
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
    needed = [spec for spec in specifications if args.force or not has_symbol(paths[spec[0]], args.architecture, spec[1])
              or (args.require_relay_policy and spec[0] == "libdatachannel"
                  and not has_relay_policy(paths[spec[0]], args.architecture))]
    if not needed:
        print(f"macOS {args.architecture} transport implementations are present.")
        return
    work = root / "TransportSourceBuild" / args.architecture
    work.mkdir(parents=True, exist_ok=True)
    sdk = run("xcrun", "--sdk", "macosx", "--show-sdk-path", capture=True).strip()
    # Homebrew static archives can require the build host's macOS version.
    # Build crypto at the app's deployment floor instead of raising that floor.
    openssl_commit = "c8bd5a57108599ac650bbae77fcabe3109dab2e8"
    openssl = args.openssl_prefix
    if openssl is None:
        openssl = work / "openssl-install"
        source = work / "openssl-source"
        checkout(source, "https://github.com/openssl/openssl.git", openssl_commit)
        build = work / "openssl-build"
        build.mkdir(exist_ok=True)
        target = "darwin64-arm64-cc" if args.architecture == "arm64" else "darwin64-x86_64-cc"
        run("perl", str(source / "Configure"), target, "no-shared", "no-tests",
            "--prefix=" + str(openssl), "-mmacosx-version-min=14.0", cwd=build)
        run("make", "-j4", cwd=build)
        run("make", "install_sw", cwd=build)
    crypto = openssl / "lib/libcrypto.a"
    ssl = openssl / "lib/libssl.a"
    for library in [crypto, ssl]:
        run("lipo", str(library), "-verify_arch", args.architecture)
    receipt = {"architecture": args.architecture, "openssl": run(str(openssl / "bin/openssl"), "version", capture=True).strip(), "opensslSourceCommit": openssl_commit if args.openssl_prefix is None else None, "deploymentTarget": "14.0", "transports": []}
    for name, symbol, repository, commit, version in needed:
        source = work / (name + "-source")
        checkout(source, repository, commit, recursive=name == "libdatachannel")
        relay = args.require_relay_policy and name == "libdatachannel"
        if relay:
            apply_relay_policy(source)
        build = work / (name + "-build")
        common = ["-DCMAKE_POLICY_VERSION_MINIMUM=3.5", "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0",
                  "-DCMAKE_OSX_ARCHITECTURES=" + args.architecture,
                  "-DCMAKE_OSX_SYSROOT=" + sdk,
                  "-DCMAKE_C_COMPILER=" + run("xcrun", "--find", "clang", capture=True).strip(),
                  "-DCMAKE_CXX_COMPILER=" + run("xcrun", "--find", "clang++", capture=True).strip(),
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
        if relay and not has_symbol(thin, args.architecture, RELAY_MARKER):
            raise RuntimeError("Built archive is missing the actual relay implementation marker")
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
        if relay:
            relay_proof = {"sourceCommit": RELAY_SOURCE, "juiceCommit": RELAY_JUICE_SOURCE,
                           "patchSHA256": hashlib.sha256(RELAY_PATCH.read_bytes()).hexdigest(),
                           "archiveSliceSHA256": slice_digest(original, args.architecture),
                           "marker": RELAY_MARKER, "architecture": args.architecture}
            # Execute the compiled marker and actual public setter against this
            # archive; no provider, credentials or TURN service is involved.
            policy_smoke = work / "RelayPolicySmoke.cpp"
            policy_smoke.write_text("""#include <juice/juice.h>
extern "C" int stream_rtc_relay_policy_20261002_v1();
int main() {
    if (stream_rtc_relay_policy_20261002_v1() != 1) return 1;
    juice_config_t config{}; config.bind_address = "127.0.0.1";
    juice_agent_t *agent = juice_create(&config);
    if (!agent) return 2;
    int result = juice_set_relay_only(agent, true);
    if (result == JUICE_ERR_SUCCESS) result = juice_gather_candidates(agent);
    if (result == JUICE_ERR_SUCCESS && juice_set_relay_only(agent, false) != JUICE_ERR_FAILED) result = -9;
    juice_destroy(agent);
    return result == JUICE_ERR_SUCCESS ? 0 : 3;
}
""")
            policy_executable = work / "relay-policy-smoke"
            run("xcrun", "clang++", "-std=c++17", "-arch", args.architecture,
                "-mmacosx-version-min=14.0", "-isysroot", sdk, "-I" + str(source / "deps/libjuice/include"),
                str(policy_smoke), str(original), "-framework", "Security", "-framework", "CoreFoundation",
                "-lz", "-o", str(policy_executable))
            if args.architecture == platform.machine():
                run(str(policy_executable))
            run("xcrun", "clang++", "-std=c++17", "-arch", args.architecture,
                "-mmacosx-version-min=14.0", "-isysroot", sdk, "-I" + str(source / "deps/libjuice/include"),
                str(Path(__file__).parent / "relay_policy_tcp_harness.cpp"), str(original),
                "-framework", "Security", "-framework", "CoreFoundation", "-lz", "-o",
                str(work / "relay-policy-tcp-harness"))
            relay_receipt(original, args.architecture).write_text(json.dumps(relay_proof, indent=2) + "\n")
            if not has_relay_policy(original, args.architecture):
                raise RuntimeError("Installed relay archive failed exact implementation/receipt verification")
        receipt["transports"].append({"name": name, "version": version, "repository": repository, "commit": commit})
    smoke = work / "TransportSmoke.cpp"
    smoke.write_text("""#include <srt.h>
#include <rtc/rtc.h>
int main() {
    if (srt_startup() != 0) return 1;
    SRTSOCKET socket = srt_create_socket();
    if (socket == SRT_INVALID_SOCK) return 2;
    srt_close(socket); srt_cleanup();
    rtcConfiguration configuration{};
    int connection = rtcCreatePeerConnection(&configuration);
    if (connection < 0) return 3;
    rtcDeletePeerConnection(connection); rtcCleanup();
    return 0;
}
""")
    executable = work / "transport-smoke"
    # Both sources are available when repairing the pinned Intel distribution.
    # A forced rebuild also exercises this path on native Apple Silicon.
    if len(needed) == 2:
        includes = [work / "libsrt-source/srtcore", work / "libsrt-source/common",
                    work / "libsrt-build", work / "libdatachannel-source/include"]
        run("xcrun", "clang++", "-std=c++17", "-arch", args.architecture,
            "-mmacosx-version-min=14.0", "-isysroot", sdk, *["-I" + str(path) for path in includes],
            str(smoke), *map(str, paths.values()), "-framework", "Security",
            "-framework", "CoreFoundation", "-lz", "-o", str(executable))
        if args.architecture == platform.machine():
            run(str(executable))
    notices = work / "licenses"
    notices.mkdir(exist_ok=True)
    for source in work.glob("*-source"):
        for license in list(source.glob("LICENSE*")) + list(source.glob("deps/*/LICENSE*")):
            if license.is_file():
                name = source.name + "-" + str(license.relative_to(source)).replace("/", "-")
                shutil.copyfile(license, notices / name)
    (work / "sources.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"Rebuilt and verified {len(needed)} static macOS {args.architecture} transport archives.")


if __name__ == "__main__":
    main()
