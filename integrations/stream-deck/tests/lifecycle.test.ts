import test from "node:test";
import assert from "node:assert/strict";
import net from "node:net";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { spawn } from "node:child_process";
import { mkdtemp, mkdir, copyFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { createRequire } from "node:module";
import { build } from "esbuild";
import type { Snapshot } from "../src/studio-client.ts";
const { WebSocketServer } = createRequire(import.meta.url)("ws");
async function waitUntil(check: () => boolean): Promise<void> {
  for (let i = 0; i < 500; ++i) { if (check()) return; await new Promise(resolve => setTimeout(resolve, 10)); }
  assert.fail("SDK lifecycle test timed out");
}

test("bundled SDK routes independent device instances, updates tallies, and persists only stable bindings", async () => {
  const directory = await mkdtemp(resolve(tmpdir(), "stream-deck-test-"));
  const projectID = randomUUID(), sceneID = randomUUID();
  const commandID = `scene.${sceneID}.select`;
  const state: Snapshot = { projectID, revision: 1, stream: "idle", recording: "paused", preview: "active", pendingStagedEdits: false,
    stagedSceneID: sceneID, layerVisibility: {}, macroProgress: { phase: "idle", stepIndex: 0, totalSteps: 0, message: "" } };
  const commands = [{ id: commandID, title: "Opening", category: "Scenes", available: true }];
  const nativePeers = new Map<net.Socket, string>();
  let connections = 0, executions = 0;
  const native = net.createServer(socket => {
    ++connections; const sessionID = randomUUID(); nativePeers.set(socket, sessionID);
    socket.on("close", () => nativePeers.delete(socket));
    let buffer = "";
    socket.on("data", data => {
      buffer += data.toString(); let newline: number;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        const request = JSON.parse(buffer.slice(0, newline)); buffer = buffer.slice(newline + 1);
        const send = (type: string, payload: object = {}) => socket.write(JSON.stringify({ version: 1, type, id: request.id, sessionID, ...payload }) + "\n");
        if (request.type === "authenticate") send("authenticated", { snapshot: state });
        if (request.type === "subscribe") send("snapshot", { snapshot: state });
        if (request.type === "capabilities") send("capabilities", { commands, totalCommands: commands.length });
        if (request.type === "command") { ++executions; send("result", { result: { succeeded: true }, snapshot: state }); }
      }
    });
  });
  native.listen(0, "127.0.0.1"); await once(native, "listening");
  const pairing = { version: 1, clientID: randomUUID(), token: "a".repeat(64), host: "127.0.0.1", port: (native.address() as net.AddressInfo).port };
  const sd = new WebSocketServer({ port: 0, host: "127.0.0.1" }); await once(sd, "listening");
  const received: any[] = [];
  const settings = new Map([ ["key-a", { commandID, projectID }], ["key-b", { commandID, projectID }] ]);
  let sdPeer: any;
  sd.on("connection", (peer: any) => {
    sdPeer = peer;
    peer.on("message", (frame: Buffer) => {
      const message = JSON.parse(frame.toString()); received.push(message);
      if (message.event === "getSettings") send("didReceiveSettings", message.context, settings.get(message.context), undefined, message.id);
      if (message.event === "setSettings") { settings.set(message.context, message.payload); send("didReceiveSettings", message.context, message.payload); }
    });
  });
  const action = "com.joeblau.stream-studio.command";
  const send = (event: string, context: string, binding: unknown = settings.get(context), customPayload?: object, id?: string) => sdPeer.send(JSON.stringify({ event, action, context,
    device: context === "key-a" ? "device-a" : "device-b", ...(id ? { id } : {}),
    payload: customPayload ?? { controller: "Keypad", coordinates: { column: 0, row: 0 }, isInMultiAction: false, settings: binding } }));
  let child: ReturnType<typeof spawn> | undefined;
  let childOutput = "";
  try {
    await mkdir(resolve(directory, "bin"));
    await copyFile("com.joeblau.stream-studio.sdPlugin/manifest.json", resolve(directory, "manifest.json"));
    await writeFile(resolve(directory, "package.json"), '{"type":"module"}');
    await build({ entryPoints: ["src/plugin.ts"], bundle: true, platform: "node", format: "esm", target: "node24", outfile: resolve(directory, "bin/plugin.js"),
      banner: { js: 'import {createRequire} from "node:module"; const require = createRequire(import.meta.url);' } });
    // Fixture credentials replace the helper inside this isolated plugin; tests never touch the user's Keychain.
    await writeFile(resolve(directory, "bin/keychain-helper"), `#!/usr/bin/env node\nif (process.argv[2] === "read") process.stdout.write(${JSON.stringify(JSON.stringify(pairing))});\n`, { mode: 0o755 });
    const info = { application: { version: "7.1.0", platform: "mac", platformVersion: "15.0", language: "en", font: "Arial" },
      devices: ["device-a", "device-b"].map(id => ({ id, name: id, type: 0, size: { columns: 5, rows: 3 } })), plugin: { version: "0.1.0", uuid: "com.joeblau.stream-studio" } };
    child = spawn(process.execPath, [resolve(directory, "bin/plugin.js"), "-port", String(sd.address().port), "-pluginUUID", "plugin-instance", "-registerEvent", "registerPlugin", "-info", JSON.stringify(info)],
      { cwd: directory, stdio: ["ignore", "pipe", "pipe"] });
    child.stdout?.on("data", data => { childOutput += data.toString(); }); child.stderr?.on("data", data => { childOutput += data.toString(); });
    await waitUntil(() => received.some(message => message.event === "registerPlugin"));
    send("willAppear", "key-a"); send("willAppear", "key-b");
    await waitUntil(() => received.filter(message => message.event === "setTitle" && message.payload.title === "Opening").length >= 2);
    assert.equal(connections, 1, "All devices share one native session");
    assert.deepEqual(new Set(received.filter(message => message.event === "setTitle" && message.payload.title === "Opening").map(message => message.context)), new Set(["key-a", "key-b"]));
    send("keyDown", "key-a"); send("keyDown", "key-a"); send("keyDown", "key-b");
    await waitUntil(() => executions === 2); await new Promise(resolve => setTimeout(resolve, 100));
    assert.equal(executions, 2, "Held repeat is suppressed independently for each device");
    send("keyUp", "key-a"); send("keyUp", "key-b"); send("keyDown", "key-a");
    await waitUntil(() => executions === 3);
    send("propertyInspectorDidAppear", "key-b");
    await waitUntil(() => received.some(message => message.event === "sendToPropertyInspector" && message.payload.status === "Connected"));
    send("sendToPlugin", "key-b", undefined, { operation: "bind", commandID });
    await waitUntil(() => received.some(message => message.event === "setSettings"));
    const persisted = received.find(message => message.event === "setSettings").payload;
    assert.deepEqual(persisted, { commandID, projectID }); assert.equal(JSON.stringify(persisted).includes(pairing.token), false);
    commands[0].title = "Renamed Opening"; ++state.revision;
    for (const [peer, sessionID] of nativePeers) peer.write(JSON.stringify({ version: 1, type: "event", sessionID, snapshot: state }) + "\n");
    await waitUntil(() => received.filter(message => message.event === "setTitle" && message.payload.title === "Renamed Opening").length >= 2);
    send("willDisappear", "key-a"); await new Promise(resolve => setTimeout(resolve, 50));
    const afterDisappear = received.length; state.stream = "live"; ++state.revision;
    for (const [peer, sessionID] of nativePeers) peer.write(JSON.stringify({ version: 1, type: "event", sessionID, snapshot: state }) + "\n");
    await new Promise(resolve => setTimeout(resolve, 600));
    assert.equal(received.slice(afterDisappear).some(message => message.context === "key-a" && ["setTitle", "setImage"].includes(message.event)), false);
    sdPeer.send(JSON.stringify({ event: "deviceDidDisconnect", device: "device-b" }));
    await new Promise(resolve => setTimeout(resolve, 50));
    const afterDisconnect = received.length; commands[0].title = "After Disconnect"; ++state.revision;
    for (const [peer, sessionID] of nativePeers) peer.write(JSON.stringify({ version: 1, type: "event", sessionID, snapshot: state }) + "\n");
    await new Promise(resolve => setTimeout(resolve, 600));
    assert.equal(received.slice(afterDisconnect).some(message => message.event === "setTitle" && message.payload.title === "After Disconnect"), false);
    assert.equal(child.exitCode, null, childOutput); assert.equal(childOutput.includes(pairing.token), false, "Pairing credentials never reach SDK logs");
  } finally {
    if (child && child.exitCode === null) { child.kill("SIGTERM"); await once(child, "exit"); }
    for (const peer of nativePeers.keys()) peer.destroy();
    sdPeer?.terminate(); await new Promise<void>(resolve => sd.close(() => resolve()));
    await new Promise<void>(resolve => native.close(() => resolve()));
    await rm(directory, { recursive: true, force: true });
  }
});
