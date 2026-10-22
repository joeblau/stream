"""Build reproducible starter archives; target-app import acceptance is pending.

The legacy V1 action/state structure is derived from Elgato's MIT MemoryGame
sample at 46e9d9080e352a9d9a1ae2811bbb126e8e0bee95. No app/user data is read.
"""
import argparse
import copy
import hashlib
import io
import json
from pathlib import Path
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "com.joeblau.stream-studio.sdPlugin" / "profiles"
NAMESPACE = uuid.UUID("935e0435-1b78-5d4b-a847-48c4d24b3886")


def encoded(value):
    return (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def archive(layout, template):
    if layout["columns"] != 5 or layout["rows"] != 3 or layout["deviceType"] != 0:
        raise ValueError("The verified public V1 template describes a 15-key Stream Deck only")
    if not 1 <= len(layout["actions"]) <= 15:
        raise ValueError("Starter layout must fit its declared 15-key device")
    profile_id = str(uuid.uuid5(NAMESPACE, layout["id"] + "/15-key/v1")).upper()
    folder = profile_id + ".sdProfile/"
    document = {"Actions": {}, "DeviceModel": template["DeviceModel"],
                "Name": layout["name"], "Version": template["Version"]}
    entries = {folder: b"", folder + "LICENSE.txt": (ROOT / "profiles/ELGATO_MEMORYGAME_LICENSE.txt").read_bytes()}
    for index, binding in enumerate(layout["actions"]):
        coordinate = f'{index % layout["columns"]},{index // layout["columns"]}'
        state = copy.deepcopy(template["state"])
        state["Title"] = binding["title"]
        # No project identifier is a deliberate unbound starter, never a wildcard.
        # The live inspector must explicitly save the current project's binding.
        settings = {"commandID": binding["commandID"]} if "commandID" in binding else {}
        if binding.get("action") not in (None, "open"):
            raise ValueError("Unknown starter action")
        action_id = "command" if "commandID" in binding else "open"
        document["Actions"][coordinate] = {
            "Name": binding["title"], "Settings": settings, "State": 0,
            "States": [state], "UUID": "com.joeblau.stream-studio." + action_id}
        entries[folder + coordinate + "/"] = b""
        entries[folder + coordinate + "/CustomImages/"] = b""
    entries[folder + "manifest.json"] = encoded(document)
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w", compression=zipfile.ZIP_STORED) as package:
        for name, data in sorted(entries.items()):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = ((0o40755 if name.endswith("/") else 0o100644) << 16)
            info.compress_type = zipfile.ZIP_STORED
            package.writestr(info, data)
    return stream.getvalue()


def generate(check=False):
    template = json.loads((ROOT / "profiles/template-v1.json").read_text())
    layouts = json.loads((ROOT / "profiles/layouts.json").read_text())
    if len(layouts) != 3 or {layout["id"] for layout in layouts} != {"stream", "record", "interview"}:
        raise ValueError("Exactly one stream, record and interview starter is required")
    results = {}
    for layout in layouts:
        name = layout["id"] + "-15-key.streamDeckProfile"
        if not name.replace("-", "").replace(".", "").isalnum():
            raise ValueError("Invalid starter filename")
        if name in results:
            raise ValueError("Duplicate starter layout")
        results[name] = archive(layout, template)
    receipts = {"format": "Elgato public MemoryGame V1-derived candidate",
                "importAcceptance": "pending: not imported into Stream Deck",
                "sourceTemplate": {
                    "repository": "https://github.com/elgatosf/streamdeck-memorygame",
                    "commit": "46e9d9080e352a9d9a1ae2811bbb126e8e0bee95",
                    "archive": "Sources/Profiles/Memory.streamDeckProfile",
                    "sha256": "f26d68efea92002d7cf7219bdf7f281084062475172c39dd2c5457c05188e04a",
                    "license": "MIT, Copyright 2018 Corsair Memory, Inc"},
                "deviceType": 0, "deviceModel": template["DeviceModel"],
                "profiles": [{"file": name, "sha256": hashlib.sha256(data).hexdigest(),
                              "bytes": len(data)} for name, data in sorted(results.items())]}
    results["provenance.json"] = encoded(receipts)
    expected = set(results)
    present = {p.name for p in OUTPUT.iterdir()} if OUTPUT.exists() else set()
    if present - expected:
        raise ValueError("Unexpected profile output; refusing to delete unknown files")
    if check:
        if present != expected or any((OUTPUT / name).read_bytes() != data for name, data in results.items()):
            raise ValueError("Starter archives are stale; run npm run profiles")
    else:
        OUTPUT.mkdir(parents=True, exist_ok=True)
        for name, data in results.items():
            (OUTPUT / name).write_bytes(data)
    print("Verified" if check else "Generated", "three deterministic 15-key starters; importer acceptance pending")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    generate(parser.parse_args().check)
