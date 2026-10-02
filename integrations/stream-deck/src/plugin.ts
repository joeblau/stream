import streamDeck, { action, SingletonAction, type WillAppearEvent, type WillDisappearEvent,
  type DidReceiveSettingsEvent, type KeyDownEvent, type KeyUpEvent, type SendToPluginEvent,
  type PropertyInspectorDidAppearEvent, type KeyAction, type DialAction, type DialRotateEvent,
  type DialDownEvent, type DialUpEvent, type TouchTapEvent } from "@elgato/streamdeck";
import type { JsonValue } from "@elgato/utils";
import { execFile } from "node:child_process";
import { StudioClient } from "./studio-client.js";
import { loadPairing, savePairing, forgetPairing } from "./credentials.js";
import { feedback, keyImage } from "./feedback.js";

type Settings = { commandID?: string; projectID?: string; value?: number; page?: number; text?: string; step?: number; category?: string };
const client = new StudioClient();
streamDeck.logger.setLevel("warn"); // The property inspector can carry a pairing token; trace is forbidden.

@action({ UUID: "com.joeblau.stream-studio.command" })
class StudioCommandAction extends SingletonAction<Settings> {
  private bindings = new Map<string, { action: KeyAction<Settings>; settings: Settings }>();
  private held = new Set<string>();
  private lastRender = new Map<string, string>();
  constructor() {
    super(); client.on("change", () => { void this.renderAll().catch(() => {}); void this.inspector().catch(() => {}); });
  }
  override async onWillAppear(ev: WillAppearEvent<Settings>): Promise<void> {
    if (!ev.action.isKey()) return;
    this.bindings.set(ev.action.id, { action: ev.action, settings: ev.payload.settings });
    await this.renderAll();
  }
  override onWillDisappear(ev: WillDisappearEvent<Settings>): void {
    this.bindings.delete(ev.action.id); this.held.delete(ev.action.id); this.lastRender.delete(ev.action.id);
  }
  deviceDisconnected(deviceID: string): void {
    for (const [id, binding] of this.bindings) if (binding.action.device.id === deviceID) {
      this.bindings.delete(id); this.held.delete(id); this.lastRender.delete(id);
    }
  }
  override async onDidReceiveSettings(ev: DidReceiveSettingsEvent<Settings>): Promise<void> {
    if (ev.action.isKey()) this.bindings.set(ev.action.id, { action: ev.action, settings: ev.payload.settings });
    await this.renderAll(); await this.inspector();
  }
  override async onKeyDown(ev: KeyDownEvent<Settings>): Promise<void> {
    if (this.held.has(ev.action.id)) return;
    this.held.add(ev.action.id);
    try {
      const settings = ev.payload.settings;
      if (!settings.commandID || !settings.projectID) throw new Error("Choose a stable command in the property inspector.");
      const argument = settings.value !== undefined ? { value: settings.value } : settings.page !== undefined ? { page: settings.page } : settings.text ? { text: settings.text } : undefined;
      await client.execute(settings.commandID, settings.projectID, argument);
      // The studio's result/snapshot drives tally. A key press never sets LIVE.
      await this.renderAll();
    } catch (error) {
      await ev.action.showAlert();
      await streamDeck.ui.sendToPropertyInspector({ error: error instanceof Error ? error.message : "The command was rejected." });
    }
  }
  override onKeyUp(ev: KeyUpEvent<Settings>): void { this.held.delete(ev.action.id); }
  override async onPropertyInspectorDidAppear(_ev: PropertyInspectorDidAppearEvent<Settings>): Promise<void> { await this.inspector(); }
  override async onSendToPlugin(ev: SendToPluginEvent<JsonValue, Settings>): Promise<void> {
    const payload = ev.payload as { operation?: string; credentials?: unknown; commandID?: string; value?: number; page?: number; text?: string } | null;
    if (!payload) return;
    try {
      if (payload.operation === "pair") { client.configure(await savePairing(payload.credentials)); }
      if (payload.operation === "forget") { await forgetPairing(); client.forget(); }
      if (payload.operation === "refresh") { await client.refreshCatalog(); }
      if (payload.operation === "bind") {
        if (!payload.commandID || !client.snapshot || !client.capabilities.has(payload.commandID)) throw new Error("Select a command from the current studio catalog.");
        const command = client.capabilities.get(payload.commandID)!;
        if (command.kind === "value" && (payload.value === undefined || !Number.isFinite(payload.value) || payload.value < 0 || payload.value > 1)) throw new Error("Choose a normalized value from 0 to 1.");
        if (command.argument === "page" && (payload.page === undefined || !Number.isSafeInteger(payload.page) || payload.page < 0 || payload.page > 100000)) throw new Error("Choose a PDF page from 1 to 100001.");
        if (command.argument === "text" && payload.text && (!payload.text.trim() || Buffer.byteLength(payload.text) > 512)) throw new Error("Marker text needs 1–512 UTF-8 bytes.");
        await ev.action.setSettings({ commandID: payload.commandID, projectID: client.snapshot.projectID,
          ...(command.kind === "value" ? { value: payload.value! } : {}),
          ...(command.argument === "page" ? { page: payload.page! } : {}),
          ...(command.argument === "text" && payload.text ? { text: payload.text } : {}) });
      }
      await this.inspector();
    } catch (error) {
      await streamDeck.ui.sendToPropertyInspector({ error: error instanceof Error ? error.message : "The setting was rejected." });
    }
  }
  private async inspector(): Promise<void> {
    const active = streamDeck.ui.action;
    if (!active || active.manifestId !== this.manifestId) return;
    const settings = await active.getSettings();
    await streamDeck.ui.sendToPropertyInspector({ status: client.status, projectID: client.snapshot?.projectID ?? "",
      settings, mode: "key", commands: [...client.capabilities.values()] });
  }
  private async renderAll(): Promise<void> {
    await Promise.all([...this.bindings].map(async ([id, binding]) => {
      const value = feedback(binding.settings, client.status, client.snapshot, client.capabilities);
      const encoded = JSON.stringify(value);
      if (this.lastRender.get(id) === encoded) return;
      this.lastRender.set(id, encoded);
      await binding.action.setTitle(value.title.length > 45 ? value.title.slice(0, 42) + "…" : value.title);
      await binding.action.setImage(keyImage(value));
    }));
  }
}

type DialBinding = { action: DialAction<Settings>; settings: Settings; ticks: number; busy: boolean; timer?: NodeJS.Timeout; held: boolean; lastRender?: string };
function selectorCommands(category: string | undefined) {
  return [...client.capabilities.values()].filter(command => category === "Layers" ? /^scene\.[^.]+\.layer\.[^.]+\.visibility$/.test(command.id)
    : category === "Sound" ? /^sound\.[^.]+\.trigger$/.test(command.id) : /^scene\.[^.]+\.select$/.test(command.id));
}
async function dialInspector(manifestID: string | undefined, mode: "level" | "selector") {
  const active = streamDeck.ui.action;
  if (!active || active.manifestId !== manifestID) return;
  const settings = await active.getSettings() as Settings;
  const commands = mode === "level" ? [...client.capabilities.values()].filter(command => command.kind === "value") : selectorCommands(settings.category);
  await streamDeck.ui.sendToPropertyInspector({ status: client.status, projectID: client.snapshot?.projectID ?? "", settings, commands, mode });
}
async function configureDial(ev: SendToPluginEvent<JsonValue, Settings>, mode: "level" | "selector") {
  const payload = ev.payload as { operation?: string; credentials?: unknown; commandID?: string; category?: string; step?: number } | null;
  if (!payload) return;
  try {
    if (payload.operation === "pair") client.configure(await savePairing(payload.credentials));
    if (payload.operation === "forget") { await forgetPairing(); client.forget(); }
    if (payload.operation === "refresh") await client.refreshCatalog();
    if (payload.operation === "selector-category" && mode === "selector") {
      if (!["Scenes", "Layers", "Sound"].includes(payload.category ?? "")) throw new Error("Choose a supported selector category.");
      const settings = await ev.action.getSettings();
      // Changing category clears the old binding; selecting a resource is
      // the explicit step that binds the active project.
      await ev.action.setSettings({ category: payload.category!, ...(settings.projectID ? { projectID: settings.projectID } : {}) });
    }
    if (payload.operation === "bind") {
      const command = payload.commandID ? client.capabilities.get(payload.commandID) : undefined;
      if (!command || !client.snapshot || (mode === "level" && command.kind !== "value")) throw new Error("Choose a supported target from the current studio catalog.");
      const category = ["Scenes", "Layers", "Sound"].includes(payload.category ?? "") ? payload.category : "Scenes";
      if (mode === "selector" && !selectorCommands(category).some(candidate => candidate.id === command.id)) throw new Error("Choose a scene, layer, or sound from the selected category.");
      const step = payload.step ?? 0.01;
      if (!Number.isFinite(step) || step < 0.001 || step > 0.25) throw new Error("Dial step must be normalized from 0.001 to 0.25.");
      await ev.action.setSettings({ commandID: command.id, projectID: client.snapshot.projectID, ...(mode === "level" ? { step } : { category }) });
    }
    await dialInspector(ev.action.manifestId, mode);
  } catch (error) { await streamDeck.ui.sendToPropertyInspector({ error: error instanceof Error ? error.message : "The dial setting was rejected." }); }
}

@action({ UUID: "com.joeblau.stream-studio.level" })
class StudioLevelAction extends SingletonAction<Settings> {
  protected bindings = new Map<string, DialBinding>();
  constructor() {
    super(); client.on("change", () => {
      for (const binding of this.bindings.values()) {
        if (client.status !== "Connected" || binding.settings.projectID !== client.snapshot?.projectID) { clearTimeout(binding.timer); binding.timer = undefined; binding.ticks = 0; binding.held = false; }
      }
      void this.renderAll().catch(() => {}); void dialInspector(this.manifestId, "level").catch(() => {});
    });
  }
  override async onWillAppear(ev: WillAppearEvent<Settings>) {
    if (!ev.action.isDial()) return;
    this.remove(ev.action.id);
    this.bindings.set(ev.action.id, { action: ev.action, settings: ev.payload.settings, ticks: 0, busy: false, held: false });
    await ev.action.setFeedbackLayout("$B1"); await this.renderAll();
  }
  override onWillDisappear(ev: WillDisappearEvent<Settings>) { this.remove(ev.action.id); }
  protected remove(id: string) { clearTimeout(this.bindings.get(id)?.timer); this.bindings.delete(id); }
  deviceDisconnected(deviceID: string) { for (const [id, binding] of this.bindings) if (binding.action.device.id === deviceID) this.remove(id); }
  override async onDidReceiveSettings(ev: DidReceiveSettingsEvent<Settings>) {
    const binding = this.bindings.get(ev.action.id);
    if (binding) { clearTimeout(binding.timer); binding.timer = undefined; binding.ticks = 0; binding.settings = ev.payload.settings; binding.lastRender = undefined; }
    await this.renderAll(); await dialInspector(this.manifestId, "level");
  }
  override onDialRotate(ev: DialRotateEvent<Settings>) {
    const binding = this.bindings.get(ev.action.id);
    if (!binding || !Number.isSafeInteger(ev.payload.ticks) || Math.abs(ev.payload.ticks) > 127) return;
    binding.ticks = Math.max(-1024, Math.min(1024, binding.ticks + ev.payload.ticks)); this.schedule(binding);
  }
  private schedule(binding: DialBinding) {
    if (binding.busy || binding.timer) return;
    binding.timer = setTimeout(() => { binding.timer = undefined; void this.flush(binding); }, 50);
  }
  private async flush(binding: DialBinding) {
    if (this.bindings.get(binding.action.id) !== binding || !binding.ticks) return;
    const ticks = binding.ticks; binding.ticks = 0; binding.busy = true;
    try {
      const { commandID, projectID } = binding.settings;
      if (!commandID || !projectID) throw new Error("Choose a stable audio level target.");
      const step = binding.settings.step ?? 0.01;
      if (!Number.isFinite(step) || step < 0.001 || step > 0.25) throw new Error("Configure a valid dial step.");
      // Relative deltas resolve against host state in dispatcher order, so
      // two encoders controlling one channel do not overwrite each other.
      await client.execute(commandID, projectID, { delta: Math.max(-1, Math.min(1, ticks * step)) });
    } catch (error) { binding.ticks = 0; await this.alert(binding, error); }
    finally { binding.busy = false; if (binding.ticks && this.bindings.get(binding.action.id) === binding) this.schedule(binding); }
  }
  protected async alert(binding: DialBinding, error: unknown) {
    if (this.bindings.get(binding.action.id) !== binding) return;
    await binding.action.showAlert(); await streamDeck.ui.sendToPropertyInspector({ error: error instanceof Error ? error.message : "The dial command was rejected." });
  }
  override async onDialDown(ev: DialDownEvent<Settings>) {
    const binding = this.bindings.get(ev.action.id); if (!binding || binding.held) return;
    binding.held = true; await this.mute(binding);
  }
  override onDialUp(ev: DialUpEvent<Settings>) { const binding = this.bindings.get(ev.action.id); if (binding) binding.held = false; }
  override async onTouchTap(ev: TouchTapEvent<Settings>) {
    const binding = this.bindings.get(ev.action.id); if (!binding) return;
    if (!ev.payload.hold) { await this.mute(binding); return; }
    try {
      if (!binding.settings.commandID || !binding.settings.projectID) throw new Error("Choose an audio level target.");
      await client.execute(binding.settings.commandID, binding.settings.projectID, { value: 0.5 });
    } catch (error) { await this.alert(binding, error); }
  }
  private async mute(binding: DialBinding) {
    try {
      const { commandID, projectID } = binding.settings;
      if (!commandID?.endsWith(".gain") || !projectID) throw new Error("Choose an audio target with a mute command.");
      await client.execute(commandID.replace(/\.gain$/, ".mute"), projectID);
    } catch (error) { await this.alert(binding, error); }
  }
  override async onPropertyInspectorDidAppear(_ev: PropertyInspectorDidAppearEvent<Settings>) { await dialInspector(this.manifestId, "level"); }
  override async onSendToPlugin(ev: SendToPluginEvent<JsonValue, Settings>) { await configureDial(ev, "level"); }
  private async renderAll() {
    await Promise.all([...this.bindings.values()].map(async binding => {
      const { commandID, projectID } = binding.settings;
      const capability = commandID ? client.capabilities.get(commandID) : undefined;
      const value = commandID ? client.snapshot?.values?.[commandID] : undefined;
      const muted = commandID ? client.snapshot?.mutes?.[commandID] : undefined;
      const usable = client.status === "Connected" && projectID === client.snapshot?.projectID && capability?.kind === "value" && value !== undefined;
      const title = usable ? capability.title : client.status !== "Connected" ? client.status : projectID !== client.snapshot?.projectID ? "Project changed" : "Missing level target";
      const payload = { title, value: usable ? `${Math.round(value * 200)}%${muted ? " · MUTED" : ""}` : "Unavailable", indicator: usable ? value * 100 : 0 };
      const encoded = JSON.stringify(payload); if (binding.lastRender === encoded) return; binding.lastRender = encoded;
      await binding.action.setFeedback(payload);
    }));
  }
}

@action({ UUID: "com.joeblau.stream-studio.selector" })
class StudioSelectorAction extends SingletonAction<Settings> {
  private bindings = new Map<string, { action: DialAction<Settings>; settings: Settings; held: boolean; lastRender?: string }>();
  constructor() { super(); client.on("change", () => { void this.renderAll().catch(() => {}); void dialInspector(this.manifestId, "selector").catch(() => {}); }); }
  override async onWillAppear(ev: WillAppearEvent<Settings>) {
    if (!ev.action.isDial()) return;
    this.bindings.set(ev.action.id, { action: ev.action, settings: ev.payload.settings, held: false });
    await ev.action.setFeedbackLayout("$A1"); await this.renderAll();
  }
  override onWillDisappear(ev: WillDisappearEvent<Settings>) { this.bindings.delete(ev.action.id); }
  deviceDisconnected(deviceID: string) { for (const [id, binding] of this.bindings) if (binding.action.device.id === deviceID) this.bindings.delete(id); }
  override async onDidReceiveSettings(ev: DidReceiveSettingsEvent<Settings>) {
    const binding = this.bindings.get(ev.action.id); if (binding) { binding.settings = ev.payload.settings; binding.lastRender = undefined; }
    await this.renderAll(); await dialInspector(this.manifestId, "selector");
  }
  override async onDialRotate(ev: DialRotateEvent<Settings>) {
    const binding = this.bindings.get(ev.action.id); if (!binding || !Number.isSafeInteger(ev.payload.ticks) || Math.abs(ev.payload.ticks) > 127 || !ev.payload.ticks) return;
    if (client.status !== "Connected" || binding.settings.projectID !== client.snapshot?.projectID) { await binding.action.showAlert(); return; }
    const candidates = selectorCommands(binding.settings.category); if (!candidates.length) { await binding.action.showAlert(); return; }
    const index = candidates.findIndex(command => command.id === binding.settings.commandID);
    const next = index < 0 ? (ev.payload.ticks > 0 ? 0 : candidates.length - 1) : ((index + ev.payload.ticks) % candidates.length + candidates.length) % candidates.length;
    binding.settings = { ...binding.settings, commandID: candidates[next]!.id };
    await binding.action.setSettings(binding.settings); await this.renderAll();
  }
  override async onDialDown(ev: DialDownEvent<Settings>) { const binding = this.bindings.get(ev.action.id); if (!binding || binding.held) return; binding.held = true; await this.activate(binding); }
  override onDialUp(ev: DialUpEvent<Settings>) { const binding = this.bindings.get(ev.action.id); if (binding) binding.held = false; }
  override async onTouchTap(ev: TouchTapEvent<Settings>) { const binding = this.bindings.get(ev.action.id); if (binding && !ev.payload.hold) await this.activate(binding); }
  private async activate(binding: { action: DialAction<Settings>; settings: Settings }) {
    try { if (!binding.settings.commandID || !binding.settings.projectID) throw new Error("Choose a stable selector target."); await client.execute(binding.settings.commandID, binding.settings.projectID); }
    catch { await binding.action.showAlert(); }
  }
  override async onPropertyInspectorDidAppear(_ev: PropertyInspectorDidAppearEvent<Settings>) { await dialInspector(this.manifestId, "selector"); }
  override async onSendToPlugin(ev: SendToPluginEvent<JsonValue, Settings>) { await configureDial(ev, "selector"); }
  private async renderAll() {
    await Promise.all([...this.bindings.values()].map(async binding => {
      if (client.status !== "Connected") binding.held = false;
      const value = feedback(binding.settings, client.status, client.snapshot, client.capabilities);
      const payload = { title: value.title, value: value.badge, icon: keyImage(value) };
      const encoded = JSON.stringify(payload); if (binding.lastRender === encoded) return; binding.lastRender = encoded;
      await binding.action.setFeedback(payload);
    }));
  }
}
@action({ UUID: "com.joeblau.stream-studio.open" })
class OpenStudioAction extends SingletonAction {
  override async onKeyDown(ev: KeyDownEvent): Promise<void> {
    await new Promise<void>(resolve => {
      execFile("/usr/bin/open", ["-b", "com.joeblau.StreamMac"], error => {
        if (error) void ev.action.showAlert(); else client.connect();
        resolve();
      });
    });
  }
}
const commandAction = new StudioCommandAction();
const levelAction = new StudioLevelAction();
const selectorAction = new StudioSelectorAction();
streamDeck.actions.registerAction(commandAction);
streamDeck.actions.registerAction(levelAction);
streamDeck.actions.registerAction(selectorAction);
streamDeck.actions.registerAction(new OpenStudioAction());
streamDeck.devices.onDeviceDidDisconnect(ev => { commandAction.deviceDisconnected(ev.device.id); levelAction.deviceDisconnected(ev.device.id); selectorAction.deviceDisconnected(ev.device.id); });
streamDeck.system.onApplicationDidLaunch(() => client.connect());
streamDeck.system.onSystemDidWakeUp(() => client.connect());
process.on("SIGTERM", () => { client.close(); process.exit(0); });
process.on("SIGINT", () => { client.close(); process.exit(0); });
void streamDeck.connect().then(async () => {
  const pairing = await loadPairing(); if (pairing) client.configure(pairing);
});
