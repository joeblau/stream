import type { Capability, Snapshot } from "./studio-client.js";
export type Binding = { commandID?: string; projectID?: string };
export type KeyFeedback = { title: string; badge: string; color: string; unavailable: boolean };
export function feedback(binding: Binding, status: string, snapshot: Snapshot | undefined,
                         capabilities: Map<string, Capability>): KeyFeedback {
  const unavailable = (title: string) => ({ title, badge: "!", color: "#5b3340", unavailable: true });
  if (status !== "Connected" || !snapshot) return unavailable(status);
  if (!binding.commandID || !binding.projectID) return unavailable("Choose\nCommand");
  if (binding.projectID !== snapshot.projectID) return unavailable("Project\nChanged");
  const command = capabilities.get(binding.commandID);
  if (!command) return unavailable("Missing\nResource");
  let badge = command.available ? "READY" : "WAIT";
  let color = command.available ? "#233b4a" : "#5a4828";
  const scene = /^scene\.([0-9a-f-]+)\.select$/i.exec(binding.commandID)?.[1]?.toLowerCase();
  if (scene && snapshot.programSceneID?.toLowerCase() === scene) { badge = "PGM"; color = "#983c4a"; }
  else if (scene && snapshot.stagedSceneID?.toLowerCase() === scene) { badge = "PVW"; color = "#266848"; }
  if (binding.commandID.startsWith("output.stream.")) {
    badge = snapshot.stream.toUpperCase(); color = snapshot.stream === "live" ? "#983c4a" : "#233b4a";
  }
  if (binding.commandID.startsWith("output.record.")) {
    badge = snapshot.recording.toUpperCase(); color = snapshot.recording === "recording" ? "#983c4a" : snapshot.recording === "paused" ? "#766021" : "#233b4a";
  }
  const layer = /^scene\.[0-9a-f-]+\.layer\.([0-9a-f-]+)\.(visibility|show|hide)$/i.exec(binding.commandID)?.[1];
  if (layer) {
    const visible = Object.entries(snapshot.layerVisibility).find(([id]) => id.toLowerCase() === layer.toLowerCase())?.[1];
    if (visible !== undefined) {
      const onProgram = Object.entries(snapshot.programLayerVisibility ?? {}).find(([id]) => id.toLowerCase() === layer.toLowerCase())?.[1];
      badge = onProgram ? "PGM" : visible ? snapshot.programLayerVisibility ? "PVW" : "VISIBLE" : "HIDDEN";
      color = onProgram ? "#983c4a" : visible ? "#266848" : "#233b4a";
    }
  }
  const group = /^scene\.[0-9a-f-]+\.group\.([0-9a-f-]+)\.(visibility|show|hide)$/i.exec(binding.commandID)?.[1];
  const overlay = /^overlay\.([0-9a-f-]+)\.(visibility|show|hide)$/i.exec(binding.commandID)?.[1];
  const visible = group ? snapshot.groupVisibility?.[group] : overlay ? snapshot.overlayVisibility?.[overlay] : undefined;
  if (visible !== undefined) { badge = visible ? overlay ? "GLOBAL ON" : "PVW ON" : "HIDDEN"; color = visible ? "#266848" : "#233b4a"; }
  const gainID = binding.commandID.replace(/\.mute(?:\.(?:on|off))?$/, ".gain");
  const muted = snapshot.mutes?.[gainID];
  if (muted !== undefined && binding.commandID.includes(".mute")) { badge = muted ? "MUTED" : "ON"; color = muted ? "#5a4828" : "#266848"; }
  const level = snapshot.values?.[binding.commandID];
  if (level !== undefined) badge = `${Math.round(level * 200)}%`;
  const resource = /^(media|sound|playlist)\.[0-9a-f-]+/i.exec(binding.commandID)?.[0];
  if (resource && !binding.commandID.includes(".mute") && !binding.commandID.endsWith(".gain")) {
    const phase = snapshot.playback?.[resource];
    if (phase) { badge = phase.toUpperCase(); color = phase === "playing" ? "#266848" : phase === "failed" ? "#5b3340" : "#233b4a"; }
  }
  if (binding.commandID.startsWith("studio.directLive.") && snapshot.directLiveEditing !== undefined) badge = snapshot.directLiveEditing ? "DIRECT LIVE" : "PVW / PGM";
  if (binding.commandID.startsWith("comments.") && snapshot.chat) {
    badge = snapshot.chat.programVisible ? "SLOT PGM" : snapshot.chat.stagedVisible ? "SLOT PVW" : snapshot.chat.ready ? "READY" : "QUEUE EMPTY";
    color = snapshot.chat.programVisible ? "#983c4a" : snapshot.chat.stagedVisible ? "#266848" : "#233b4a";
  }
  const macro = /^macro\.([0-9a-f-]+)\.run$/i.exec(binding.commandID)?.[1];
  if (binding.commandID === "macro.cancel" || (macro && snapshot.macroProgress.macroID?.toLowerCase() === macro.toLowerCase())) {
    badge = snapshot.macroProgress.phase.toUpperCase();
    if (snapshot.macroProgress.phase === "running") badge = `${snapshot.macroProgress.stepIndex + 1}/${snapshot.macroProgress.totalSteps}`;
  }
  return { title: command.title, badge, color, unavailable: !command.available };
}
function escapeXML(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");
}
export function keyImage(value: KeyFeedback): string {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144"><rect width="144" height="144" rx="16" fill="${value.color}"/><rect x="10" y="10" width="124" height="124" rx="10" fill="none" stroke="#e1edf4" stroke-width="3"/><text x="72" y="56" text-anchor="middle" fill="#ffffff" font-family="sans-serif" font-size="${value.badge.length > 10 ? 12 : 17}" font-weight="bold">${escapeXML(value.badge)}</text></svg>`;
  return `data:image/svg+xml;base64,${Buffer.from(svg).toString("base64")}`;
}
