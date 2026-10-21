import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";

// Run the actual property inspector against its DOM/WebSocket boundary. This
// catches live-event behavior without accessing Stream Deck or the Keychain.
async function inspector() {
  class Control {
    value = ""; textContent = ""; hidden = false; disabled = false;
    children: Control[] = [];
    onclick?: () => void;
    replaceChildren(...children: Control[]) { this.children = children; }
  }
  class Option extends Control {
    constructor(text: string, value = text) { super(); this.textContent = text; this.value = value; }
  }
  const controls = new Map<string, Control>();
  const element = (id: string) => {
    if (!controls.has(id)) controls.set(id, new Control());
    return controls.get(id)!;
  };
  let peer: Socket;
  class Socket {
    static OPEN = 1;
    readyState = 1; sent: any[] = [];
    onopen?: () => void; onclose?: () => void;
    onmessage?: (event: { data: string }) => void;
    constructor(_url: string) { peer = this; }
    send(data: string) { this.sent.push(JSON.parse(data)); }
    receive(payload: object, event = "sendToPropertyInspector") { this.onmessage?.({ data: JSON.stringify({ event, payload }) }); }
  }
  const window: Record<string, any> = {};
  const context = vm.createContext({ window, document: { getElementById: element }, Option, WebSocket: Socket });
  vm.runInContext(await readFile("com.joeblau.stream-studio.sdPlugin/ui/command.js", "utf8"), context);
  window.connectElgatoStreamDeckSocket(12345, "key", "registerPropertyInspector", "{}",
    JSON.stringify({ action: "com.joeblau.stream-studio.command", payload: { settings: {} } }));
  peer!.onopen?.();
  return { element, peer: peer! };
}

test("inspector preserves unsubmitted edits through live snapshots and hydrates acknowledged settings", async () => {
  const { element, peer } = await inspector();
  const binding = { commandID: "output.record.marker", projectID: "project", text: "Original" };
  const payload = { status: "Connected", projectID: "project", settings: binding,
    commands: [{ id: binding.commandID, title: "Marker", category: "Recording", argument: "text", available: true }] };
  peer.receive(payload);
  assert.equal(element("marker").value, "Original");
  element("marker").value = "New chapter in progress";
  element("page").value = "17"; element("step").value = "4"; element("value").value = "125";
  peer.receive({ ...payload, commands: [{ ...payload.commands[0], available: false, unavailableReason: "Not recording" }] });
  assert.equal(element("marker").value, "New chapter in progress");
  assert.equal(element("page").value, "17"); assert.equal(element("step").value, "4"); assert.equal(element("value").value, "125");
  assert.equal(element("availability").textContent, "Not recording");
  element("apply-marker").onclick?.();
  assert.deepEqual(peer.sent.at(-1).payload, { operation: "bind", commandID: binding.commandID, text: "New chapter in progress" });
  peer.receive({ settings: { ...binding, text: "Acknowledged chapter" } }, "didReceiveSettings");
  assert.equal(element("marker").value, "Acknowledged chapter");
});

test("inspector retains missing stable bindings with explicit unavailable feedback and refuses rebinding them", async () => {
  const { element, peer } = await inspector();
  const settings = { commandID: "scene.deleted.select", projectID: "project" };
  peer.receive({ status: "Connected", projectID: "project", settings, commands: [] });
  assert.match(element("availability").textContent, /Missing resource/);
  assert.equal(element("command").value, settings.commandID);
  assert.equal(element("command").children.at(-1)?.disabled, true);
  const before = peer.sent.length;
  element("apply-value").onclick?.();
  assert.equal(peer.sent.length, before);
  assert.match(element("error").textContent, /supported resource/);
  peer.receive({ status: "Connected", projectID: "other-project", settings, commands: [] });
  assert.match(element("availability").textContent, /current project/);
  peer.onclose?.();
  assert.match(element("availability").textContent, /Connect to Stream Studio/);
});
