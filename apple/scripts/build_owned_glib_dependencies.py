#!/usr/bin/env python3
"""Build pinned static GLib dependencies into an owned prefix, without Homebrew libraries."""
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
import tarfile
import urllib.request

from build_owned_nice_transport import archive_floor, checkout, digest, macos_machine_file, run, version

PINS = {
    "glib": ("https://github.com/GNOME/glib.git", "41eca60845d3fc309af361f5e7f801ba339099aa"),
    "pcre2": ("https://github.com/PCRE2Project/pcre2.git", "b2bd4254b379b9d7dc9a3dda060a7e27009ccdff"),
    "proxy-libintl": ("https://github.com/frida/proxy-libintl.git", "33934de09af6a6627eb44e310a8079df009abdbb"),
}
FFI_URL = "https://github.com/libffi/libffi/releases/download/v3.4.8/libffi-3.4.8.tar.gz"
FFI_SHA256 = "bc9842a18898bfacb0ed1252c4febcc7e78fa139fd27fdc7a3e30d9d9356119b"
GLIB_PATCH = Path(__file__).resolve().parent / "patches/glib-2.84.4-macos-pipe2-availability.patch"
GLIB_PATCHED_SHA256 = "e0bf4daf9ad7ab002b1326edd190828534cc6d2642f2006471a205fc28ca8cc6"


def pc(prefix, name, content):
    directory = prefix / "lib/pkgconfig"
    directory.mkdir(parents=True, exist_ok=True)
    (directory / (name + ".pc")).write_text(content)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", required=True, type=Path)
    parser.add_argument("--tools-prefix", required=True, type=Path)
    parser.add_argument("--architecture", choices=["arm64", "x86_64"], default=platform.machine())
    parser.add_argument("--deployment-target", default="14.0")
    args = parser.parse_args()
    version(args.deployment_target)
    root = args.build_dir.resolve()
    root.mkdir(parents=True, exist_ok=True)
    sources = {name: checkout(root, name + "-source", *spec, recursive=name == "glib") for name, spec in PINS.items()}
    if subprocess.run(["git", "-C", str(sources["glib"]), "apply", "--check", str(GLIB_PATCH)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        run("git", "-C", sources["glib"], "apply", GLIB_PATCH)
    if digest(sources["glib"] / "meson.build") != GLIB_PATCHED_SHA256:
        raise RuntimeError("GLib source differs from the exact reviewed availability patch")
    archive = root / "libffi-3.4.8.tar.gz"
    if not archive.exists():
        with urllib.request.urlopen(FFI_URL, timeout=60) as response, archive.open("wb") as output:
            shutil.copyfileobj(response, output)
    if digest(archive) != FFI_SHA256:
        raise RuntimeError("Unexpected libffi release archive; preserved without extraction")
    ffi = root / "libffi-3.4.8"
    if not ffi.exists():
        with tarfile.open(archive) as source:
            source.extractall(root, filter="data")
    with tarfile.open(archive) as source:
        for member in source.getmembers():
            if member.isfile():
                candidate = root / member.name
                if candidate.is_symlink() or not candidate.resolve().is_relative_to(ffi.resolve()):
                    raise RuntimeError("libffi source path replaced; preserved without building")
                expected = hashlib.sha256(source.extractfile(member).read()).hexdigest()
                if not candidate.is_file() or digest(candidate) != expected:
                    raise RuntimeError("libffi extracted source differs from pinned release; preserved without building")

    owned = root / args.architecture
    owned.mkdir(exist_ok=True)
    prefix = owned / "prefix"
    sdk = Path(run("xcrun", "--sdk", "macosx", "--show-sdk-path", capture=True).strip())
    configuration = {"architecture": args.architecture, "target": args.deployment_target, "sdk": str(sdk), "prefix": str(prefix)}
    configuration_path = owned / "build-configuration.json"
    if configuration_path.exists() and json.loads(configuration_path.read_text()) != configuration:
        raise RuntimeError("Owned build configuration changed; choose a fresh directory")
    configuration_path.write_text(json.dumps(configuration, indent=2) + "\n")
    env = os.environ.copy()
    env["PATH"] = str(args.tools_prefix.resolve() / "bin") + os.pathsep + env["PATH"]
    env["PKG_CONFIG_PATH"] = str(prefix / "lib/pkgconfig")
    env["PKG_CONFIG_LIBDIR"] = env["PKG_CONFIG_PATH"]
    env["MACOSX_DEPLOYMENT_TARGET"] = args.deployment_target
    env["CC"] = "xcrun --sdk macosx clang -arch " + args.architecture
    env["CFLAGS"] = shlex.join(["-O2", "-mmacosx-version-min=" + args.deployment_target, "-isysroot", str(sdk)])
    ffi_build = owned / "libffi-build"
    ffi_build.mkdir(exist_ok=True)
    if not (ffi_build / "Makefile").exists():
        subprocess.run([str(ffi / "configure"), "--prefix=" + str(prefix), "--disable-shared", "--enable-static", "--disable-docs",
                        "--disable-multi-os-directory", "--host=" + ("aarch64" if args.architecture == "arm64" else "x86_64") + "-apple-darwin"], cwd=ffi_build, env=env, check=True)
    subprocess.run(["make", "-j2"], cwd=ffi_build, env=env, check=True)
    subprocess.run(["make", "install"], cwd=ffi_build, env=env, check=True)

    pcre_build = owned / "pcre2-build"
    run("cmake", "-S", sources["pcre2"], "-B", pcre_build, "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_INSTALL_PREFIX=" + str(prefix),
        "-DCMAKE_OSX_ARCHITECTURES=" + args.architecture, "-DCMAKE_OSX_DEPLOYMENT_TARGET=" + args.deployment_target,
        "-DBUILD_SHARED_LIBS=OFF", "-DPCRE2_BUILD_TESTS=OFF", "-DPCRE2_BUILD_PCRE2GREP=OFF", "-DPCRE2_SUPPORT_JIT=OFF", env=env)
    run("cmake", "--build", pcre_build, "--parallel", "2", env=env)
    run("cmake", "--install", pcre_build, env=env)

    machine = owned / "macos.ini"
    machine_option = macos_machine_file(machine, args.architecture, args.deployment_target, sdk, prefix)
    for name, options in [("proxy-libintl", []), ("glib", ["-Dtests=false", "-Dinstalled_tests=false", "-Dintrospection=disabled",
                         "-Ddocumentation=false", "-Dman-pages=disabled", "-Dnls=disabled", "-Dlibmount=disabled", "-Dselinux=disabled",
                         "-Dsysprof=disabled", "-Ddtrace=disabled", "-Dsystemtap=disabled", "-Dlibelf=disabled"])]:
        build = owned / (name + "-build")
        reconfigure = ["--reconfigure"] if (build / "build.ninja").exists() else []
        run("meson", "setup", *reconfigure, machine_option, machine, build, sources[name], "--prefix=" + str(prefix), "--libdir=lib",
            "--default-library=static", "--buildtype=release", "--wrap-mode=nodownload", *options, env=env)
        run("ninja", "-C", build, "-j2", env=env)
        run("ninja", "-C", build, "install", env=env)
        if name == "proxy-libintl":
            pc(prefix, "intl", f"prefix={prefix}\nName: owned proxy-libintl\nDescription: pinned upstream STUB_ONLY intl fallback\nVersion: 1\nLibs: -L${{prefix}}/lib -lintl\nCflags: -I${{prefix}}/include -DG_INTL_STATIC_COMPILATION\n")
            zlib_version = re.search(r'#define ZLIB_VERSION\s+"([^"]+)"', (sdk / "usr/include/zlib.h").read_text()).group(1)
            pc(prefix, "zlib", f"Name: macOS SDK zlib\nDescription: public SDK system zlib\nVersion: {zlib_version}\nLibs: -lz\nCflags: -I{sdk}/usr/include\n")

    archives = sorted((prefix / "lib").glob("*.a"))
    floors = {str(path): archive_floor(path, args.architecture) for path in archives}
    if any(version(value) > version(args.deployment_target) for value in floors.values()):
        raise RuntimeError("Owned dependency archive exceeds requested runtime floor")
    licenses = prefix / "licenses"
    licenses.mkdir(exist_ok=True)
    source_receipts = {}
    for name, source in {**sources, "libffi": ffi}.items():
        for pattern in ["COPYING*", "LICENSE*", "LICENCE*", "LGPL*"]:
            for path in source.glob(pattern):
                if path.is_file():
                    shutil.copyfile(path, licenses / (name + "-" + path.name))
        packaged = owned / (name + "-source.tar.gz")
        if name == "libffi":
            shutil.copyfile(archive, packaged)
        else:
            with packaged.open("wb") as output:
                subprocess.run(["git", "-C", str(source), "archive", "--format=tar.gz", "HEAD"], stdout=output, check=True)
        source_receipts[name] = {"url": FFI_URL if name == "libffi" else PINS[name][0],
                                 "pin": FFI_SHA256 if name == "libffi" else PINS[name][1], "sourceArchiveSHA256": digest(packaged)}
    gvdb = sources["glib"] / "subprojects/gvdb"
    gvdb_archive = owned / "gvdb-source.tar.gz"
    with gvdb_archive.open("wb") as output:
        subprocess.run(["git", "-C", str(gvdb), "archive", "--format=tar.gz", "HEAD"], stdout=output, check=True)
    source_receipts["gvdb"] = {"url": "https://github.com/GNOME/gvdb.git", "pin": run("git", "-C", gvdb, "rev-parse", "HEAD", capture=True).strip(), "sourceArchiveSHA256": digest(gvdb_archive)}
    shutil.copyfile(GLIB_PATCH, owned / GLIB_PATCH.name)
    receipt = {**configuration, "sources": source_receipts, "glibPatchSHA256": digest(GLIB_PATCH), "archives": [{"path": str(path), "sha256": digest(path), "minOS": floors[str(path)]} for path in archives],
               "buildTools": {"meson": run("meson", "--version", env=env, capture=True).strip(), "ninja": run("ninja", "--version", env=env, capture=True).strip(), "xcode": run("xcodebuild", "-version", capture=True).strip()},
               "intlMode": "upstream STUB_ONLY; transport dependency messages untranslated", "pcreJIT": False,
               "systemDependencies": ["Apple public SDK frameworks, libc, libz, libiconv, libresolv"],
               "scope": "owned optional transport dependencies; runtime/media qualification separate"}
    (prefix / "owned-dependencies.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print("Owned pinned GLib dependency prefix: " + str(prefix))


if __name__ == "__main__":
    main()
