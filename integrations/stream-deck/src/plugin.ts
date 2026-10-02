import streamDeck, { action, SingletonAction, type WillAppearEvent, type WillDisappearEvent,
  type DidReceiveSettingsEvent, type KeyDownEvent, type KeyUpEvent, type SendToPluginEvent,
  type PropertyInspectorDidAppearEvent, type KeyAction } from "@elgato/streamdeck";
import type { JsonValue } from "@elgato/utils";
import { execFile } from "node:child_process";
import { StudioClient } from "./studio-client.js";
import { loadPairing, savePairing, forgetPairing } from "./credentials.js";
import { feedback, keyImage } from "./feedback.js";

type Settings = { commandID?: string; projectID?: string };
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
      await client.execute(settings.commandID, settings.projectID);
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
    const payload = ev.payload as { operation?: string; credentials?: unknown; commandID?: string } | null;
    if (!payload) return;
    try {
      if (payload.operation === "pair") { client.configure(await savePairing(payload.credentials)); }
      if (payload.operation === "forget") { await forgetPairing(); client.forget(); }
      if (payload.operation === "refresh") { await client.refreshCatalog(); }
      if (payload.operation === "bind") {
        if (!payload.commandID || !client.snapshot || !client.capabilities.has(payload.commandID)) throw new Error("Select a command from the current studio catalog.");
        await ev.action.setSettings({ commandID: payload.commandID, projectID: client.snapshot.projectID });
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
      settings, commands: [...client.capabilities.values()] });
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
streamDeck.actions.registerAction(commandAction);
streamDeck.actions.registerAction(new OpenStudioAction());
streamDeck.devices.onDeviceDidDisconnect(ev => commandAction.deviceDisconnected(ev.device.id));
streamDeck.system.onApplicationDidLaunch(() => client.connect());
streamDeck.system.onSystemDidWakeUp(() => client.connect());
process.on("SIGTERM", () => { client.close(); process.exit(0); });
process.on("SIGINT", () => { client.close(); process.exit(0); });
void streamDeck.connect().then(async () => {
  const pairing = await loadPairing(); if (pairing) client.configure(pairing);
});
