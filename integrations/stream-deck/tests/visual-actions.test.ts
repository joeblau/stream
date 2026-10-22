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
test("bundled SDK visual keys send explicit source UUIDs and retain multi-key tally through rename/delete/disconnect/reconnect", async () => {
  const directory = await mkdtemp(resolve(tmpdir(), "stream-plus-test-"));
  const projectID = randomUUID(), sceneA = randomUUID(), sceneB = randomUUID(), overlayA = randomUUID(), overlayB = randomUUID();
  const gainID = "audio.microphone.gain", muteID = "audio.microphone.mute";
  const visualLayer=randomUUID(), sourceA=randomUUID(), sourceB=randomUUID();
  const visualPrefix=`scene.${sceneA}.layer.${visualLayer}`, visualID=visualPrefix+".source.select";
  const selectA = `scene.${sceneA}.select`, selectB = `scene.${sceneB}.select`;
  const overlaySelectA = `overlay.${overlayA}.visibility`, overlaySelectB = `overlay.${overlayB}.visibility`;
  const state: Snapshot = { projectID, revision: 1, stream: "idle", recording: "paused", preview: "active", pendingStagedEdits: false,
    stagedSceneID: sceneA, layerVisibility: {}, overlayVisibility: { [overlayA]: false, [overlayB]: false }, values: { [gainID]: 0.5 }, mutes: { [gainID]: false }, macroProgress: { phase: "idle", stepIndex: 0, totalSteps: 0, message: "" } };
  const commands: Capability[] = [{ id: gainID, title: "Microphone Gain", category: "Audio Levels", available: true, kind: "value" },
    { id: muteID, title: "Mute Microphone", category: "Audio", available: true, kind: "command" },
    { id: selectA, title: "Opening", category: "Scenes", available: true }, { id: selectB, title: "Interview", category: "Scenes", available: true },
    { id: overlaySelectA, title: "Show Global Overlay Logo", category: "Global Overlays", available: true },
    { id: overlaySelectB, title: "Show Global Overlay Lower Third", category: "Global Overlays", available: true }];
  state.visuals = {[visualPrefix]:{previewVisible:true,programVisible:true,sourceID:sourceA,programSourceID:sourceA}};
  commands.push({id:visualID,title:"Select Camera for PIP",category:"Camera / PIP",available:true,argument:"source",sourceKind:"camera"},
    {id:`source.${sourceA}.effects.bypass`,title:"Bypass Shared Source Effects — A",category:"Shared Sources",available:true,sourceKind:"camera",sourceAvailable:true},
    {id:`source.${sourceB}.effects.bypass`,title:"Bypass Shared Source Effects — B",category:"Shared Sources",available:true,sourceKind:"camera",sourceAvailable:true});
  const peers = new Map<net.Socket, string>();
  let visualRequests=0;
  let valueRequests = 0, muteRequests = 0, selections = 0, overlayRequests = 0, dropNext = false;
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
          if (request.commandID === overlaySelectA || request.commandID === overlaySelectB) { ++overlayRequests; const id = request.commandID === overlaySelectA ? overlayA : overlayB; state.overlayVisibility![id] = !state.overlayVisibility![id]; }
          if(request.commandID===visualID){++visualRequests;assert.equal(request.text,sourceB);state.visuals![visualPrefix]!.sourceID=request.text;}
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
  const received: any[] = [], settings = new Map<string, object>([["dial-a", { commandID: gainID, projectID, step: 0.01 }], ["dial-b", { commandID: gainID, projectID, step: 0.01 }], ["selector", { commandID: selectA, projectID, category: "Scenes" }], ["selector-overlay", { commandID: overlaySelectA, projectID, category: "Overlays" }]]);
  settings.set("visual-a",{commandID:visualID,projectID,text:sourceB});settings.set("visual-b",{commandID:visualID,projectID,text:sourceB});
  let sdPeer: any, child: ReturnType<typeof spawn> | undefined, output = "";
  const send = (event: string, context: string, payload: object = {}) => sdPeer.send(JSON.stringify({ event, context, action: `com.joeblau.stream-studio.${context.startsWith("visual") ? "command" : context.startsWith("selector") ? "selector" : "level"}`, device: context === "dial-b" ? "plus-b" : "plus-a",
    payload: { controller: context.startsWith("visual") ? "Keypad" : "Encoder", coordinates: { column: context === "dial-b" ? 1 : 0, row: 0 }, settings: settings.get(context), ...payload } }));
  sd.on("connection", (peer: any) => {
    sdPeer = peer; peer.on("message", (data: Buffer) => {
      const message = JSON.parse(data.toString()); received.push(message);
      if (message.event === "getSettings") send("didReceiveSettings", message.context);
      if (message.event === "setSettings") { settings.set(message.context, message.payload); send("didReceiveSettings", message.context); }
    });
  });
  const imageHas=(context:string,text:string)=>received.some(message=>message.event==="setImage"&&message.context===context&&Buffer.from(message.payload.image.split(",")[1],"base64").toString().includes(text));
  const publish = () => { ++state.revision; for (const [peer, sessionID] of peers) peer.write(JSON.stringify({ version: 1, type: "event", sessionID, snapshot: state }) + "\n"); };
  try {
    await mkdir(resolve(directory, "bin")); await copyFile("com.joeblau.stream-studio.sdPlugin/manifest.json", resolve(directory, "manifest.json"));
    await writeFile(resolve(directory, "package.json"), '{"type":"module"}');
    await build({ entryPoints: ["src/plugin.ts"], bundle: true, platform: "node", format: "esm", target: "node24", outfile: resolve(directory, "bin/plugin.js"), banner: { js: 'import {createRequire} from "node:module"; const require = createRequire(import.meta.url);' } });
    await writeFile(resolve(directory, "bin/keychain-helper"), `#!/usr/bin/env node\nif (process.argv[2] === "read") process.stdout.write(${JSON.stringify(JSON.stringify(pairing))});\n`, { mode: 0o755 });
    const info = { application: { version: "7.1.0", platform: "mac", platformVersion: "15.0", language: "en", font: "Arial" }, devices: ["plus-a", "plus-b"].map(id => ({ id, name: id, type: 7, size: { columns: 4, rows: 2 } })), plugin: { version: "0.1.0", uuid: "com.joeblau.stream-studio" } };
    child = spawn(process.execPath, [resolve(directory, "bin/plugin.js"), "-port", String(sd.address().port), "-pluginUUID", "fixture", "-registerEvent", "registerPlugin", "-info", JSON.stringify(info)], { cwd: directory, stdio: ["ignore", "pipe", "pipe"] });
    child.stdout?.on("data", data => { output += data.toString(); }); child.stderr?.on("data", data => { output += data.toString(); });
    await until(() => received.some(message => message.event === "registerPlugin"));
    send("willAppear", "dial-a"); send("willAppear", "dial-b"); send("willAppear", "selector"); send("willAppear", "selector-overlay");
    await until(() => received.filter(message => message.event === "setFeedback" && message.payload.title === "Microphone Gain").length >= 2);
    send("dialRotate", "dial-a", { ticks: 3, pressed: false }); send("dialRotate", "dial-a", { ticks: 2, pressed: false }); send("dialRotate", "dial-b", { ticks: -2, pressed: false });
    await until(() => valueRequests === 2); assert.ok(Math.abs(state.values![gainID]! - 0.53) < 0.00001);
    await until(() => received.some(message => message.event === "setFeedback" && message.payload.value === "106%"));
    send("dialDown", "dial-a"); send("dialDown", "dial-a"); await until(() => muteRequests === 1);
    send("dialUp", "dial-a"); send("touchTap", "dial-b", { hold: false, tapPos: [100, 50] }); await until(() => muteRequests === 2);
    send("touchTap", "dial-a", { hold: true, tapPos: [100, 50] }); await until(() => valueRequests === 3); assert.equal(state.values![gainID], 0.5);
    send("dialRotate", "selector", { ticks: 1, pressed: false }); await until(() => (settings.get("selector") as any).commandID === selectB); assert.equal(selections, 0);
    send("dialDown", "selector"); send("dialDown", "selector"); await until(() => selections === 1); assert.equal(state.stagedSceneID, sceneB);
    send("dialRotate", "selector-overlay", { ticks: 1, pressed: false });
    await until(() => (settings.get("selector-overlay") as any).commandID === overlaySelectB);
    assert.equal(overlayRequests, 0, "Overlay browsing does not mutate global visibility");
    send("touchTap", "selector-overlay", { hold: false, tapPos: [100, 50] });
    await until(() => overlayRequests === 1); assert.equal(state.overlayVisibility![overlayB], true);
    await until(() => received.some(message => message.context === "selector-overlay" && message.event === "setFeedback" && message.payload.value === "GLOBAL ON"));
    commands[3]!.title = "Renamed Interview"; publish(); await until(() => received.some(message => message.event === "setFeedback" && message.payload.title === "Renamed Interview"));
    commands.splice(3, 1); publish(); await until(() => received.some(message => message.context === "selector" && message.event === "setFeedback" && message.payload.title === "Missing\nResource"));
    send("dialUp", "selector"); send("dialDown", "selector"); await new Promise(resolve => setTimeout(resolve, 100)); assert.equal(selections, 1);
    dropNext = true; send("dialRotate", "dial-a", { ticks: 1, pressed: false }); await until(() => valueRequests === 4);
    await until(() => peers.size === 1); await new Promise(resolve => setTimeout(resolve, 300)); assert.equal(valueRequests, 4, "A lost acknowledgement never replays numeric deltas");
    send("dialRotate", "dial-b", { ticks: 4, pressed: false }); send("willDisappear", "dial-b"); await new Promise(resolve => setTimeout(resolve, 200)); assert.equal(valueRequests, 4, "Page teardown discards queued rotation");
    send("willAppear","visual-a");send("willAppear","visual-b");
    await until(()=>imageHas("visual-a",">READY<")&&imageHas("visual-b",">READY<"));
    send("keyDown","visual-a");send("keyDown","visual-a");await until(()=>visualRequests===1);send("keyUp","visual-a");
    await until(()=>imageHas("visual-a",">PVW<")&&imageHas("visual-b",">PVW<"));
    assert.equal(state.visuals![visualPrefix]!.programSourceID,sourceA,"source changes must not invent Take");
    commands.find(value=>value.id===visualID)!.title="Select Camera for Renamed PIP";publish();
    await until(()=>received.some(message=>message.context==="visual-b"&&message.event==="setTitle"&&message.payload.title==="Select Camera for Renamed PIP"));
    dropNext=true;send("keyDown","visual-b");await until(()=>visualRequests===2);send("keyUp","visual-b");
    await until(()=>peers.size===1);await new Promise(resolve=>setTimeout(resolve,1300));assert.equal(visualRequests,2,"lost source acknowledgment cannot replay");
    commands.find(value=>value.id===`source.${sourceB}.effects.bypass`)!.sourceAvailable=false;publish();
    await until(()=>imageHas("visual-b",">UNAVAILABLE<"));
    commands.splice(commands.findIndex(value=>value.id===`source.${sourceB}.effects.bypass`),1);publish();
    await until(()=>received.some(message=>message.context==="visual-b"&&message.event==="setTitle"&&message.payload.title==="Missing\nSource"));
    commands.splice(commands.findIndex(value=>value.id===visualID),1);publish();
    await until(()=>received.some(message=>message.context==="visual-a"&&message.event==="setTitle"&&message.payload.title==="Missing\nResource"));
    send("keyDown","visual-a");send("keyUp","visual-a");await new Promise(resolve=>setTimeout(resolve,100));assert.equal(visualRequests,2);
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

test("visual receipts preserve on-air tally independently of locks, source identity and global overlay masks", async()=>{
  const {feedback}=await import("../src/feedback.ts");
  const scene=randomUUID(),layer=randomUUID(),group=randomUUID(),overlay=randomUUID(),sourceA=randomUUID(),sourceB=randomUUID();
  const prefix=`scene.${scene}.layer.${layer}`,groupPrefix=`scene.${scene}.group.${group}`;
  const state:Snapshot={projectID:"show",revision:1,stream:"idle",recording:"idle",preview:"active",pendingStagedEdits:true,layerVisibility:{},
    macroProgress:{phase:"idle",stepIndex:0,totalSteps:0,message:""},visuals:{
      [prefix]:{previewVisible:false,programVisible:true,sourceID:sourceB,programSourceID:sourceA,bypassed:true,programBypassed:false},
      [groupPrefix]:{previewVisible:false,programVisible:true},[`overlay.${overlay}`]:{previewVisible:true,programVisible:false}}};
  const commands=new Map<string,Capability>();
  const bind=(id:string,text?:string)=>{commands.set(id,{id,title:"Visual resource",category:"Layers",available:true});return{commandID:id,projectID:"show",...(text?{text}:{})};};
  for(const id of[sourceA,sourceB])commands.set(`source.${id}.effects.bypass`,{id:`source.${id}.effects.bypass`,title:"Shared source",category:"Shared Sources",available:true,sourceKind:"camera",sourceAvailable:true});
  assert.equal(feedback(bind(prefix+".source.select",sourceA),"Connected",state,commands).badge,"PGM");
  assert.equal(feedback(bind(prefix+".source.select",sourceB),"Connected",state,commands).badge,"SELECTED");
  assert.equal(feedback(bind(prefix+".pip.toggle"),"Connected",state,commands).badge,"PGM");
  assert.equal(feedback(bind(groupPrefix+".hide"),"Connected",state,commands).badge,"PGM");
  assert.equal(feedback(bind(`overlay.${overlay}.visibility`),"Connected",state,commands).badge,"PVW");
  assert.equal(feedback(bind(prefix+".effects.bypass"),"Connected",state,commands).badge,"BYPASSED PVW");
  state.visuals![prefix]={programVisible:true,programBypassed:true};
  assert.equal(feedback(bind(prefix+".effects.bypass"),"Connected",state,commands).badge,"BYPASSED");
  state.visuals![prefix]={programVisible:true,programBypassed:false};
  assert.equal(feedback(bind(prefix+".effects.bypass"),"Connected",state,commands).badge,"EFFECTS ON");
  state.receiptsPending=true;
  assert.equal(feedback(bind(prefix+".effects.bypass"),"Connected",state,commands).title,"Updating\nVisuals");
  state.receiptsPending=false;
  state.visuals![prefix]={programVisible:true,programSourceID:sourceA};
  const selector=bind(prefix+".source.select",sourceA);commands.get(`source.${sourceA}.effects.bypass`)!.sourceAvailable=false;
  assert.equal(feedback(selector,"Connected",state,commands).unavailable,true);assert.equal(feedback(selector,"Connected",state,commands).badge,"PGM");
  commands.delete(`source.${sourceA}.effects.bypass`);assert.equal(feedback(selector,"Connected",state,commands).title,"Missing\nSource");
});
