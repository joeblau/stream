// Actual Chromium DOM + WebSocket test of the shipped inspector. The owned
// browser profile, loopback server and fake Stream Deck peer never use operator
// settings, a device, the real Stream Deck app or Keychain.
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { spawn } from 'node:child_process';
import { access, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import http from 'node:http';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
const { WebSocket, WebSocketServer } = createRequire(import.meta.url)('ws');
const root = new URL('../com.joeblau.stream-studio.sdPlugin/ui/', import.meta.url);
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const directory = await mkdtemp(path.join(tmpdir(), 'stream-deck-inspector-browser-'));
let chrome, browserSocket, inspector;
const frames = [], runtimeErrors = [];
const server = http.createServer(async (request, response) => {
  const name = request.url === '/' ? 'command.html' : request.url?.slice(1);
  if (!['command.html', 'command.js'].includes(name)) { response.writeHead(404).end(); return; }
  response.setHeader('Content-Type', name.endsWith('.js') ? 'text/javascript' : 'text/html');
  response.end(await readFile(new URL(name, root)));
});
const deck = new WebSocketServer({ noServer: true });
server.on('upgrade', (request, socket, head) => deck.handleUpgrade(request, socket, head, peer => deck.emit('connection', peer)));
deck.on('connection', peer => { inspector = peer; peer.on('message', raw => frames.push(JSON.parse(raw))); });
server.listen(0, '127.0.0.1'); await once(server, 'listening');
const port = server.address().port;
async function executable() {
  for (const candidate of [process.env.CHROME_BIN, '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '/usr/bin/google-chrome', '/usr/bin/chromium'].filter(Boolean)) {
    try { await access(candidate); return candidate; } catch {}
  }
  throw new Error('Chrome is required for actual inspector qualification; set CHROME_BIN.');
}
let serial = 0;
const pending = new Map();
function rpc(method, params = {}) {
  const id = ++serial;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`Chrome timed out: ${method}`)); }, 10_000);
    pending.set(id, { resolve, reject, timer }); browserSocket.send(JSON.stringify({ id, method, params }));
  });
}
async function evaluate(expression) {
  const result = await rpc('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description ?? result.exceptionDetails.text);
  return result.result.value;
}
async function wait(check, label) {
  for (let i = 0; i < 100; ++i) { if (await check()) return; await delay(30); }
  throw new Error(`Inspector timeout: ${label}`);
}
function update(payload, context = 'owned-key') { inspector.send(JSON.stringify({ event: 'sendToPropertyInspector', context, payload })); }
try {
  chrome = spawn(await executable(), ['--headless=new', '--remote-debugging-port=0', `--user-data-dir=${directory}`,
    '--no-first-run', '--no-default-browser-check', '--password-store=basic', '--use-mock-keychain', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
  let stderr = ''; chrome.stderr.on('data', bytes => { stderr += bytes; });
  await wait(() => /DevTools listening on (ws:\/\/[^\s]+)/.test(stderr), 'Chrome startup');
  const endpoint = /DevTools listening on (ws:\/\/[^\s]+)/.exec(stderr)[1];
  const targets = await (await fetch(endpoint.replace(/^ws:/, 'http:').replace(/\/devtools\/browser\/.*/, '/json/list'))).json();
  browserSocket = new WebSocket(targets.find(target => target.type === 'page').webSocketDebuggerUrl);
  await once(browserSocket, 'open');
  browserSocket.on('message', raw => {
    const message = JSON.parse(raw), call = pending.get(message.id);
    if (call) { clearTimeout(call.timer); pending.delete(message.id); message.error ? call.reject(new Error(message.error.message)) : call.resolve(message.result); }
    if (message.method === 'Runtime.exceptionThrown') runtimeErrors.push(message.params.exceptionDetails.text);
  });
  await rpc('Runtime.enable');
  await rpc('Emulation.setDeviceMetricsOverride', { width: 320, height: 900, deviceScaleFactor: 1, mobile: false });
  await rpc('Page.navigate', { url: `http://127.0.0.1:${port}/` });
  await wait(() => evaluate('typeof window.connectElgatoStreamDeckSocket === "function"'), 'shipped script');
  await evaluate(`window.connectElgatoStreamDeckSocket(${port}, 'owned-key', 'registerPropertyInspector', '{}', JSON.stringify({action:'com.joeblau.stream-studio.command',payload:{settings:{}}}))`);
  await wait(() => frames.some(frame => frame.event === 'registerPropertyInspector'), 'real WebSocket registration');
  const id = 'scene.stable.select';
  const commands = [{ id, title: 'Opening', category: 'Scenes', available: true },
    { id: 'destination.stable.endRemote', title: 'End Opening Event', category: 'Destinations', available: true, requiresConfirmation: true },
    { id: 'guest.slot.stable.admit', title: 'Admit Alice', category: 'Guests', available: false, unavailableReason: 'No guest is assigned to this slot.' },
    { id: 'show.show-a.profile.profile-a.select', title: 'Open Interview', category: 'Show Profiles', available: true },
    { id: 'output.record.marker', title: 'Marker', category: 'Recording', argument: 'text', available: true }];
  const state = { status: 'Connected', projectID: 'project-a', settings: { commandID: id, projectID: 'project-a' }, commands };
  update(state);
  await wait(() => evaluate('document.getElementById("command").value === "scene.stable.select"'), 'initial binding');
  await evaluate('document.getElementById("resource-type").value="guest";document.getElementById("resource-type").dispatchEvent(new Event("change"))');
  assert.deepEqual(await evaluate('[...document.getElementById("command").options].map(option=>option.value)'), ['', 'guest.slot.stable.admit', id]);
  assert.match(await evaluate('document.getElementById("binding").textContent'), /scene\.stable/);
  update({ ...state, commands: commands.map(command => command.id === id ? { ...command, title: '<Renamed & Safe>' } : command) });
  await wait(() => evaluate('document.getElementById("command").selectedOptions[0].textContent === "<Renamed & Safe>"'), 'rename without rebinding');
  update({ ...state, commands: commands.filter(command => command.id !== id) });
  await wait(() => evaluate('document.getElementById("availability").textContent.includes("Missing resource")'), 'deleted resource');
  assert.equal(await evaluate('document.getElementById("command").selectedOptions[0].disabled'), true);
  update({ ...state, projectID: 'other-project' });
  await wait(() => evaluate('document.getElementById("availability").textContent.includes("current project")'), 'project change');
  const profileSettings = { commandID: 'show.show-a.profile.profile-a.select', projectID: 'project-a', scope: 'studio', authority: 'stale-settings' };
  const profileState = { ...state, projectID: 'profile-b', settings: profileSettings,
    commands: commands.map(command => command.id === profileSettings.commandID ? { ...command, scope: 'studio', authority: 'fresh-descriptor' } : command) };
  const beforeProfile = frames.length;
  update(profileState);
  await wait(() => evaluate('document.getElementById("availability").textContent === "Available"'), 'fresh studio scope across profile switch');
  assert.match(await evaluate('document.getElementById("project").textContent'), /Current show’s saved profiles/);
  assert.equal(await evaluate('document.getElementById("command").value'), profileSettings.commandID);
  assert.equal(frames.length, beforeProfile, 'Scope display must preserve projectID without rebinding or persisting authority');
  for (const scope of [undefined, 'unknown']) {
    update({ ...profileState, commands: commands.map(command => ({ ...command, scope })) });
    await wait(() => evaluate('document.getElementById("availability").textContent.includes("current project")'), 'unknown scope remains guarded');
  }
  update({ ...profileState, commands: commands.filter(command => command.id !== profileSettings.commandID) });
  await wait(() => evaluate('document.getElementById("command").selectedOptions[0].disabled'), 'missing profile descriptor after show switch');
  assert.match(await evaluate('document.getElementById("availability").textContent'), /current project/);
  update({ ...profileState, status: 'Disconnected' });
  await wait(() => evaluate('document.getElementById("availability").textContent.includes("Connect to Stream Studio")'), 'stale scope after disconnect');
  assert.doesNotMatch(await evaluate('document.getElementById("project").textContent'), /Current show’s saved profiles/);
  assert.equal(frames.length, beforeProfile);
  update({ ...state, settings: { commandID: 'output.record.marker', projectID: 'project-a', text: 'Original' } });
  await wait(() => evaluate('document.getElementById("marker").value === "Original"'), 'marker binding');
  await evaluate('document.getElementById("marker").value="Draft 👩🏽‍🚀"'); update({ ...state, settings: { commandID: 'output.record.marker', projectID: 'project-a', text: 'Original' } });
  await delay(70); assert.equal(await evaluate('document.getElementById("marker").value'), 'Draft 👩🏽‍🚀');
  const before = frames.length;
  await evaluate('document.getElementById("marker").value="👩🏽‍🚀".repeat(60);document.getElementById("apply-marker").click()');
  await delay(70); assert.equal(frames.length, before); assert.match(await evaluate('document.getElementById("error").textContent'), /UTF-8/);
  update({ ...state, settings: { commandID: 'destination.stable.endRemote', projectID: 'project-a' } });
  await wait(() => evaluate('!document.getElementById("confirmation").hidden'), 'native confirmation explanation');
  update({ ...state, status: 'Disconnected' });
  await wait(() => evaluate('document.getElementById("command").disabled'), 'disconnect');
  update(state); await wait(() => evaluate('!document.getElementById("command").disabled'), 'reconnect');
  update({ ...state, settings: { commandID: 'wrong-key', projectID: 'project-a' } }, 'another-key');
  await delay(70); assert.equal(await evaluate('document.getElementById("command").value'), id);
  const camera = 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE', screen = '11111111-2222-3333-4444-555555555555';
  const sourceCommand = 'scene.stable.layer.stable.source.select';
  const sourceCommands = [...commands,
    { id: sourceCommand, title: 'Choose Camera', category: 'Camera / PIP', argument: 'source', sourceKind: 'camera', available: true, authority: 'never-persist' },
    { id: `source.${camera}.effects.bypass`, title: 'Bypass Shared Source Effects — Camera One', category: 'Shared Sources', sourceKind: 'camera', available: true },
    { id: `source.${screen}.effects.bypass`, title: 'Bypass Shared Source Effects — Screen One', category: 'Shared Sources', sourceKind: 'screen', available: true }];
  await evaluate('document.getElementById("resource-type").value="";document.getElementById("resource-type").dispatchEvent(new Event("change"))');
  update({ ...state, commands: sourceCommands });
  await wait(() => evaluate(`!![...document.getElementById('command').options].find(option=>option.value === '${sourceCommand}')`), 'source command');
  const bindingsBeforeSource = frames.length;
  await evaluate(`document.getElementById('command').value='${sourceCommand}';document.getElementById('command').dispatchEvent(new Event('change'))`);
  assert.equal(await evaluate('document.getElementById("source-options").hidden'), false);
  assert.deepEqual(await evaluate('[...document.getElementById("source").options].map(option=>option.value)'), ['', camera]);
  assert.equal(frames.length, bindingsBeforeSource, 'Choosing the target must not silently bind a source');
  await evaluate(`document.getElementById('source').value='${camera}';document.getElementById('source').dispatchEvent(new Event('change'));document.getElementById('apply-source').click()`);
  await wait(() => frames.length > bindingsBeforeSource, 'explicit source binding');
  assert.deepEqual(frames.at(-1).payload, { operation: 'bind', commandID: sourceCommand, text: camera });
  assert.equal(await evaluate('getComputedStyle(document.getElementById("confirmation")).display'), 'none');
  assert.equal(await evaluate('document.documentElement.scrollWidth <= window.innerWidth'), true, 'Inspector must fit a 320px panel without horizontal scrolling');
  if (process.env.STREAM_INSPECTOR_SCREENSHOT) {
    const image = await rpc('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true });
    await writeFile(process.env.STREAM_INSPECTOR_SCREENSHOT, Buffer.from(image.data, 'base64'));
  }
  const oldPeer = inspector, binds = frames.filter(frame => frame.payload?.operation === 'bind').length;
  oldPeer.close();
  await wait(() => evaluate('document.getElementById("status").textContent === "Stream Deck disconnected"'), 'actual inspector socket close');
  await evaluate(`window.connectElgatoStreamDeckSocket(${port}, 'owned-key', 'registerPropertyInspector', '{}', JSON.stringify({action:'com.joeblau.stream-studio.command',payload:{settings:${JSON.stringify(state.settings)}}}))`);
  await wait(() => inspector !== oldPeer && frames.filter(frame => frame.event === 'registerPropertyInspector').length === 2, 'new inspector registration');
  update(state); await wait(() => evaluate('document.getElementById("command").value === "scene.stable.select"'), 'persisted binding after reconnect');
  assert.equal(frames.filter(frame => frame.payload?.operation === 'bind').length, binds, 'Reconnect must not rebind or replay an action');
  assert.deepEqual(runtimeErrors, []);
  console.log('PASS: actual Chrome inspector DOM/WebSocket registration, live resource filtering, rename/delete, project changes, UTF-8 validation, draft preservation, confirmation notice, disconnect/reconnect, context isolation and bounded typed source binding.');
} finally {
  for (const call of pending.values()) { clearTimeout(call.timer); call.reject(new Error('Browser fixture closed')); }
  browserSocket?.close(); for (const peer of deck.clients) peer.terminate(); deck.close(); server.close();
  if (chrome && chrome.exitCode === null) { chrome.kill(); await Promise.race([once(chrome, 'exit'), delay(3000)]); }
  await rm(directory, { recursive: true, force: true });
}
