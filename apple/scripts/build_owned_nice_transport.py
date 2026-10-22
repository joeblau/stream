#!/usr/bin/env python3
"""Build an opt-in pinned libnice ICE backend without modifying vendor or SDK caches.

This is a separate, current-host qualification artifact. The caller supplies
existing GLib/OpenSSL installations and a deployment target compatible with
those archives. It does not replace the default UDP-only SDK or certify an
older runtime. All sources, notices, dependency hashes and link flags remain
in the owned build directory. At most two compiler jobs run.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess

SDK_PIN = "8c31097ea78f051e857d0aa1b2f6efb26cd12b7e"
NICE_PIN = "ae3eb16fd7d1237353bf64e899c612b8a63bca8a"
OPENSSL_PIN = "c8bd5a57108599ac650bbae77fcabe3109dab2e8"
PATCHED_ICE_SHA256 = "f21c77a844a340dd1ef128b0cb7d996fbcec3403f41d614df65dbc920c403e1d"
PATCH = Path(__file__).resolve().parent / "patches/libdatachannel-0.24-nice-relay-policy.patch"


def run(*args, env=None, capture=False):
    return subprocess.run(list(map(str, args)), env=env, check=True, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def archive_payload_digest(path):
    data = path.read_bytes()
    if data[:8] != b"!<arch>\n":
        raise RuntimeError("Expected a thin static archive for member digest")
    offset, members = 8, []
    while offset < len(data):
        header = data[offset:offset + 60]
        if len(header) != 60 or header[58:60] != b"`\n":
            raise RuntimeError("Invalid static archive member header")
        size = int(header[48:58].strip())
        body = data[offset + 60:offset + 60 + size]
        if len(body) != size:
            raise RuntimeError("Truncated static archive member")
        members.append([header[:16].decode("ascii").rstrip(), size, hashlib.sha256(body).hexdigest()])
        offset += 60 + size + size % 2
    return hashlib.sha256(json.dumps(members, separators=(",", ":")).encode()).hexdigest()


def version(value):
    if not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
        raise ValueError("Use a numeric macOS deployment target")
    return tuple(map(int, value.split("."))) + (0,) * (3 - len(value.split(".")))


def archive_floor(path, architecture=None):
    headers = run("otool", "-arch", architecture or platform.machine(), "-l", path, capture=True)
    values = re.findall(r"\bminos\s+(\d+(?:\.\d+){0,2})", headers)
    values += re.findall(r"cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version (\d+(?:\.\d+){0,2})", headers)
    if not values:
        raise RuntimeError(f"Cannot establish dependency runtime floor: {path.name}")
    return max(values, key=version)


def macos_machine_file(path, architecture, target, sdk, prefix):
    compiler = ["/usr/bin/xcrun", "--sdk", "macosx", "clang", "-arch", architecture]
    arguments = ["-mmacosx-version-min=" + target, "-isysroot", str(sdk), "-I" + str(prefix / "include"),
                 "-Werror=unguarded-availability-new"]
    links = ["-mmacosx-version-min=" + target, "-L" + str(prefix / "lib")]
    value = "[binaries]\n" + "\n".join(key + " = " + repr(compiler) for key in ["c", "objc"])
    value += "\npkg-config = " + repr(shutil.which("pkg-config") or "pkg-config")
    value += "\ncpp = " + repr(compiler[:3] + ["clang++", "-arch", architecture])
    value += "\n[built-in options]\n" + "\n".join(key + " = " + repr(arguments) for key in ["c_args", "objc_args", "cpp_args"])
    value += "\n" + "\n".join(key + " = " + repr(links) for key in ["c_link_args", "objc_link_args", "cpp_link_args"])
    if architecture != platform.machine():
        value += "\n[host_machine]\nsystem = 'darwin'\ncpu_family = '" + ("aarch64" if architecture == "arm64" else "x86_64") + "'\ncpu = '" + architecture + "'\nendian = 'little'\n[properties]\nneeds_exe_wrapper = true\n"
    path.write_text(value + "\n")
    return "--native-file" if architecture == platform.machine() else "--cross-file"


def verify_owned_dependencies(prefix, architecture, target):
    receipt = json.loads((prefix / "owned-dependencies.json").read_text())
    if receipt["architecture"] != architecture or version(receipt["target"]) > version(target):
        raise RuntimeError("Owned GLib receipt architecture or runtime floor differs from requested backend")
    for entry in receipt["archives"]:
        artifact = Path(entry["path"]).resolve()
        if not artifact.is_relative_to(prefix.resolve()) or digest(artifact) != entry["sha256"]:
            raise RuntimeError("Owned GLib artifact differs from its source-build receipt; preserved without building")
    return receipt


def checkout(root, name, url, pin, recursive=False):
    source = root / name
    if not source.exists():
        run("git", "clone", "--filter=blob:none", "--no-checkout", url, source)
        run("git", "-C", source, "checkout", "--detach", pin)
        if recursive:
            run("git", "-C", source, "submodule", "update", "--init", "--recursive", "--jobs", "2")
    if run("git", "-C", source, "rev-parse", "HEAD", capture=True).strip() != pin:
        raise RuntimeError(f"Unexpected source revision: {name}")
    changed = run("git", "-C", source, "diff", "HEAD", "--name-only", capture=True).splitlines()
    allowed = {"libdatachannel-source": ["src/impl/icetransport.cpp"], "glib-source": ["meson.build"]}.get(name, [])
    if changed not in ([], allowed):
        raise RuntimeError(f"Unrelated source changes preserved; choose another build directory: {name}")
    if recursive:
        status = run("git", "-C", source, "submodule", "status", "--recursive", capture=True)
        if any(not line.startswith(" ") for line in status.splitlines()):
            raise RuntimeError("SDK submodule revision differs from its pinned source")
        clean = subprocess.run(["git", "-C", str(source), "submodule", "foreach", "--quiet", "--recursive",
                                "git diff HEAD --quiet --exit-code"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if clean.returncode != 0:
            raise RuntimeError("SDK submodule has staged or unstaged tracked changes; preserved without building")
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", required=True, type=Path)
    parser.add_argument("--openssl-prefix", required=True, type=Path)
    parser.add_argument("--glib-prefix", required=True, type=Path)
    parser.add_argument("--tools-prefix", required=True, type=Path, help="Existing directory with bin/meson and bin/ninja")
    parser.add_argument("--deployment-target", required=True, help="Must cover every supplied dependency archive's actual runtime floor")
    parser.add_argument("--architecture", choices=["arm64", "x86_64"], default=platform.machine())
    parser.add_argument("--openssl-source", type=Path, help="Clean pinned OpenSSL source for corresponding-source material")
    parser.add_argument("--source-bundle", action="store_true", help="Retain corresponding source, recipes and notices; requires owned GLib and OpenSSL source")
    args = parser.parse_args()
    requested_floor = version(args.deployment_target)
    root = args.build_dir.resolve()
    root.mkdir(parents=True, exist_ok=True)
    sdk = checkout(root, "libdatachannel-source", "https://github.com/paullouisageneau/libdatachannel.git", SDK_PIN, True)
    nice = checkout(root, "libnice-source", "https://github.com/libnice/libnice.git", NICE_PIN)
    if subprocess.run(["git", "-C", str(sdk), "apply", "--check", str(PATCH)],
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        run("git", "-C", sdk, "apply", PATCH)
    else:
        run("git", "-C", sdk, "apply", "--reverse", "--check", PATCH)
    if digest(sdk / "src/impl/icetransport.cpp") != PATCHED_ICE_SHA256:
        raise RuntimeError("SDK source includes changes beyond the reviewed backend patch")

    env = os.environ.copy()
    env["PATH"] = str(args.tools_prefix.resolve() / "bin") + os.pathsep + env["PATH"]
    env["PKG_CONFIG_PATH"] = os.pathsep.join([
        str(args.openssl_prefix.resolve() / "lib/pkgconfig"),
        str(args.glib_prefix.resolve() / "lib/pkgconfig"), env.get("PKG_CONFIG_PATH", "")])
    env["MACOSX_DEPLOYMENT_TARGET"] = args.deployment_target
    owned_dependencies = args.glib_prefix.resolve() / "owned-dependencies.json"
    if args.source_bundle and (not owned_dependencies.exists() or args.openssl_source is None):
        raise RuntimeError("Source material requires the pinned owned GLib receipt and OpenSSL source")
    if args.openssl_source is not None:
        if run("git", "-C", args.openssl_source, "rev-parse", "HEAD", capture=True).strip() != OPENSSL_PIN or run("git", "-C", args.openssl_source, "diff", "HEAD", "--name-only", capture=True).strip():
            raise RuntimeError("OpenSSL source differs from the reviewed pin; preserved without building")
    if owned_dependencies.exists():
        dependency_receipt = verify_owned_dependencies(args.glib_prefix.resolve(), args.architecture, args.deployment_target)
        env["PKG_CONFIG_PATH"] = os.pathsep.join([str(args.openssl_prefix.resolve() / "lib/pkgconfig"), str(args.glib_prefix.resolve() / "lib/pkgconfig")])
        env["PKG_CONFIG_LIBDIR"] = env["PKG_CONFIG_PATH"]
    flags = shlex.split(run("pkg-config", "--libs", "--static", "gio-2.0", "gobject-2.0", "gmodule-2.0", "gthread-2.0", env=env, capture=True))
    search = [Path(flag[2:]) for flag in flags if flag.startswith("-L")]
    search.append(args.glib_prefix.resolve() / "lib")
    dependencies, system_flags = [], []
    system = {"iconv", "z", "m", "resolv", "pthread", "c"}
    index = 0
    while index < len(flags):
        flag = flags[index]
        if flag.startswith("-l") and flag[2:] not in system:
            archive = next((p / ("lib" + flag[2:] + ".a") for p in search if (p / ("lib" + flag[2:] + ".a")).is_file()), None)
            if archive is None:
                if flag == "-lffi" and not owned_dependencies.exists():
                    system_flags.append(flag)
                    index += 1
                    continue
                raise RuntimeError(f"Required static dependency unavailable: {flag}")
            if archive.resolve() not in dependencies:
                dependencies.append(archive.resolve())
        elif flag == "-framework":
            index += 1
            system_flags.extend([flag, flags[index]])
        elif not flag.startswith("-L"):
            system_flags.append(flag)
        index += 1
    openssl_archives = [args.openssl_prefix.resolve() / "lib/libssl.a", args.openssl_prefix.resolve() / "lib/libcrypto.a"]
    dependency_floors = {str(path): archive_floor(path, args.architecture) for path in dependencies + openssl_archives}
    if any(version(floor) > requested_floor for floor in dependency_floors.values()):
        raise RuntimeError("A supplied dependency requires a newer runtime than the requested target; build matching dependencies first")

    nice_build, nice_install = root / "libnice-build", root / "libnice-install"
    reconfigure = ["--reconfigure"] if (nice_build / "build.ninja").exists() else []
    machine = root / "macos.ini"
    sdk_path = Path(run("xcrun", "--sdk", "macosx", "--show-sdk-path", capture=True).strip())
    machine_option = macos_machine_file(machine, args.architecture, args.deployment_target, sdk_path, args.glib_prefix.resolve())
    run("meson", "setup", *reconfigure, machine_option, machine, nice_build, nice, "--prefix=" + str(nice_install), "--default-library=static",
        "-Dgupnp=disabled", "-Dgstreamer=disabled", "-Dexamples=disabled", "-Dtests=disabled",
        "-Dgtk_doc=disabled", "-Dintrospection=disabled", "-Dcrypto-library=openssl", env=env)
    run("ninja", "-C", nice_build, "-j2", env=env)
    run("ninja", "-C", nice_build, "install", env=env)

    env["PKG_CONFIG_PATH"] = str(nice_install / "lib/pkgconfig") + os.pathsep + env["PKG_CONFIG_PATH"]
    sdk_build = root / "libdatachannel-build"
    run("cmake", "-S", sdk, "-B", sdk_build, "-DCMAKE_POLICY_VERSION_MINIMUM=3.5", "-DCMAKE_BUILD_TYPE=Release",
        "-DCMAKE_OSX_DEPLOYMENT_TARGET=" + args.deployment_target, "-DUSE_NICE=ON", "-DBUILD_SHARED_LIBS=OFF",
        "-DCMAKE_OSX_ARCHITECTURES=" + args.architecture,
        "-DBUILD_SHARED_DEPS_LIBS=OFF", "-DNO_EXAMPLES=ON", "-DNO_TESTS=ON", "-DUSE_SYSTEM_SRTP=OFF",
        "-DUSE_SYSTEM_USRSCTP=OFF", "-DOPENSSL_ROOT_DIR=" + str(args.openssl_prefix.resolve()),
        "-DOPENSSL_USE_STATIC_LIBS=ON", env=env)
    run("cmake", "--build", sdk_build, "--parallel", "2", env=env)
    archives = sorted(sdk_build.rglob("*.a")) + [nice_install / "lib/libnice.a"] + dependencies
    archives += openssl_archives
    built_floors = {str(path): archive_floor(path, args.architecture) for path in archives}
    if any(version(floor) > requested_floor for floor in built_floors.values()):
        raise RuntimeError("A built archive requires a newer runtime than requested; no combined backend was produced")
    output = root / "libdatachannel-nice-complete.a"
    merge_env = env.copy()
    merge_env["ZERO_AR_DATE"] = "1"
    run("libtool", "-static", "-o", output, *archives, env=merge_env)
    symbols = run("nm", "-arch", args.architecture, "-g", output, capture=True)
    for symbol in ["_stream_rtc_nice_relay_policy_20261021_v1", "_stream_rtc_turn_transports_20261021_v1"]:
        if not any(symbol in line and " U " not in line for line in symbols.splitlines()):
            raise RuntimeError("Compiled backend receipt missing")

    notices = root / "licenses"
    notices.mkdir(exist_ok=True)
    if owned_dependencies.exists():
        shutil.copyfile(owned_dependencies, root / "owned-glib-dependencies.json")
        for path in (args.glib_prefix.resolve() / "licenses").glob("*"):
            if path.is_file():
                shutil.copyfile(path, notices / path.name)
    for name, source in [("libdatachannel", sdk), ("libnice", nice), ("glib", args.glib_prefix.resolve()),
                         ("openssl", args.openssl_prefix.resolve())]:
        for pattern in ["COPYING*", "LICENSE*", "LICENCE*", "LGPL*", "*.spdx.json", "INSTALL_RECEIPT.json"]:
            for file in source.glob(pattern):
                if file.is_file():
                    shutil.copyfile(file, notices / (name + "-" + file.name))
    for archive in dependencies:
        prefix = archive.parent.parent
        for pattern in ["COPYING*", "LICENSE*", "LICENCE*", "LGPL*", "*.spdx.json", "INSTALL_RECEIPT.json"]:
            for file in prefix.glob(pattern):
                if file.is_file():
                    shutil.copyfile(file, notices / (prefix.name + "-" + file.name))
    for dependency in (sdk / "deps").iterdir():
        if dependency.is_dir():
            for pattern in ["COPYING*", "LICENSE*", "LICENCE*"]:
                for file in dependency.glob(pattern):
                    if file.is_file():
                        shutil.copyfile(file, notices / (dependency.name + "-" + file.name))
    receipt = {"sdkSource": SDK_PIN, "niceSource": NICE_PIN, "architecture": args.architecture, "patchSHA256": digest(PATCH),
               "opensslSource": OPENSSL_PIN if args.openssl_source is not None else None,
               "archiveSHA256": digest(output), "archivePayloadSHA256": archive_payload_digest(output), "archiveDatesZeroed": True,
               "requestedDeploymentTarget": args.deployment_target,
               "glibVersion": run("pkg-config", "--modversion", "glib-2.0", env=env, capture=True).strip(),
               "dependencies": [{"path": str(p), "sha256": digest(p)} for p in archives],
               "dependencyRuntimeFloors": built_floors,
               "sdkSubmodules": run("git", "-C", sdk, "submodule", "status", "--recursive", capture=True).splitlines(),
               "additionalSystemLinkFlags": system_flags, "turnTransports": ["udp", "tcp"],
               "tlsQualified": False, "scope": "opt-in owned backend; runtime, selected relay and decoded media qualification required"}
    (root / "nice-transport-build.json").write_text(json.dumps(receipt, indent=2) + "\n")
    if args.source_bundle:
        bundle = root / "corresponding-source"
        bundle.mkdir(exist_ok=True)
        source_records = {}
        for name, source in {"libdatachannel": sdk, "libnice": nice, "openssl": args.openssl_source,
                             **{path.name: path for path in (sdk / "deps").iterdir() if (path / ".git").exists()}}.items():
            packaged = bundle / (name + "-source.tar.gz")
            with packaged.open("wb") as destination:
                subprocess.run(["git", "-C", str(source), "archive", "--format=tar.gz", "HEAD"], stdout=destination, check=True)
            source_records[name] = {"pin": run("git", "-C", source, "rev-parse", "HEAD", capture=True).strip(), "archiveSHA256": digest(packaged)}
        for name, source in dependency_receipt["sources"].items():
            packaged = args.glib_prefix.resolve().parent / (name + "-source.tar.gz")
            if digest(packaged) != source["sourceArchiveSHA256"]:
                raise RuntimeError("Owned dependency source archive changed; refused incomplete source material")
            shutil.copyfile(packaged, bundle / packaged.name)
            source_records[name] = source
        recipes = bundle / "apple/scripts"
        recipes.mkdir(parents=True, exist_ok=True)
        for name in ["build_owned_nice_transport.py", "build_owned_glib_dependencies.py"]:
            shutil.copyfile(Path(__file__).resolve().parent / name, recipes / name)
        (recipes / "patches").mkdir(exist_ok=True)
        for name in [PATCH.name, "glib-2.84.4-macos-pipe2-availability.patch"]:
            shutil.copyfile(Path(__file__).resolve().parent / "patches" / name, recipes / "patches" / name)
        shutil.copytree(notices, bundle / "licenses", dirs_exist_ok=True)
        shutil.copyfile(owned_dependencies, bundle / "owned-glib-dependencies.json")
        shutil.copyfile(root / "nice-transport-build.json", bundle / "nice-transport-build.json")
        (bundle / "source-material.json").write_text(json.dumps({"sources": source_records, "scope": "corresponding dependency sources and recipes; application relink objects and release review remain separate"}, indent=2) + "\n")
    print("Owned backend archive and provenance: " + str(root))


if __name__ == "__main__":
    main()
