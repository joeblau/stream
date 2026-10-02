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
import type { Capability, Snapshot } from "../src/studio-client.ts";
const { WebSocketServer } = createRequire(import.meta.url)("ws");
async function until(check: () => boolean) {
  for (let i = 0; i < 700; ++i) { if (check()) return; await new Promise(resolve => setTimeout(resolve, 10)); }
  assert.fail("Dial SDK fixture timed out");
}
test("bundled Plus dials batch ticks, serialize authoritative deltas, handle mute/touch, selectors and reconnect without replay", async () => {
  const directory = await mkdtemp(resolve(tmpdir(), "stream-plus-test-"));
  const projectID = randomUUID(), sceneA = randomUUID(), sceneB = randomUUID();
  const gainID = "audio.microphone.gain", muteID = "audio.microphone.mute";
  const selectA = `scene.${sceneA}.select`, selectB = `scene.${sceneB}.select`;
  const state: Snapshot = { projectID, revision: 1, stream: "idle", recording: "paused", preview: "active", pendingStagedEdits: false,
    stagedSceneID: sceneA, layerVisibility: {}, values: { [gainID]: 0.5 }, mutes: { [gainID]: false }, macroProgress: { phase: "idle", stepIndex: 0, totalSteps: 0, message: "" } };
  const commands: Capability[] = [{ id: gainID, title: "Microphone Gain", category: "Audio Levels", available: true, kind: "value" },
    { id: muteID, title: "Mute Microphone", category: "Audio", available: true, kind: "command" },
    { id: selectA, title: "Opening", category: "Scenes", available: true }, { id: selectB, title: "Interview", category: "Scenes", available: true }];
  const peers = new Map<net.Socket, string>();
  let valueRequests = 0, muteRequests = 0, selections = 0, dropNext = false;
  const native = net.createServer(socket => {
    const sessionID = randomUUID(); peers.set(socket, sessionID); socket.on("close", () => peers.delete(socket));
    let buffer = "";
    socket.on("data", data => {
      buffer += data.toString(); let newline: number;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        const request = JSON.parse(buffer.slice(0, newline)); buffer = buffer.slice(newline + 1);
        const send = (type: string, payload: object = {}) => socket.write(JSON.stringify({ version: 1, type, id: request.id, sessionID, ...payload }) + "\n");
        if (request.type === "authenticate") send("authenticated", { snapshot: state });
        if (request.type === "subscribe") send("snapshot", { snapshot: state });
        if (request.type === "capabilities") send("capabilities", { commands, totalCommands: commands.length });
        if (request.type === "command") {
          if (request.commandID === gainID) { ++valueRequests; state.values![gainID] = request.value ?? Math.max(0, Math.min(1, state.values![gainID]! + request.delta)); }
          if (request.commandID === muteID) { ++muteRequests; state.mutes![gainID] = !state.mutes![gainID]; }
          if (request.commandID === selectA || request.commandID === selectB) { ++selections; state.stagedSceneID = request.commandID === selectA ? sceneA : sceneB; }
          ++state.revision;
          if (dropNext) { dropNext = false; socket.destroy(); }
          else send("result", { result: { succeeded: true }, snapshot: state });
        }
      }
    });
  });
  native.listen(0, "127.0.0.1"); await once(native, "listening");
  const pairing = { version: 1, clientID: randomUUID(), token: "c".repeat(64), port: (native.address() as net.AddressInfo).port };
  const sd = new WebSocketServer({ port: 0, host: "127.0.0.1" }); await once(sd, "listening");
  const received: any[] = [], settings = new Map<string, object>([["dial-a", { commandID: gainID, projectID, step: 0.01 }], ["dial-b", { commandID: gainID, projectID, step: 0.01 }], ["selector", { commandID: selectA, projectID, category: "Scenes" }]]);
  let sdPeer: any, child: ReturnType<typeof spawn> | undefined, output = "";
  const send = (event: string, context: string, payload: object = {}) => sdPeer.send(JSON.stringify({ event, context, action: `com.joeblau.stream-studio.${context === "selector" ? "selector" : "level"}`, device: context === "dial-b" ? "plus-b" : "plus-a",
    payload: { controller: "Encoder", coordinates: { column: context === "dial-b" ? 1 : 0, row: 0 }, settings: settings.get(context), ...payload } }));
  sd.on("connection", (peer: any) => {
    sdPeer = peer; peer.on("message", (data: Buffer) => {
      const message = JSON.parse(data.toString()); received.push(message);
      if (message.event === "getSettings") send("didReceiveSettings", message.context);
      if (message.event === "setSettings") { settings.set(message.context, message.payload); send("didReceiveSettings", message.context); }
    });
  });
  const publish = () => { ++state.revision; for (const [peer, sessionID] of peers) peer.write(JSON.stringify({ version: 1, type: "event", sessionID, snapshot: state }) + "\n"); };
  try {
    await mkdir(resolve(directory, "bin")); await copyFile("com.joeblau.stream-studio.sdPlugin/manifest.json", resolve(directory, "manifest.json"));
    await writeFile(resolve(directory, "package.json"), '{"type":"module"}');
    await build({ entryPoints: ["src/plugin.ts"], bundle: true, platform: "node", format: "esm", target: "node24", outfile: resolve(directory, "bin/plugin.js"), banner: { js: 'import {createRequire} from "node:module"; const require = createRequire(import.meta.url);' } });
    await writeFile(resolve(directory, "bin/keychain-helper"), `#!/usr/bin/env node\nif (process.argv[2] === "read") process.stdout.write(${JSON.stringify(JSON.stringify(pairing))});\n`, { mode: 0o755 });
    const info = { application: { version: "7.1.0", platform: "mac", platformVersion: "15.0", language: "en", font: "Arial" }, devices: ["plus-a", "plus-b"].map(id => ({ id, name: id, type: 5, size: { columns: 4, rows: 2 } })), plugin: { version: "0.1.0", uuid: "com.joeblau.stream-studio" } };
    child = spawn(process.execPath, [resolve(directory, "bin/plugin.js"), "-port", String(sd.address().port), "-pluginUUID", "fixture", "-registerEvent", "registerPlugin", "-info", JSON.stringify(info)], { cwd: directory, stdio: ["ignore", "pipe", "pipe"] });
    child.stdout?.on("data", data => { output += data.toString(); }); child.stderr?.on("data", data => { output += data.toString(); });
    await until(() => received.some(message => message.event === "registerPlugin"));
    send("willAppear", "dial-a"); send("willAppear", "dial-b"); send("willAppear", "selector");
    await until(() => received.filter(message => message.event === "setFeedback" && message.payload.title === "Microphone Gain").length >= 2);
    send("dialRotate", "dial-a", { ticks: 3, pressed: false }); send("dialRotate", "dial-a", { ticks: 2, pressed: false }); send("dialRotate", "dial-b", { ticks: -2, pressed: false });
    await until(() => valueRequests === 2); assert.ok(Math.abs(state.values![gainID]! - 0.53) < 0.00001);
    await until(() => received.some(message => message.event === "setFeedback" && message.payload.value === "106%"));
    send("dialDown", "dial-a"); send("dialDown", "dial-a"); await until(() => muteRequests === 1);
    send("dialUp", "dial-a"); send("touchTap", "dial-b", { hold: false, tapPos: [100, 50] }); await until(() => muteRequests === 2);
    send("touchTap", "dial-a", { hold: true, tapPos: [100, 50] }); await until(() => valueRequests === 3); assert.equal(state.values![gainID], 0.5);
    send("dialRotate", "selector", { ticks: 1, pressed: false }); await until(() => (settings.get("selector") as any).commandID === selectB); assert.equal(selections, 0);
    send("dialDown", "selector"); send("dialDown", "selector"); await until(() => selections === 1); assert.equal(state.stagedSceneID, sceneB);
    commands[3]!.title = "Renamed Interview"; publish(); await until(() => received.some(message => message.event === "setFeedback" && message.payload.title === "Renamed Interview"));
    commands.pop(); publish(); await until(() => received.some(message => message.context === "selector" && message.event === "setFeedback" && message.payload.title === "Missing\nResource"));
    send("dialUp", "selector"); send("dialDown", "selector"); await new Promise(resolve => setTimeout(resolve, 100)); assert.equal(selections, 1);
    dropNext = true; send("dialRotate", "dial-a", { ticks: 1, pressed: false }); await until(() => valueRequests === 4);
    await until(() => peers.size === 1); await new Promise(resolve => setTimeout(resolve, 300)); assert.equal(valueRequests, 4, "A lost acknowledgement never replays numeric deltas");
    send("dialRotate", "dial-b", { ticks: 4, pressed: false }); send("willDisappear", "dial-b"); await new Promise(resolve => setTimeout(resolve, 200)); assert.equal(valueRequests, 4, "Page teardown discards queued rotation");
    sdPeer.send(JSON.stringify({ event: "deviceDidDisconnect", device: "plus-a" })); await new Promise(resolve => setTimeout(resolve, 50));
    const before = received.length; state.values![gainID] = 0.7; publish(); await new Promise(resolve => setTimeout(resolve, 600));
    assert.equal(received.slice(before).some(message => message.event === "setFeedback" && message.context === "dial-a"), false);
    assert.equal(child.exitCode, null, output); assert.equal(output.includes(pairing.token), false);
  } finally {
    if (child && child.exitCode === null) { child.kill("SIGTERM"); await once(child, "exit"); }
    peers.forEach((_, peer) => peer.destroy()); sdPeer?.terminate();
    await new Promise<void>(resolve => sd.close(() => resolve())); await new Promise<void>(resolve => native.close(() => resolve()));
    await rm(directory, { recursive: true, force: true });
  }
});
