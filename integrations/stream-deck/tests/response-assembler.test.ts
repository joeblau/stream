import test from "node:test";
import assert from "node:assert/strict";
import net from "node:net";
import { once } from "node:events";
import { randomUUID } from "node:crypto";
import { NativeResponseAssembler } from "../src/response-assembler.ts";
import { StudioClient, type Snapshot } from "../src/studio-client.ts";
import { feedback } from "../src/feedback.ts";
function snapshot(revision: number, destinations = 129): Snapshot {
  return { projectID: "large-project", revision, stream: "idle", recording: "idle", preview: "active", pendingStagedEdits: false, layerVisibility: {},
    transport: { destinations: Array.from({ length: destinations }, (_, index) => ({ id: randomUUID(), name: `Destination ${index} ${"日".repeat(64)}`, state: "idle", endingPending: false, confirmationPending: false })),
      confirmationPending: false, endingPending: false }, macroProgress: { phase: "idle", stepIndex: 0, totalSteps: 0, message: "" } };
}
const sessionID = randomUUID();
function chunks(response: object): any[] {
  const data = Buffer.from(JSON.stringify(response)), transferID = randomUUID(), count = Math.ceil(data.length / (24 * 1024)), value: any = response;
  assert.ok(data.length > 65536);
  return Array.from({ length: count }, (_, index) => ({ version: 1, type: "responseChunk", id: value.id, sessionID: value.sessionID,
    responseChunk: { transferID, index, count, totalBytes: data.length, responseType: value.type, snapshotRevision: value.snapshot?.revision,
      body: data.subarray(index * 24 * 1024, (index + 1) * 24 * 1024).toString("base64") } }));
}
async function until(predicate: () => boolean): Promise<void> {
  for (let i = 0; i < 400; ++i) { if (predicate()) return; await new Promise(resolve => setTimeout(resolve, 10)); }
  assert.fail("Bounded response fixture deadline");
}
test("bounded frames reconstruct complete maximum-size realistic resource receipts without dropping any key", () => {
  const state: any = snapshot(8, 256);
  // Distinct max-size staged/taken scenes plus sources and overlays; no reliance on shared UUIDs.
  state.visuals = Object.fromEntries(Array.from({ length: 512 }, (_, index) => [`scene.${randomUUID()}.layer.${randomUUID()}`,
    { previewVisible: index >= 256, programVisible: index < 256, sourceID: randomUUID(), programSourceID: randomUUID() }]));
  const response = { version: 1, type: "event", sessionID, snapshot: state };
  const frames = chunks(response), assembler = new NativeResponseAssembler();
  assert.ok(frames.length > 5);
  for (const frame of frames) assert.ok(Buffer.byteLength(JSON.stringify(frame)) <= 65536);
  // Out-of-order independent frames remain atomic and preserve split UTF-8 bytes.
  for (const frame of frames.slice(1).reverse()) assert.equal(assembler.accept(frame), undefined);
  assert.equal(assembler.pendingSnapshotRevision, 8);
  assert.deepEqual(assembler.accept(frames[0]), response);
  assert.equal(assembler.pendingCount, 0);
});
test("interleaved revisions retire old events while old request acknowledgements cannot roll back state", () => {
  const assembler = new NativeResponseAssembler();
  const old = chunks({ version: 1, type: "event", sessionID, snapshot: snapshot(10, 512) });
  const newer = chunks({ version: 1, type: "event", sessionID, snapshot: snapshot(11, 512) });
  const result = chunks({ version: 1, type: "result", id: randomUUID(), sessionID, result: { succeeded: true }, snapshot: snapshot(9, 512) });
  assert.equal(assembler.accept(old[0]), undefined);
  assert.equal(assembler.accept(result[0]), undefined);
  assert.equal(assembler.accept(newer[0]), undefined);
  assert.equal(assembler.pendingCount, 2, "New event retained a superseded incomplete event map");
  for (const frame of old.slice(1)) assert.equal(assembler.accept(frame), undefined);
  let fresh: any;
  for (const frame of newer.slice(1)) fresh = assembler.accept(frame) ?? fresh;
  assert.equal(fresh.snapshot.revision, 11);
  assembler.noteCompleteSnapshot(11);
  let ack: any;
  for (const frame of result.slice(1)) ack = assembler.accept(frame) ?? ack;
  assert.equal(ack.snapshot.revision, 9, "A request acknowledgement must still settle without replay");
  assert.equal(assembler.newestSnapshotRevision, 11, "Old reply rolled back authoritative revision");
});
test("mixed sessions, duplicate frames and invalid aggregate bounds reject rather than expose partial maps", () => {
  const response = { version: 1, type: "event", sessionID, snapshot: snapshot(1, 512) };
  const frames = chunks(response), assembler = new NativeResponseAssembler();
  assembler.accept(frames[0]);
  assert.throws(() => assembler.accept({ ...frames[1], sessionID: randomUUID() }), /Mixed/);
  assert.throws(() => assembler.accept(frames[0]), /duplicate/);
  const oversized = structuredClone(frames[1]); oversized.responseChunk.totalBytes = 16 * 1024 * 1024 + 1;
  assert.throws(() => new NativeResponseAssembler().accept(oversized), /metadata/);
  const badLength = structuredClone(frames[0]); badLength.responseChunk.body = Buffer.from("short").toString("base64");
  assert.throws(() => new NativeResponseAssembler().accept(badLength), /length/);
});
test("129 destinations and a large native revision stay usable, atomically update and retire old session chunks", async () => {
  const original = snapshot(1), large = snapshot(2, 512), newer = snapshot(3, 512);
  original.transport!.destinations[128].name = "Bound destination 129";
  const commandID = `destination.${original.transport!.destinations[128].id}.start`;
  let peers: net.Socket[] = [], connection = 0, currentSession = "", executeCount = 0;
  const server = net.createServer(socket => {
    peers.push(socket); const sessionID = randomUUID(); currentSession = sessionID; connection++; let buffer = "";
    socket.on("data", data => {
      buffer += data.toString(); let line: number;
      while ((line = buffer.indexOf("\n")) >= 0) {
        const request = JSON.parse(buffer.slice(0, line)); buffer = buffer.slice(line + 1);
        const send = (type: string, payload: object) => socket.write(JSON.stringify({ version: 1, type, id: request.id, sessionID, ...payload }) + "\n");
        if (request.type === "authenticate") { assert.equal(request.responseChunks, true); send("authenticated", { snapshot: original }); }
        if (request.type === "subscribe") send("snapshot", { snapshot: original });
        if (request.type === "capabilities") send("capabilities", { commands: [{ id: commandID, title: "Destination 129", category: "Destinations", available: true }] });
        if (request.type === "command") { executeCount++; send("result", { result: { succeeded: true } }); }
      }
    });
  });
  server.listen(0, "127.0.0.1"); await once(server, "listening");
  const client = new StudioClient();
  const pairing = { version: 1 as const, clientID: randomUUID(), token: "a".repeat(64), port: (server.address() as net.AddressInfo).port };
  const write = (frame: any) => peers.at(-1)!.write(JSON.stringify(frame) + "\n");
  try {
    client.configure(pairing); await until(() => client.status === "Connected");
    assert.equal(client.snapshot?.transport?.destinations.length, 129, "Legitimate saved destinations made the protocol incompatible");
    await client.execute(commandID, original.projectID); assert.equal(executeCount, 1);
    const old = chunks({ version: 1, type: "event", sessionID: currentSession, snapshot: large });
    write(old[0]); await until(() => client.snapshot?.receiptsPending === true);
    assert.equal(client.snapshot?.transport?.destinations.length, 129, "A partial new map became authoritative");
    assert.equal(feedback({ commandID, projectID: original.projectID }, client.status, client.snapshot, client.capabilities).title, "Updating\nState");
    await assert.rejects(client.execute(commandID, original.projectID), /updating complete/);
    const fresh = chunks({ version: 1, type: "event", sessionID: currentSession, snapshot: newer });
    write(fresh[0]); for (const frame of old.slice(1)) write(frame); for (const frame of fresh.slice(1)) write(frame);
    await until(() => client.snapshot?.revision === 3);
    assert.equal(client.snapshot?.transport?.destinations.length, 512); assert.equal(client.snapshot?.receiptsPending, undefined);
    const abandoned = chunks({ version: 1, type: "event", sessionID: currentSession, snapshot: snapshot(4, 512) });
    write(abandoned[0]); await until(() => client.snapshot?.receiptsPending === true);
    write({ version: 1, type: "event", sessionID: currentSession, snapshot: { ...original, revision: 5 } });
    await until(() => client.snapshot?.revision === 5 && !client.snapshot.receiptsPending);
    await new Promise(resolve => setTimeout(resolve, 5200));
    assert.equal(client.status, "Connected", "Retired partial event left a stale chunk timeout that disconnected healthy state");
    assert.equal(connection, 1);
    peers.at(-1)!.destroy(); await until(() => connection === 2 && client.status === "Connected");
    assert.equal(client.snapshot?.revision, 1, "A retired session's revision leaked through reconnect");
    assert.equal(executeCount, 1, "Resource refresh replayed a production request");
  } finally { client.close(); for (const socket of peers) socket.destroy(); server.close(); await once(server, "close"); }
});
