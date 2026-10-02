import test from "node:test";
import assert from "node:assert/strict";
import net from "node:net";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { StudioClient, validatePairing, type Snapshot, type Capability } from "../src/studio-client.ts";
import { feedback, keyImage } from "../src/feedback.ts";
async function waitUntil(check: () => boolean): Promise<void> {
  for (let i = 0; i < 400; ++i) { if (check()) return; await new Promise(resolve => setTimeout(resolve, 10)); }
  assert.fail("Controller test timed out");
}
const snapshot = (): Snapshot => ({ projectID: "project-a", revision: 1, stream: "idle", recording: "idle", preview: "active",
  pendingStagedEdits: true, stagedSceneID: "scene-a", programSceneID: "scene-b", layerVisibility: {},
  macroProgress: { phase: "idle", stepIndex: 0, totalSteps: 0, message: "" } });

test("pairing validates loopback, version, credential shape and port without echoing secrets", () => {
  const pairing = { version: 1, clientID: randomUUID(), token: "a".repeat(64), host: "127.0.0.1", port: 12345 };
  assert.equal(validatePairing(pairing).clientID, pairing.clientID);
  for (const invalid of [{ ...pairing, host: "0.0.0.0" }, { ...pairing, version: 2 }, { ...pairing, port: 0 }, { ...pairing, token: "secret" }, { ...pairing, clientID: "not-a-uuid" }]) {
    assert.throws(() => validatePairing(invalid), /Paste version 1/);
  }
});
test("feedback uses authoritative preview/program, paused recording, and missing/project states", () => {
  const state = snapshot();
  const scene = randomUUID(); state.stagedSceneID = scene;
  const id = `scene.${scene}.select`;
  const commands = new Map<string, Capability>([[id, { id, title: "Intro", category: "Scenes", available: true }]]);
  const binding = { commandID: id, projectID: state.projectID };
  assert.equal(feedback(binding, "Connected", state, commands).badge, "PVW");
  state.programSceneID = scene;
  assert.equal(feedback(binding, "Connected", state, commands).badge, "PGM");
  assert.equal(feedback(binding, "Disconnected", state, commands).unavailable, true);
  assert.equal(feedback({ ...binding, projectID: "other" }, "Connected", state, commands).title, "Project\nChanged");
  commands.delete(id);
  assert.equal(feedback(binding, "Connected", state, commands).title, "Missing\nResource");
  state.recording = "paused"; commands.set("output.record.stop", { id: "output.record.stop", title: "Stop Recording", category: "Output", available: true });
  assert.equal(feedback({ commandID: "output.record.stop", projectID: state.projectID }, "Connected", state, commands).badge, "PAUSED");
  state.stream = "connecting"; commands.set("output.stream.stop", { id: "output.stream.stop", title: "Cancel", category: "Output", available: true });
  assert.equal(feedback({ commandID: "output.stream.stop", projectID: state.projectID }, "Connected", state, commands).badge, "CONNECTING");
  assert.ok(keyImage({ title: "Name", badge: "<unsafe>", color: "#000000", unavailable: false }).startsWith("data:image/svg+xml;base64,"));
});

test("native client authenticates/discovers stable IDs, follows state, and never replays on reconnect", async () => {
  const state = snapshot();
  const id = `scene.${randomUUID()}.select`;
  const commands: Capability[] = [{ id, title: "Intro", category: "Scenes", available: true }];
  const peers = new Set<net.Socket>();
  const sessions = new Map<net.Socket, string>();
  let commandCount = 0, dropNextCommand = false, handshakeCount = 0;
  const server = net.createServer(socket => {
    peers.add(socket); socket.on("close", () => peers.delete(socket));
    let buffer = "", session = randomUUID(), authenticated = false;
    sessions.set(socket, session);
    socket.on("data", data => {
      buffer += data.toString(); let newline: number;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        const request = JSON.parse(buffer.slice(0, newline)); buffer = buffer.slice(newline + 1);
        const send = (type: string, payload: object = {}) => socket.write(JSON.stringify({ version: 1, type, id: request.id.toUpperCase(), sessionID: session, ...payload }) + "\n");
        if (request.type === "authenticate") { ++handshakeCount; authenticated = true; send("authenticated", { snapshot: state }); continue; }
        assert.equal(authenticated, true); assert.equal(request.sessionID, session);
        assert.equal(request.token, undefined, "Tokens only belong in the handshake");
        if (request.type === "subscribe") send("snapshot", { snapshot: state });
        if (request.type === "capabilities") send("capabilities", { commands, totalCommands: commands.length });
        if (request.type === "command") {
          ++commandCount;
          if (dropNextCommand) { dropNextCommand = false; socket.destroy(); }
          else send("result", { result: { succeeded: true }, snapshot: state });
        }
      }
    });
  });
  server.listen(0, "127.0.0.1"); await once(server, "listening");
  const port = (server.address() as net.AddressInfo).port;
  const client = new StudioClient();
  try {
    client.configure({ version: 1, clientID: randomUUID(), token: "a".repeat(64), port });
    await waitUntil(() => client.status === "Connected");
    assert.equal(client.capabilities.get(id)?.title, "Intro");
    await client.execute(id, state.projectID); assert.equal(commandCount, 1);
    commands[0].title = "Renamed Intro";
    await client.refreshCatalog(); assert.equal(client.capabilities.get(id)?.title, "Renamed Intro");
    state.stream = "connecting"; ++state.revision;
    for (const peer of peers) peer.write(JSON.stringify({ version: 1, type: "event", sessionID: sessions.get(peer), snapshot: state }) + "\n");
    await waitUntil(() => client.snapshot?.stream === "connecting");
    assert.notEqual(client.snapshot?.stream, "live", "Accepted commands cannot invent acknowledged LIVE");
    dropNextCommand = true;
    await assert.rejects(client.execute(id, state.projectID), /disconnected|retried/i);
    await waitUntil(() => client.status === "Connected" && handshakeCount >= 2);
    assert.equal(commandCount, 2, "Reconnect never sends the dropped command again");
    state.projectID = "project-b"; ++state.revision;
    for (const peer of peers) peer.write(JSON.stringify({ version: 1, type: "event", sessionID: sessions.get(peer), snapshot: state }) + "\n");
    await waitUntil(() => client.snapshot?.projectID === "project-b");
    await assert.rejects(client.execute(id, "project-a"), /configured project/);
    assert.equal(commandCount, 2);
    commands.splice(0); await client.refreshCatalog();
    await assert.rejects(client.execute(id, state.projectID), /missing/);
    assert.equal(commandCount, 2);
  } finally { client.close(); for (const peer of peers) peer.destroy(); await new Promise<void>(resolve => server.close(() => resolve())); }
});
test("version mismatch stays incompatible and does not spin or fake availability", async () => {
  const peers = new Set<net.Socket>(); let connections = 0;
  const server = net.createServer(socket => {
    ++connections; peers.add(socket); socket.on("close", () => peers.delete(socket));
    socket.once("data", () => socket.end(JSON.stringify({ version: 2, type: "authenticated" }) + "\n"));
  });
  server.listen(0, "127.0.0.1"); await once(server, "listening");
  const client = new StudioClient();
  try {
    client.configure({ version: 1, clientID: randomUUID(), token: "a".repeat(64), port: (server.address() as net.AddressInfo).port });
    await waitUntil(() => client.status === "Incompatible");
    await new Promise(resolve => setTimeout(resolve, 1100));
    assert.equal(connections, 1); assert.equal(client.snapshot, undefined); assert.equal(client.capabilities.size, 0);
  } finally { client.close(); for (const peer of peers) peer.destroy(); await new Promise<void>(resolve => server.close(() => resolve())); }
});

test("malformed and unexpected native responses stop safely without throwing from socket callbacks", async () => {
  for (const frame of [null, { version: 1, type: "capabilities", commands: {} }, { version: 1, type: "authenticated", snapshot: {} }]) {
    const peers = new Set<net.Socket>();
    const server = net.createServer(socket => {
      peers.add(socket); socket.on("close", () => peers.delete(socket));
      socket.once("data", () => socket.end(JSON.stringify(frame) + "\n"));
    });
    server.listen(0, "127.0.0.1"); await once(server, "listening");
    const client = new StudioClient();
    try {
      client.configure({ version: 1, clientID: randomUUID(), token: "a".repeat(64), port: (server.address() as net.AddressInfo).port });
      await waitUntil(() => client.status === "Incompatible");
      assert.equal(client.snapshot, undefined); assert.equal(client.capabilities.size, 0);
    } finally { client.close(); for (const peer of peers) peer.destroy(); await new Promise<void>(resolve => server.close(() => resolve())); }
  }
});
