import test from "node:test";
import assert from "node:assert/strict";
import net from "node:net";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { spawn } from "node:child_process";
import { mkdtemp, mkdir, copyFile, writeFile, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { createRequire } from "node:module";
import { build } from "esbuild";
import type { Capability, Snapshot } from "../src/studio-client.ts";
const { WebSocketServer } = createRequire(import.meta.url)("ws");
async function waitUntil(check: () => boolean): Promise<void> {
  for (let i = 0; i < 500; ++i) { if (check()) return; await new Promise(resolve => setTimeout(resolve, 10)); }
  assert.fail("SDK lifecycle test timed out");
}

const configurations = [
  { scenario: "scene", label: "15-key", type: 0, columns: 5, rows: 3 },
  { scenario: "destination", label: "15-key", type: 0, columns: 5, rows: 3 },
  { scenario: "scene", label: "Mobile free six-key", type: 3, columns: 3, rows: 2 },
  { scenario: "scene", label: "Pedal three-key", type: 5, columns: 3, rows: 1 },
] as const;
for (const configuration of configurations) test(`bundled SDK ${configuration.label} ${configuration.scenario} routes independent instances and preserves bindings across plugin and owned host restarts`, async () => {
  const { scenario } = configuration;
  const directory = await mkdtemp(resolve(tmpdir(), "stream-deck-test-"));
  const projectID = randomUUID(), sceneID = randomUUID();
  const commandID = scenario === "scene" ? `scene.${sceneID}.select` : `destination.${sceneID}.event.${"e".repeat(64)}.start`;
  const secondCommandID = scenario === "scene" ? commandID : `destination.${sceneID}.event.${"e".repeat(64)}.endRemote`;
  const dispatched: string[] = [];
  const state: Snapshot = { projectID, revision: 1, stream: "idle", recording: "paused", preview: "active", pendingStagedEdits: false,
    stagedSceneID: sceneID, layerVisibility: {}, macroProgress: { phase: "idle", stepIndex: 0, totalSteps: 0, message: "" } };
  if (scenario === "destination") state.transport = { destinations: [{ id: sceneID, name: "Opening", state: "idle", eventKey: "e".repeat(64), endingPending: false, confirmationPending: false }], confirmationPending: false, endingPending: false };
  const commands: Capability[] = [...new Set([commandID, secondCommandID])].map(id => ({ id, title: "Opening", category: scenario === "scene" ? "Scenes" : "Destinations", available: true, requiresConfirmation: id.endsWith(".endRemote") }));
  const nativePeers = new Map<net.Socket, string>();
  let connections = 0, executions = 0, dropNextAcknowledgement = false;
  const mutations: any[] = [];
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
        if (request.type === "subscribe" || request.type === "snapshot") send("snapshot", { snapshot: state });
        if (request.type === "capabilities") send("capabilities", { commands, totalCommands: commands.length });
        if (request.type === "command") {
          mutations.push(request); ++executions; dispatched.push(request.commandID);
          if (request.commandID.endsWith(".endRemote")) { state.transport!.destinations[0].confirmationPending = true; state.transport!.confirmationPending = true; ++state.revision; }
          if (dropNextAcknowledgement) { dropNextAcknowledgement = false; socket.destroy(); }
          else send("result", { result: { succeeded: true }, snapshot: state });
        }
      }
    });
  });
  native.listen(0, "127.0.0.1"); await once(native, "listening");
  const pairing = { version: 1, clientID: randomUUID(), token: "a".repeat(64), host: "127.0.0.1", port: (native.address() as net.AddressInfo).port };
  const sd = new WebSocketServer({ port: 0, host: "127.0.0.1" }); await once(sd, "listening");
  const received: any[] = [];
  const settings = new Map<string, { commandID: string; projectID?: string }>([ ["key-a", { commandID, projectID }], ["key-b", { commandID: secondCommandID, projectID }] ]);
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
      devices: ["device-a", "device-b"].map(id => ({ id, name: id, type: configuration.type, size: { columns: configuration.columns, rows: configuration.rows } })), plugin: { version: "0.1.0", uuid: "com.joeblau.stream-studio" } };
    async function launch() {
      const registered = received.filter(message => message.event === "registerPlugin").length;
      child = spawn(process.execPath, [resolve(directory, "bin/plugin.js"), "-port", String(sd.address().port), "-pluginUUID", "plugin-instance", "-registerEvent", "registerPlugin", "-info", JSON.stringify(info)],
        { cwd: directory, stdio: ["ignore", "pipe", "pipe"] });
      child.stdout?.on("data", data => { childOutput += data.toString(); }); child.stderr?.on("data", data => { childOutput += data.toString(); });
      await waitUntil(() => received.filter(message => message.event === "registerPlugin").length > registered);
    }
    await launch();
    if (configuration.type === 3 || configuration.type === 5) {
      // Generic starter profiles intentionally contain no projectID. Even a
      // configured/persisted command cannot run before an explicit live rebind.
      settings.set("key-a", { commandID });
      send("willAppear", "key-a"); send("propertyInspectorDidAppear", "key-a");
      await waitUntil(() => received.some(message => message.event === "sendToPropertyInspector"
        && message.payload.status === "Connected" && message.payload.commands?.some((item: Capability) => item.id === commandID)));
      send("keyDown", "key-a");
      await waitUntil(() => received.some(message => message.event === "showAlert" && message.context === "key-a"));
      assert.equal(executions, 0, "An unbound starter must not mutate the current project");
      send("keyUp", "key-a"); send("sendToPlugin", "key-a", undefined, { operation: "bind", commandID });
      await waitUntil(() => settings.get("key-a")?.projectID === projectID);
    }
    send("willAppear", "key-a"); send("willAppear", "key-b");
    await waitUntil(() => received.filter(message => message.event === "setTitle" && message.payload.title === "Opening").length >= 2);
    assert.equal(connections, 1, "All devices share one native session");
    assert.deepEqual(new Set(received.filter(message => message.event === "setTitle" && message.payload.title === "Opening").map(message => message.context)), new Set(["key-a", "key-b"]));
    send("keyDown", "key-a"); send("keyDown", "key-a"); send("keyDown", "key-b");
    await waitUntil(() => executions === 2); await new Promise(resolve => setTimeout(resolve, 100));
    assert.equal(executions, 2, "Held repeat is suppressed independently for each device");
    assert.deepEqual(dispatched, [commandID, secondCommandID], "SDK retargeted explicit multi-action variants");
    if (scenario === "destination") {
      await waitUntil(() => received.some(message => message.event === "setImage" && message.context === "key-b"
        && Buffer.from(message.payload.image.split(",")[1], "base64").toString().includes("CONFIRM IN STUDIO")));
      assert.equal(state.transport!.destinations[0].remoteEnd, undefined, "Accepted review request must not invent ended receipt");
    }
    send("keyUp", "key-a"); send("keyUp", "key-b"); send("keyDown", "key-a");
    await waitUntil(() => executions === 3);
    send("propertyInspectorDidAppear", "key-b");
    await waitUntil(() => received.some(message => message.event === "sendToPropertyInspector" && message.payload.status === "Connected"));
    send("sendToPlugin", "key-b", undefined, { operation: "bind", commandID });
    await waitUntil(() => received.some(message => message.event === "setSettings"));
    const persisted = received.find(message => message.event === "setSettings").payload;
    assert.deepEqual(persisted, { commandID, projectID }); assert.equal(JSON.stringify(persisted).includes(pairing.token), false);
    for (const command of commands) command.title = "Renamed Opening"; ++state.revision;
    for (const [peer, sessionID] of nativePeers) peer.write(JSON.stringify({ version: 1, type: "event", sessionID, snapshot: state }) + "\n");
    await waitUntil(() => received.filter(message => message.event === "setTitle" && message.payload.title === "Renamed Opening").length >= 2);
    // Persist the host-owned JSON settings, lose an acknowledgement, then stop
    // the real plugin process and restart the owned native TCP listener. A new
    // SDK process must hydrate the binding without replaying that mutation.
    await writeFile(resolve(directory, "saved-bindings.json"), JSON.stringify([...settings]));
    const savedBindings = await readFile(resolve(directory, "saved-bindings.json"), "utf8");
    const beforeLostAcknowledgement = executions;
    send("keyUp", "key-a"); dropNextAcknowledgement = true; send("keyDown", "key-a");
    await waitUntil(() => executions === beforeLostAcknowledgement + 1);
    child!.kill("SIGTERM"); await once(child!, "exit");
    await waitUntil(() => nativePeers.size === 0);
    await new Promise<void>(resolve => native.close(() => resolve()));
    state.revision = 1; // Fresh host incarnation is permitted to reset revision.
    native.listen(pairing.port, "127.0.0.1"); await once(native, "listening");
    settings.clear();
    for (const [context, binding] of JSON.parse(savedBindings)) settings.set(context, binding);
    const receivedBeforeRestart = received.length;
    await launch(); send("willAppear", "key-a"); send("willAppear", "key-b");
    await waitUntil(() => new Set(received.slice(receivedBeforeRestart).filter(message => message.event === "setTitle"
      && message.payload.title === "Renamed Opening").map(message => message.context)).size === 2);
    await new Promise(resolve => setTimeout(resolve, 150));
    assert.equal(executions, beforeLostAcknowledgement + 1, "Plugin restart replayed an interrupted mutation");
    assert.equal(JSON.stringify([...settings]), savedBindings, "Relaunch rewrote stable bindings");
    send("keyDown", "key-a"); await waitUntil(() => executions === beforeLostAcknowledgement + 2);
    assert.equal(dispatched.at(-1), commandID);
    send("keyUp", "key-a");
    // The actual bundled SDK routes new interaction IDs through the same
    // shared client; the controlled native peer supplies no live account.
    const slot = randomUUID(), guestID = `guest.slot.${slot}.mute`, profileProject = randomUUID(), profileID = randomUUID();
    const showID = `show.${profileProject}.profile.${profileID}.select`;
    const presetID = `chat.preset.${randomUUID()}.youtube.send`;
    commands.push({id:guestID,title:"Mute Ada",category:"Guests",available:true,authority:"c".repeat(64),bindingIntent:"configuredSlot"},
      {id:showID,title:"Select saved profile",category:"Show Profiles",available:true,scope:"studio",authority:"owned-runtime"},
      {id:presetID,title:"Send Welcome",category:"Chat Presets",available:true,authority:"d".repeat(64),bindingIntent:"currentConnection"},
      {id:"audience.viewers",title:"Actual provider readings",category:"Audience",available:true,kind:"feedback"});
    state.guestSlots=[{id:slot,name:"Ada",media:"ready",muted:false,solo:false}];
    state.audience={observedAt:Date.now()/1000,health:"idle",readings:[],presetDelivery:{}};
    state.showProfiles={projectID:profileProject,profileID:randomUUID(),canSelect:true};
    const publish=()=>{++state.revision;for(const [peer,sessionID] of nativePeers)peer.write(JSON.stringify({version:1,type:"event",sessionID,snapshot:state})+"\n");};
    publish(); await new Promise(resolve=>setTimeout(resolve,650));
    const bind=async(context:string,id:string)=>{
      send("sendToPlugin",context,undefined,{operation:"bind",commandID:id});
      await waitUntil(()=>settings.get(context)?.commandID===id);send("keyUp",context);
    };
    await bind("key-a",guestID);await bind("key-b",guestID);
    const beforeGuests=executions;send("keyDown","key-a");send("keyDown","key-b");
    await waitUntil(()=>executions===beforeGuests+2);
    assert(mutations.filter(request=>request.commandID===guestID).every(request=>request.authority==="c".repeat(64)));
    await bind("key-b",presetID);send("keyDown","key-b");await waitUntil(()=>mutations.some(request=>request.commandID===presetID));
    assert.equal(mutations.find(request=>request.commandID===presetID).authority,"d".repeat(64));
    await bind("key-b","audience.viewers");const beforeFeedback=executions;send("keyDown","key-b");
    await new Promise(resolve=>setTimeout(resolve,100));assert.equal(executions,beforeFeedback,"Feedback-only SDK key must not issue a mutation");
    await bind("key-b",showID);const savedSource=settings.get("key-b")!.projectID;
    state.projectID=randomUUID();state.showProfiles.profileID=profileID;publish();await new Promise(resolve=>setTimeout(resolve,650));
    send("keyDown","key-b");await waitUntil(()=>mutations.some(request=>request.commandID===showID));
    assert.equal(settings.get("key-b")!.projectID,savedSource,"Profile requests never rewrite a saved binding's original context");
    assert(received.filter(message=>message.event==="setSettings").every(message=>!["authority","scope","bindingIntent"].some(key=>key in message.payload)),"Only stable binding settings persist");
    state.projectID=projectID;publish();await new Promise(resolve=>setTimeout(resolve,650));
    await bind("key-a",commandID);await bind("key-b",commandID);
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
    assert.equal(child!.exitCode, null, childOutput); assert.equal(childOutput.includes(pairing.token), false, "Pairing credentials never reach SDK logs");
  } finally {
    if (child && child.exitCode === null) { child.kill("SIGTERM"); await once(child, "exit"); }
    for (const peer of nativePeers.keys()) peer.destroy();
    sdPeer?.terminate(); await new Promise<void>(resolve => sd.close(() => resolve()));
    await new Promise<void>(resolve => native.close(() => resolve()));
    await rm(directory, { recursive: true, force: true });
  }
});
