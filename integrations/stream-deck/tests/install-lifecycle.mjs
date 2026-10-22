// Opt-in official CLI development-link lifecycle. Only a random fixture UUID
// is linked. Its helper cannot access Keychain, and no profiles are authored,
// imported, removed or switched. A real package installation is a separate test.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { chmod, cp, lstat, mkdtemp, readFile, readdir, readlink, rm, unlink, writeFile } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
assert.equal(process.platform, 'darwin', 'The owned development-link lifecycle requires macOS.');
const root = fileURLToPath(new URL('../', import.meta.url));
const original = 'com.joeblau.stream-studio';
const id = `com.joeblau.stream-studio-fixture-${randomUUID()}`;
const directory = await mkdtemp(path.join(tmpdir(), 'stream-deck-owned-install-'));
const fixture = path.join(directory, `${id}.sdPlugin`);
const installedRoot = path.join(homedir(), 'Library/Application Support/com.elgato.StreamDeck/Plugins');
const installed = path.join(installedRoot, `${id}.sdPlugin`);
const cli = path.join(root, 'node_modules/@elgato/cli/bin/streamdeck.mjs');
const before = (await readdir(installedRoot)).sort();
assert(!before.includes(`${id}.sdPlugin`), 'Owned random fixture identity already exists.');
function run(...args) { return execFileSync(process.execPath, [cli, ...args], { cwd: root, encoding: 'utf8', timeout: 20_000 }); }
async function ownsLink() {
  try { return (await lstat(installed)).isSymbolicLink() && path.resolve(await readlink(installed)) === fixture; }
  catch (error) { if (error.code === 'ENOENT') return false; throw error; }
}
try {
  await cp(path.join(root, `${original}.sdPlugin`), fixture, { recursive: true });
  for (const name of ['manifest.json', 'bin/plugin.js']) {
    const file = path.join(fixture, name);
    await writeFile(file, (await readFile(file, 'utf8')).replaceAll(original, id));
  }
  const manifestPath = path.join(fixture, 'manifest.json');
  const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
  manifest.Name = 'Stream Studio Owned Install Fixture';
  await writeFile(manifestPath, JSON.stringify(manifest, null, 2));
  // This fixture can never read or replace an operator's real pairing.
  const helper = path.join(fixture, 'bin/keychain-helper');
  await writeFile(helper, '#!/bin/sh\nprintf "null\\n"\n'); await chmod(helper, 0o755);
  run('validate', fixture, '--no-update-check');
  run('link', fixture); assert(await ownsLink(), 'Official CLI did not link the owned fixture.');
  assert(run('list', '--all').split(/\r?\n/).some(line => line.includes(id)), 'Official CLI did not discover the fixture.');
  manifest.Version = '0.1.0.1'; await writeFile(manifestPath, JSON.stringify(manifest, null, 2));
  run('validate', fixture, '--no-update-check'); run('link', fixture);
  assert(await ownsLink(), 'Development update changed link ownership.');
  assert.equal(JSON.parse(await readFile(path.join(installed, 'manifest.json'), 'utf8')).Version, '0.1.0.1');
  run('unlink', id); assert.equal(await ownsLink(), false, 'Official CLI did not remove its owned link.');
  assert.deepEqual((await readdir(installedRoot)).sort(), before, 'Installed plugin inventory changed outside the owned fixture.');
  console.log('PASS: official CLI validation, unique owned development link/discovery/update/unlink, and unchanged original plugin inventory. No profile import or real package-install qualification claimed.');
} finally {
  // If a CLI error interrupts cleanup, remove only our exact verified symlink.
  if (await ownsLink()) await unlink(installed);
  await rm(directory, { recursive: true, force: true });
}
