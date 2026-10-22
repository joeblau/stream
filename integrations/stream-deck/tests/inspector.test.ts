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
    onchange?: () => void;
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
    close() { this.readyState = 3; }
    receive(payload: object, event = "sendToPropertyInspector") { this.onmessage?.({ data: JSON.stringify({ event, payload }) }); }
  }
  const window: Record<string, any> = {};
  const context = vm.createContext({ window, document: { getElementById: element }, Option, WebSocket: Socket, TextEncoder });
  vm.runInContext(await readFile("com.joeblau.stream-studio.sdPlugin/ui/command.js", "utf8"), context);
  window.connectElgatoStreamDeckSocket(12345, "key", "registerPropertyInspector", "{}",
    JSON.stringify({ action: "com.joeblau.stream-studio.command", payload: { settings: {} } }));
  peer!.onopen?.();
  return { element, peer: peer!, reconnect: () => {
    window.connectElgatoStreamDeckSocket(12345, "key", "registerPropertyInspector", "{}",
      JSON.stringify({ action: "com.joeblau.stream-studio.command", payload: { settings: {} } }));
    peer!.onopen?.(); return peer!;
  } };
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

test("inspector live resource selectors retain UUID bindings across filters, rename and deletion", async () => {
  const { element, peer } = await inspector();
  const selected = "destination.stable.event.live.endRemote";
  const settings = { commandID: selected, projectID: "project" };
  const commands = [
    { id: selected, title: "Finish Opening Event", category: "Destinations", available: true, requiresConfirmation: true, target: { kind: "destination", id: "stable", name: "Opening" } },
    { id: "scene.scene-a.select", title: "Opening", category: "Scenes", available: true },
    { id: "scene.scene-a.layer.layer-a.source.camera-a.select", title: "Face Camera", category: "Camera / PIP", available: true },
    { id: "overlay.logo.show", title: "Logo", category: "Overlays", available: false },
    { id: "interview.slot.slot-a.admit", title: "Guest Alice", category: "Guests", available: true },
  ];
  peer.receive({ status: "Connected", projectID: "project", settings, commands });
  assert.equal(element("confirmation").hidden, false);
  element("resource-type").value = "source"; element("resource-type").onchange?.();
  assert.deepEqual(element("command").children.map(c => c.value), ["", commands[2].id, selected]);
  assert.equal(element("command").value, selected);
  assert.match(element("binding").textContent, /destination\.stable/);
  peer.receive({ status: "Connected", projectID: "project", settings, commands: commands.map(c => c.id === selected ? { ...c, title: "Finish Renamed Event" } : c) });
  assert.equal(element("command").children.at(-1)?.textContent, "Finish Renamed Event");
  peer.receive({ status: "Connected", projectID: "project", settings, commands: commands.filter(c => c.id !== selected) });
  assert.equal(element("command").value, selected);
  assert.match(element("availability").textContent, /Missing resource/);
  assert.equal(element("confirmation").hidden, true);
});

test("inspector validates numeric and UTF-8 arguments before crossing the plugin boundary", async () => {
  const { element, peer } = await inspector();
  function bind(command: object, field: string, value: string, button: string, mode = "key") {
    peer.receive({ status: "Connected", projectID: "project", settings: { commandID: "target", projectID: "project" }, mode,
      commands: [{ id: "target", title: "Target", category: "Test", available: true, ...command }] });
    element(field).value = value;
    const count = peer.sent.length;
    element(button).onclick?.();
    assert.equal(peer.sent.length, count);
  }
  bind({ kind: "value" }, "value", "", "apply-value");
  assert.match(element("error").textContent, /Gain/);
  bind({ kind: "value" }, "value", "201", "apply-value");
  bind({ argument: "page" }, "page", "1.5", "apply-page");
  assert.match(element("error").textContent, /whole number/);
  bind({}, "step", "Infinity", "apply-step", "level");
  assert.match(element("error").textContent, /Dial step/);
  bind({ argument: "text" }, "marker", "👩🏽‍🚀".repeat(60), "apply-marker");
  assert.match(element("error").textContent, /UTF-8/);
  peer.receive({ status: "Connected", projectID: "project", settings: { commandID: "target", projectID: "project" },
    commands: [{ id: "target", title: "Target", category: "Test", argument: "text", available: true }] });
  assert.match(element("error").textContent, /UTF-8/, "Live snapshots must not erase a readable validation error");
  element("marker").value = "Chapter 1"; element("apply-marker").onclick?.();
  assert.equal(peer.sent.at(-1).payload.text, "Chapter 1");
  peer.onclose?.();
  const count = peer.sent.length; element("apply-marker").onclick?.();
  assert.equal(peer.sent.length, count);
  assert.match(element("error").textContent, /Connect to Stream Studio/);
});

test("inspector ignores late socket callbacks after a new registration and binds display-only feedback", async () => {
  const { element, peer, reconnect } = await inspector();
  const next = reconnect();
  const settings = { commandID: "audience.viewers", projectID: "project" };
  next.receive({ status: "Connected", projectID: "project", settings,
    commands: [{ id: settings.commandID, title: "Viewers", category: "Audience", kind: "feedback", available: true }] });
  peer.onclose?.(); peer.receive({ status: "Disconnected", commands: [] });
  assert.equal(element("status").textContent, "Connected");
  assert.match(element("availability").textContent, /Display only/);
  assert.equal(element("command").value, settings.commandID);
  element("command").onchange?.();
  assert.deepEqual(next.sent.at(-1).payload, { operation: "bind", commandID: settings.commandID });
});

test("inspector chooses bounded typed source UUIDs without Cartesian bindings or stale authority", async () => {
  const { element, peer } = await inspector();
  const camera = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", screen = "11111111-2222-3333-4444-555555555555";
  const id = "scene.scene-a.layer.layer-a.source.select";
  const commands = [
    { id, title: "Set Camera", category: "Camera / PIP", argument: "source", sourceKind: "camera", available: true, authority: "do-not-store" },
    { id: `source.${camera}.effects.bypass`, title: "Bypass Shared Source Effects — Camera One", category: "Shared Sources", sourceKind: "camera", available: true },
    { id: `source.${screen}.effects.bypass`, title: "Bypass Shared Source Effects — Screen One", category: "Shared Sources", sourceKind: "screen", available: true },
  ];
  const state = { status: "Connected", projectID: "project", settings: { commandID: id, projectID: "project", text: "deleted-source" }, commands };
  peer.receive(state);
  assert.equal(element("source-options").hidden, false);
  assert.deepEqual(element("source").children.map(c => c.value), ["", camera, "deleted-source"]);
  assert.match(element("availability").textContent, /Missing or different-kind source/);
  const before = peer.sent.length; element("apply-source").onclick?.(); assert.equal(peer.sent.length, before);
  element("source").value = camera; element("source").onchange?.();
  peer.receive({ ...state, commands: commands.map(c => c.sourceKind === "camera" && c.id !== id ? { ...c, title: "Bypass Shared Source Effects — Renamed Camera" } : c) });
  assert.equal(element("source").value, camera);
  assert.equal(element("source").children[1].textContent, "Renamed Camera");
  element("apply-source").onclick?.();
  assert.deepEqual(peer.sent.at(-1).payload, { operation: "bind", commandID: id, text: camera });
  peer.receive({ ...state, commands: commands.map(c => c.id === `source.${camera}.effects.bypass` ? { ...c, sourceAvailable: false } : c) });
  assert.equal(element("source").value, camera);
  assert.equal(element("source").children[1].disabled, true);
  assert.match(element("availability").textContent, /Source disconnected/);
  const disconnectedCount = peer.sent.length; element("apply-source").onclick?.(); assert.equal(peer.sent.length, disconnectedCount);
  peer.receive({ ...state, commands: commands.filter(c => c.id !== `source.${camera}.effects.bypass`) });
  assert.equal(element("source").value, camera);
  const count = peer.sent.length; element("apply-source").onclick?.(); assert.equal(peer.sent.length, count);
  assert.match(element("error").textContent, /configured source/);
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
