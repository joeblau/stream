import test from "node:test";
import assert from "node:assert/strict";
import net from "node:net";
import { once } from "node:events";
import { randomUUID } from "node:crypto";
import { StudioClient, type Snapshot, type Capability } from "../src/studio-client.ts";
import { feedback } from "../src/feedback.ts";
const initial = (): Snapshot => ({ projectID: "transport-project", revision: 1, stream: "idle", recording: "idle", preview: "active",
  pendingStagedEdits: false, layerVisibility: {}, macroProgress: { phase: "idle", stepIndex: 0, totalSteps: 0, message: "" } });
async function until(condition: () => boolean): Promise<void> {
  for (let i = 0; i < 400; ++i) { if (condition()) return; await new Promise(resolve => setTimeout(resolve, 10)); }
  assert.fail("Transport client fixture deadline");
}
test("scene Run and each recording phase retain authoritative tally", () => {
  const state = initial(), id = randomUUID(), commandID = `scene.${id}.run`;
  const commands = new Map<string, Capability>([[commandID, { id: commandID, title: "Run opening", category: "Scenes", available: true }]]);
  state.stagedSceneID = id;
  assert.equal(feedback({ commandID, projectID: state.projectID }, "Connected", state, commands).badge, "PVW");
  state.programSceneID = id;
  assert.equal(feedback({ commandID, projectID: state.projectID }, "Connected", state, commands).badge, "PGM");
  for (const action of ["start", "stop", "pause", "resume", "split"]) {
    const commandID = `output.record.${action}`;
    commands.set(commandID, { id: commandID, title: action, category: "Output", available: false });
    for (const phase of ["idle", "preparing", "recording", "paused", "stopping", "failed"]) {
      state.recording = phase;
      assert.equal(feedback({ commandID, projectID: state.projectID }, "Connected", state, commands).badge, phase.toUpperCase());
    }
    state.recordingCountdown = 4;
    assert.equal(feedback({ commandID, projectID: state.projectID }, "Connected", state, commands).badge, "REC IN 4");
    state.recordingCountdown = 0;
  }
});
test("destination/event feedback separates confirmation, local delivery, and provider end receipts", () => {
  const state = initial(), id = randomUUID(), key = "a".repeat(64);
  state.transport = { destinations: [{ id, name: "YouTube", state: "live", eventKey: key, endingPending: false, confirmationPending: false }], confirmationPending: false, endingPending: false };
  const target = state.transport.destinations[0], commands = new Map<string, Capability>();
  const value = (action: string, event = key) => {
    const commandID = `destination.${id}.event.${event}.${action}`;
    commands.set(commandID, { id: commandID, title: action, category: "Destinations", available: !target.confirmationPending, requiresConfirmation: action.startsWith("end") });
    return feedback({ commandID, projectID: state.projectID }, "Connected", state, commands);
  };
  assert.equal(value("stop").badge, "LIVE");
  target.confirmationPending = true;
  assert.equal(value("endRemote").badge, "CONFIRM IN STUDIO");
  target.confirmationPending = false; target.endingPending = true;
  assert.equal(value("endRemote").badge, "ENDING");
  target.endingPending = false; target.remoteEnd = "unconfirmed";
  assert.equal(value("endRemote").badge, "REMOTE UNCONFIRMED");
  target.remoteEnd = "ended";
  assert.equal(value("endRemote").badge, "REMOTE ENDED");
  assert.equal(value("stop").badge, "LIVE", "Remote completion must not imply local disconnection");
  target.localStop = "Stop unconfirmed";
  assert.equal(value("endBoth").badge, "LOCAL STOP UNKNOWN", "Confirmed remote End hid unconfirmed local stop");
  target.localStop = "Stopped"; target.state = "idle";
  assert.equal(value("endBoth").badge, "ENDED");
  assert.equal(value("stop").badge, "LOCAL IDLE");
  assert.equal(value("endRemote", "b".repeat(64)).badge, "EVENT NOT CURRENT");
  target.managedStart = "review"; target.remoteEnd = undefined;
  assert.equal(value("start").badge, "REVIEW IN STUDIO");
  state.transport.destinations = [];
  assert.equal(value("start").title, "Missing\nDestination");
});
test("exact event requests survive rename, refresh on reconnect, and never replay native ending", async () => {
  const state = initial(), id = randomUUID(), event = "a".repeat(64);
  const start = `destination.${id}.event.${event}.start`, end = `destination.${id}.event.${event}.endRemote`;
  state.transport = { destinations: [{ id, name: "Opening", state: "idle", eventKey: event, endingPending: false, confirmationPending: false }], confirmationPending: false, endingPending: false };
  let commands: Capability[] = [start, end].map(id => ({ id, title: "Opening", category: "Destinations", available: true, requiresConfirmation: id === end,
    target: { kind: "destination", id, name: "Opening", provider: "youtube", channelID: "owner", eventID: "event" } }));
  const sockets = new Map<net.Socket, string>(), received: string[] = [];
  let connections = 0;
  const server = net.createServer(socket => {
    connections++; const sessionID = randomUUID(); sockets.set(socket, sessionID);
    socket.on("close", () => sockets.delete(socket)); let buffer = "";
    socket.on("data", data => {
      buffer += data.toString(); let index: number;
      while ((index = buffer.indexOf("\n")) >= 0) {
        const request = JSON.parse(buffer.slice(0, index)); buffer = buffer.slice(index + 1);
        const send = (type: string, payload: object) => socket.write(JSON.stringify({ version: 1, type, id: request.id, sessionID, ...payload }) + "\n");
        if (request.type === "authenticate") send("authenticated", { snapshot: state });
        if (request.type === "subscribe") send("snapshot", { snapshot: state });
        if (request.type === "capabilities") send("capabilities", { commands, totalCommands: commands.length });
        if (request.type === "command") {
          received.push(request.commandID);
          if (request.commandID === end) { socket.destroy(); continue; } // lost acknowledgement: consent may already be pending
          send("result", { result: { succeeded: true } });
        }
      }
    });
  });
  server.listen(0, "127.0.0.1"); await once(server, "listening");
  const client = new StudioClient();
  try {
    client.configure({ version: 1, clientID: randomUUID(), token: "a".repeat(64), port: (server.address() as net.AddressInfo).port });
    await until(() => client.status === "Connected");
    assert.equal(client.capabilities.get(end)?.requiresConfirmation, true);
    assert.equal(client.capabilities.get(end)?.target?.eventID, "event");
    await client.execute(start, state.projectID);
    commands = commands.map(c => ({ ...c, title: "Renamed event" }));
    await client.refreshCatalog(); assert.equal(client.capabilities.get(start)?.title, "Renamed event");
    await assert.rejects(client.execute(end, state.projectID));
    await until(() => connections === 2 && client.status === "Connected");
    assert.deepEqual(received, [start, end], "Reconnect replayed an ambiguous ending request");
    commands = []; await client.refreshCatalog();
    await assert.rejects(client.execute(start, state.projectID));
    assert.equal(received.length, 2, "Deleted event binding sent a command");
  } finally { client.close(); for (const socket of sockets.keys()) socket.destroy(); server.close(); await once(server, "close"); }
});
