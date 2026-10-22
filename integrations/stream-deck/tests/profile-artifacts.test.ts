import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";

test("outer package rejects links, nonregular entries, backslashes and inconsistent directory metadata", () => {
  execFileSync("python3", ["-B", "tests/profile-package-refusals.py"], { stdio: "pipe" });
});

test("three reproducible profile candidates contain supported owned actions and require explicit project rebinding", async () => {
  execFileSync("python3", ["scripts/generate-profiles.py", "--check"], { stdio: "pipe" });
  // The standard ZIP reader checks each real binary archive, not a generator's
  // in-memory representation. No Stream Deck app/user profile is involved.
  const profiles = JSON.parse(execFileSync("python3", ["-c", `
import hashlib,json,pathlib,zipfile
result=[]
for path in sorted(pathlib.Path('com.joeblau.stream-studio.sdPlugin/profiles').glob('*.streamDeckProfile')):
 with zipfile.ZipFile(path) as package:
  assert package.testzip() is None
  manifests=[name for name in package.namelist() if name.endswith('/manifest.json')]
  assert len(manifests)==1
  notices=[name for name in package.namelist() if name.endswith('/LICENSE.txt')]
  assert len(notices)==1 and b'Copyright 2018 Corsair Memory' in package.read(notices[0])
  result.append({'file':path.name,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
   'members':[{'name':info.filename,'time':list(info.date_time),'mode':info.external_attr>>16,'compression':info.compress_type} for info in package.infolist()],
   'document':json.loads(package.read(manifests[0]))})
print(json.dumps(result))
`], { encoding: "utf8" })) as Array<{ file: string; sha256: string; members: Array<{ name: string; time: number[]; mode: number; compression: number }>; document: any }>;
  assert.equal(profiles.length, 3);
  const plugin = JSON.parse(await readFile("com.joeblau.stream-studio.sdPlugin/manifest.json", "utf8"));
  const provenance = JSON.parse(await readFile("com.joeblau.stream-studio.sdPlugin/profiles/provenance.json", "utf8"));
  const layouts = JSON.parse(await readFile("profiles/layouts.json", "utf8"));
  const nativeCatalog = await readFile("../../apple/StreamMac/StudioCommandPalette.swift", "utf8");
  assert.match(provenance.importAcceptance, /^pending:/);
  assert.match(await readFile("profiles/ELGATO_MEMORYGAME_LICENSE.txt", "utf8"), /Copyright 2018 Corsair Memory/);
  assert.equal(plugin.Profiles.length, profiles.length);
  const ids = new Set<string>();
  for (const profile of profiles) {
    assert.equal(provenance.profiles.find((entry: any) => entry.file === profile.file)?.sha256, profile.sha256);
    const registration = plugin.Profiles.find((entry: any) => entry.Name === `profiles/${profile.file.replace(/\.streamDeckProfile$/, "")}`);
    assert.deepEqual(registration, { Name: `profiles/${profile.file.replace(/\.streamDeckProfile$/, "")}`, DeviceType: 0,
      Readonly: false, DontAutoSwitchWhenInstalled: true, AutoInstall: false });
    const root = profile.members[0]!.name.split("/")[0]!;
    assert.match(root, /^[0-9A-F-]{36}\.sdProfile$/);
    assert(!ids.has(root)); ids.add(root);
    for (const member of profile.members) {
      assert(member.name.startsWith(`${root}/`) && !member.name.includes("..") && !member.name.includes("\\"));
      assert.deepEqual(member.time, [1980, 1, 1, 0, 0, 0]);
      assert.equal(member.compression, 0, "Stored bytes avoid compressor-version differences");
      assert.notEqual(member.mode & 0o170000, 0o120000, "Profiles must not contain symlinks");
    }
    const layout = layouts.find((entry: any) => profile.file === `${entry.id}-15-key.streamDeckProfile`);
    assert(layout);
    assert.equal(profile.document.DeviceModel, "20GAA9901");
    assert.equal(profile.document.Version, "1.0");
    assert.equal(profile.document.Name, layout.name);
    assert.equal(Object.keys(profile.document.Actions).length, layout.actions.length);
    for (const [coordinate, value] of Object.entries(profile.document.Actions)) {
      const action = value as any, [column, row] = coordinate.split(",").map(Number);
      assert(column! >= 0 && column! < 5 && row! >= 0 && row! < 3);
      const binding = layout.actions[row! * 5 + column!];
      assert.equal(action.Name, binding.title);
      assert(plugin.Actions.some((entry: any) => entry.UUID === action.UUID && entry.Controllers.includes("Keypad")));
      assert.equal(action.State, 0);
      if (action.UUID.endsWith(".command")) {
        assert.deepEqual(action.Settings, { commandID: binding.commandID });
        assert(nativeCatalog.includes(JSON.stringify(binding.commandID)), `Unknown shipping command ${binding.commandID}`);
        assert(!/[0-9a-f]{8}-[0-9a-f-]{27}/i.test(binding.commandID), "Generic starters must not contain resource UUIDs");
      } else {
        assert.equal(action.UUID, "com.joeblau.stream-studio.open");
        assert.deepEqual(action.Settings, {});
      }
      assert.equal(action.States[0].Title, binding.title);
    }
  }
});
