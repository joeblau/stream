#!/usr/bin/env python3
"""Retain qualification CLI objects and relink them with a replaceable owned transport archive.

This produces local relinking evidence, not a signed/distributable application.
Dependency notices/corresponding source and release license review stay explicit.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

from build_owned_nice_transport import archive_floor, digest, run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--link-file-list", type=Path, required=True)
    parser.add_argument("--products-dir", type=Path, required=True)
    parser.add_argument("--backend-build-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--application-repository", type=Path, required=True)
    args = parser.parse_args()
    output = args.output_dir.resolve()
    if output.exists() and any(output.iterdir()):
        raise RuntimeError("Choose an empty owned relink directory; existing files were preserved")
    output.mkdir(parents=True, exist_ok=True)
    backend = args.backend_build_dir.resolve()
    receipt = json.loads((backend / "nice-transport-build.json").read_text())
    archive = backend / "libdatachannel-nice-complete.a"
    if digest(archive) != receipt["archiveSHA256"]:
        raise RuntimeError("Transport archive differs from source-build receipt")
    objects, libraries, frameworks = output / "objects", output / "lib", output / "frameworks"
    for directory in [objects, libraries, frameworks]:
        directory.mkdir()
    records = []
    for index, line in enumerate(args.link_file_list.read_text().splitlines()):
        source = Path(line.strip()).resolve()
        if not source.is_file() or source.suffix != ".o":
            raise RuntimeError("Unexpected application relink input")
        destination = objects / (f"{index:04d}-" + source.name)
        shutil.copyfile(source, destination)
        records.append({"object": str(destination.relative_to(output)), "sha256": digest(destination)})
    for name in ["StreamCore.framework", "Syphon.framework"]:
        shutil.copytree(args.products_dir.resolve() / name, frameworks / name, symlinks=True)
    shutil.copyfile(args.products_dir.resolve() / "libsrt.a", libraries / "libsrt.a")
    shutil.copyfile(archive, libraries / "libdatachannel.a")
    shutil.copytree(backend / "corresponding-source", output / "transport-corresponding-source", symlinks=True)
    repository = args.application_repository.resolve()
    baseline = run("git", "-C", repository, "rev-parse", "HEAD", capture=True).strip()
    with (output / "application-source.tar.gz").open("wb") as destination:
        subprocess.run(["git", "-C", str(repository), "archive", "--format=tar.gz", "HEAD"], stdout=destination, check=True)
    manifest = {"baseline": baseline, "architecture": receipt["architecture"], "target": receipt["requestedDeploymentTarget"],
                "objects": records, "transportSHA256": digest(libraries / "libdatachannel.a"), "srtSHA256": digest(libraries / "libsrt.a"),
                "frameworks": [{"name": name, "sha256": digest(frameworks / name / name.removesuffix(".framework")),
                                "minOS": archive_floor(frameworks / name / name.removesuffix(".framework"), receipt["architecture"])}
                               for name in ["StreamCore.framework", "Syphon.framework"]],
                "applicationSourceSHA256": digest(output / "application-source.tar.gz"),
                "scope": "local unstripped qualification relink inputs; Intel hardware, old-OS runtime, signing and release license review separate"}
    (output / "relink-material.json").write_text(json.dumps(manifest, indent=2) + "\n")
    # The retained standalone recipe accepts a replacement static transport
    # archive. No original source tree, SDK cache or application object changes.
    recipe = '''#!/usr/bin/env python3
import argparse,json,pathlib,subprocess
p=argparse.ArgumentParser();p.add_argument('--transport-archive',type=pathlib.Path);a=p.parse_args()
r=pathlib.Path(__file__).resolve().parent;m=json.loads((r/'relink-material.json').read_text())
sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
swift=pathlib.Path(subprocess.check_output(['xcrun','--find','swiftc'],text=True).strip()).parent.parent/'lib/swift/macosx'
transport=a.transport_archive.resolve() if a.transport_archive else r/'lib/libdatachannel.a'
command=['xcrun','clang++','-target',m['architecture']+'-apple-macos'+m['target'],'-isysroot',sdk]
command += [str(r/o['object']) for o in m['objects']]
command += ['-F'+str(r/'frameworks'),'-L'+str(r/'lib'),'-L'+str(swift),'-L/usr/lib/swift','-fobjc-link-runtime',
'-Wl,-no_warn_duplicate_libraries','-Wl,-rpath,@loader_path/frameworks','-Wl,-rpath,/usr/lib/swift',
'-lc++','-lz','-liconv','-lresolv','-framework','Carbon','-framework','StreamCore','-framework','Syphon',str(r/'lib/libsrt.a'),str(transport),'-o',str(r/'NativeInterviewReturnAudioCLI')]
subprocess.run(command,check=True)
'''
    (output / "relink.py").write_text(recipe)
    run("python3", output / "relink.py")
    binary = output / "NativeInterviewReturnAudioCLI"
    manifest["relinkedBinarySHA256"] = digest(binary)
    manifest["relinkedBinaryMinOS"] = archive_floor(binary, receipt["architecture"])
    (output / "relink-material.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("Retained application objects and successful replaceable transport relink: " + str(output))


if __name__ == "__main__":
    main()
