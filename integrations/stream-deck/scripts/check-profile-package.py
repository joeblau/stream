"""Check that the official plugin package preserves each candidate verbatim."""
import hashlib
import json
from pathlib import Path
import stat
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = "com.joeblau.stream-studio.sdPlugin"


def check_package(package_path):
    with zipfile.ZipFile(package_path) as package:
        assert package.testzip() is None
        names = package.namelist()
        assert len(names) == len(set(names)), "Duplicate package entries"
        for entry in package.infolist():
            name = entry.filename
            assert name.startswith(PLUGIN + "/") and ".." not in Path(name).parts, "Unsafe package path"
            assert "\\" not in name, "Backslash package path"
            entry_type = stat.S_IFMT(entry.external_attr >> 16)
            assert entry_type in (0, stat.S_IFREG, stat.S_IFDIR), "Unsupported package entry type"
            # DOS-created archives may omit Unix type bits; otherwise the
            # metadata and directory suffix must agree. Never accept a link.
            assert entry_type in ((0, stat.S_IFDIR) if entry.is_dir() else (0, stat.S_IFREG)), "Package entry type/path mismatch"
        manifest = json.loads(package.read(PLUGIN + "/manifest.json"))
        assert len(manifest["Profiles"]) == 3
        for registration in manifest["Profiles"]:
            relative = registration["Name"] + ".streamDeckProfile"
            assert package.read(PLUGIN + "/" + relative) == (ROOT / PLUGIN / relative).read_bytes()
            assert registration["AutoInstall"] is False
            assert registration["DontAutoSwitchWhenInstalled"] is True
            assert registration["Readonly"] is False
        license_text = (ROOT / "profiles/ELGATO_MEMORYGAME_LICENSE.txt").read_bytes()
        assert license_text in package.read(PLUGIN + "/THIRD_PARTY_LICENSES.txt")


if __name__ == "__main__":
    package_path = ROOT / "dist/com.joeblau.stream-studio.streamDeckPlugin"
    check_package(package_path)
    print("PASS: official package contains three exact candidate archives, safe entries/registrations and the MIT notice;")
    print("target Stream Deck import/install acceptance remains pending")
    print("package SHA256", hashlib.sha256(package_path.read_bytes()).hexdigest())
