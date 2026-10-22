"""Check that the official plugin package preserves each candidate verbatim."""
import hashlib
import json
from pathlib import Path
import zipfile

root = Path(__file__).resolve().parents[1]
plugin = "com.joeblau.stream-studio.sdPlugin"
package_path = root / "dist/com.joeblau.stream-studio.streamDeckPlugin"
with zipfile.ZipFile(package_path) as package:
    assert package.testzip() is None
    names = package.namelist()
    assert len(names) == len(set(names)), "Duplicate package entries"
    assert all(name.startswith(plugin + "/") and ".." not in Path(name).parts for name in names)
    manifest = json.loads(package.read(plugin + "/manifest.json"))
    assert len(manifest["Profiles"]) == 3
    for registration in manifest["Profiles"]:
        relative = registration["Name"] + ".streamDeckProfile"
        assert package.read(plugin + "/" + relative) == (root / plugin / relative).read_bytes()
        assert registration["AutoInstall"] is False
        assert registration["DontAutoSwitchWhenInstalled"] is True
        assert registration["Readonly"] is False
    license_text = (root / "profiles/ELGATO_MEMORYGAME_LICENSE.txt").read_bytes()
    assert license_text in package.read(plugin + "/THIRD_PARTY_LICENSES.txt")
print("PASS: official package contains three exact candidate archives, safe registrations and the MIT notice;")
print("target Stream Deck import/install acceptance remains pending")
print("package SHA256", hashlib.sha256(package_path.read_bytes()).hexdigest())
