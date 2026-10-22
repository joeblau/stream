import { EventEmitter } from "node:events";
import { randomUUID } from "node:crypto";
import net from "node:net";
import { NativeResponseAssembler } from "./response-assembler.ts";

export type Pairing = { version: 1; clientID: string; token: string; host?: string; port?: number };
export type Capability = { id: string; title: string; category: string; available: boolean; unavailableReason?: string; kind?: "command" | "value" | "feedback"; argument?: "text" | "page" | "source"; sourceKind?: "camera" | "screen"; sourceAvailable?: boolean;
  authority?: string; scope?: "project" | "studio"; bindingIntent?: "currentConnection" | "configuredSlot"; requiresConfirmation?: boolean; target?: { kind: string; id: string; name: string; eventID?: string; provider?: string; channelID?: string } };
export type CommandArgument = { value: number } | { delta: number } | { page: number } | { text: string };
export type VisualState = { previewVisible?: boolean; programVisible?: boolean; bypassed?: boolean; programBypassed?: boolean; sourceID?: string; programSourceID?: string };
export type Transport = {
  destinations: { id: string; name: string; state: string; eventKey?: string; managedStart?: string; localStop?: string; remoteEnd?: string;
    endingPending: boolean; confirmationPending: boolean }[];
  confirmationPending: boolean; endingPending: boolean; endingCountdown?: number;
};
export type Snapshot = {
  visuals?: Record<string, VisualState>;
  projectID: string; revision: number; stream: string; recording: string; preview: string;
  recordingCountdown?: number;
  transport?: Transport;
  /** Local loading marker; never expose a partially assembled resource map. */
  receiptsPending?: boolean;
  stagedSceneID?: string; programSceneID?: string; pendingStagedEdits: boolean;
  layerVisibility: Record<string, boolean>;
  values?: Record<string, number>; mutes?: Record<string, boolean>;
  playback?: Record<string, string>; programLayerVisibility?: Record<string, boolean>; groupVisibility?: Record<string, boolean>;
  overlayVisibility?: Record<string, boolean>; directLiveEditing?: boolean;
  chat?: { queuedCount: number; selectedID?: string; featuredID?: string; ready: boolean; stagedVisible: boolean; programVisible: boolean };
  interview?: { phase: string; room?: string; locked: boolean; members: {
    id: string; name: string; membership: string; media: string; slot?: string;
    programAllowed: boolean; monitorAllowed: boolean; screenApproved: boolean; screenSharing: boolean;
  }[] };
  guestSlots?: { id: string; name: string; peerID?: string; membership?: string; media?: string; muted?: boolean; solo?: boolean }[];
  showProfiles?: { projectID: string; profileID: string; canSelect: boolean; requestedProjectID?: string; requestedProfileID?: string };
  audience?: { observedAt: number; liveSeconds?: number; health: string; readings: { destinationID: string; name: string; count?: number; readAt?: number; freshness: string }[]; presetDelivery: Record<string, string> };
  macroProgress: { phase: string; macroID?: string; runID?: string; stepIndex: number; totalSteps: number; message: string };
};
export type Response = { version: 1; type: string; id?: string; sessionID?: string; snapshot?: Snapshot;
  commands?: Capability[]; nextCursor?: number; totalCommands?: number;
  error?: { code: string; message: string }; result?: { succeeded: boolean; error?: { code: string; message: string } } };
const MAX_FRAME = 65536;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const object = (value: unknown): value is Record<string, unknown> => !!value && typeof value === "object" && !Array.isArray(value);
function validResponse(value: unknown): value is Response {
  if (!object(value) || value.version !== 1 || typeof value.type !== "string"
      || !["authenticated", "capabilities", "snapshot", "event", "result", "error", "pong"].includes(value.type)) return false;
  if (value.id !== undefined && (typeof value.id !== "string" || !UUID.test(value.id))) return false;
  if (value.sessionID !== undefined && (typeof value.sessionID !== "string" || !UUID.test(value.sessionID))) return false;
  const validError = (error: unknown) => object(error) && typeof error.code === "string" && typeof error.message === "string";
  if (value.error !== undefined && !validError(value.error)) return false;
  if (value.type === "error" && !validError(value.error)) return false;
  if (value.type === "result" && (!object(value.result) || typeof value.result.succeeded !== "boolean"
      || (value.result.error !== undefined && !validError(value.result.error)))) return false;
  if (value.type === "capabilities" && (!Array.isArray(value.commands) || value.commands.length > 10000
      || !value.commands.every(c => object(c) && typeof c.id === "string" && typeof c.title === "string" && typeof c.category === "string"
        && typeof c.available === "boolean" && (c.unavailableReason === undefined || typeof c.unavailableReason === "string")
        && (c.kind === undefined || c.kind === "command" || c.kind === "value" || c.kind === "feedback")
        && (c.authority === undefined || typeof c.authority === "string" && c.authority.length > 0 && c.authority.length <= 128)
        && (c.scope === undefined || c.scope === "project" || c.scope === "studio")
        && (c.bindingIntent === undefined || c.bindingIntent === "currentConnection" || c.bindingIntent === "configuredSlot")
        && (c.argument === undefined || c.argument === "text" || c.argument === "page" || c.argument === "source")
        && (c.sourceKind === undefined || c.sourceKind === "camera" || c.sourceKind === "screen")
        && (c.sourceAvailable === undefined || typeof c.sourceAvailable === "boolean")
        && (c.requiresConfirmation === undefined || typeof c.requiresConfirmation === "boolean")
        && (c.target === undefined || (object(c.target) && [c.target.kind, c.target.id, c.target.name].every(value => typeof value === "string")
          && [c.target.eventID, c.target.provider, c.target.channelID].every(value => value === undefined || typeof value === "string")))))) return false;
  const state = value.snapshot;
  if (["authenticated", "snapshot", "event"].includes(value.type) && !object(state)) return false;
  if (state !== undefined) {
    if (!object(state) || typeof state.projectID !== "string" || !Number.isSafeInteger(state.revision) || (state.revision as number) < 0
        || typeof state.stream !== "string" || typeof state.recording !== "string" || typeof state.preview !== "string"
        || typeof state.pendingStagedEdits !== "boolean" || !object(state.layerVisibility)
        || !Object.values(state.layerVisibility).every(visible => typeof visible === "boolean") || !object(state.macroProgress)) return false;
    const progress = state.macroProgress;
    if (typeof progress.phase !== "string" || typeof progress.message !== "string"
        || !Number.isSafeInteger(progress.stepIndex) || !Number.isSafeInteger(progress.totalSteps)) return false;
    if ([state.programSceneID, state.stagedSceneID].some(id => id !== undefined && typeof id !== "string")) return false;
    if (state.values !== undefined && (!object(state.values) || !Object.values(state.values).every(value => typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1))) return false;
    if (state.mutes !== undefined && (!object(state.mutes) || !Object.values(state.mutes).every(value => typeof value === "boolean"))) return false;
    for (const key of ["programLayerVisibility", "groupVisibility", "overlayVisibility"]) {
      if (state[key] !== undefined && (!object(state[key]) || !Object.values(state[key]).every(value => typeof value === "boolean"))) return false;
    }
    if (state.visuals !== undefined && (!object(state.visuals) || !Object.values(state.visuals).every(value =>
      object(value) && [value.previewVisible, value.programVisible, value.bypassed, value.programBypassed].every(flag => flag === undefined || typeof flag === "boolean")
      && [value.sourceID, value.programSourceID].every(id => id === undefined || (typeof id === "string" && UUID.test(id)))))) return false;
    if (state.playback !== undefined && (!object(state.playback) || !Object.values(state.playback).every(value => typeof value === "string"))) return false;
    if (state.directLiveEditing !== undefined && typeof state.directLiveEditing !== "boolean") return false;
    if (state.recordingCountdown !== undefined && (!Number.isSafeInteger(state.recordingCountdown) || (state.recordingCountdown as number) < 0 || (state.recordingCountdown as number) > 60)) return false;
    if (state.transport !== undefined) {
      const transport = state.transport;
      if (!object(transport) || typeof transport.confirmationPending !== "boolean" || typeof transport.endingPending !== "boolean"
          || (transport.endingCountdown !== undefined && (!Number.isSafeInteger(transport.endingCountdown) || (transport.endingCountdown as number) < 0 || (transport.endingCountdown as number) > 120))
          || !Array.isArray(transport.destinations)) return false;
      const destinations = new Set<string>();
      for (const target of transport.destinations) {
        if (!object(target) || typeof target.id !== "string" || !UUID.test(target.id) || destinations.has(target.id.toLowerCase())
            || typeof target.name !== "string" || !["idle", "connecting", "live", "reconnecting", "stopping", "failed"].includes(target.state as string)
            || typeof target.endingPending !== "boolean" || typeof target.confirmationPending !== "boolean"
            || [target.managedStart, target.localStop, target.remoteEnd].some(value => value !== undefined && typeof value !== "string")
            || (target.eventKey !== undefined && (typeof target.eventKey !== "string" || !/^[0-9a-f]{64}$/.test(target.eventKey)))) return false;
        destinations.add(target.id.toLowerCase());
      }
    }
    if (state.chat !== undefined && (!object(state.chat) || !Number.isSafeInteger(state.chat.queuedCount) || (state.chat.queuedCount as number) < 0
        || typeof state.chat.ready !== "boolean" || typeof state.chat.stagedVisible !== "boolean" || typeof state.chat.programVisible !== "boolean"
        || [state.chat.selectedID, state.chat.featuredID].some(id => id !== undefined && typeof id !== "string"))) return false;
    if (state.guestSlots !== undefined && (!Array.isArray(state.guestSlots) || state.guestSlots.length > 16
        || !state.guestSlots.every(slot => object(slot) && typeof slot.id === "string" && UUID.test(slot.id)
          && typeof slot.name === "string" && slot.name.length <= 256
          && (slot.peerID === undefined || typeof slot.peerID === "string" && UUID.test(slot.peerID))
          && [slot.membership, slot.media].every(value => value === undefined || typeof value === "string")
          && [slot.muted, slot.solo].every(value => value === undefined || typeof value === "boolean")))) return false;
    if (state.showProfiles !== undefined) {
      const profiles = state.showProfiles;
      if (!object(profiles) || typeof profiles.projectID !== "string" || !UUID.test(profiles.projectID)
          || typeof profiles.profileID !== "string" || !UUID.test(profiles.profileID) || typeof profiles.canSelect !== "boolean"
          || [profiles.requestedProjectID, profiles.requestedProfileID].some(value => value !== undefined && (typeof value !== "string" || !UUID.test(value)))) return false;
    }
    if (state.audience !== undefined) {
      const audience = state.audience;
      if (!object(audience) || typeof audience.observedAt !== "number" || !Number.isFinite(audience.observedAt)
          || typeof audience.health !== "string" || (audience.liveSeconds !== undefined && (!Number.isSafeInteger(audience.liveSeconds) || (audience.liveSeconds as number) < 0 || (audience.liveSeconds as number) > 31536000))
          || !Array.isArray(audience.readings) || audience.readings.length > 64 || !object(audience.presetDelivery)
          || Object.keys(audience.presetDelivery).length > 64 || !Object.values(audience.presetDelivery).every(value => typeof value === "string")) return false;
      if (!audience.readings.every(reading => object(reading) && typeof reading.destinationID === "string" && UUID.test(reading.destinationID)
          && typeof reading.name === "string" && reading.name.length <= 512 && typeof reading.freshness === "string"
          && (reading.count === undefined || Number.isSafeInteger(reading.count) && (reading.count as number) >= 0)
          && (reading.readAt === undefined || typeof reading.readAt === "number" && Number.isFinite(reading.readAt)))) return false;
    }
    if (state.interview !== undefined) {
      const interview = state.interview;
      if (!object(interview) || typeof interview.phase !== "string" || typeof interview.locked !== "boolean"
          || (interview.room !== undefined && (typeof interview.room !== "string" || !UUID.test(interview.room)))
          || !Array.isArray(interview.members) || interview.members.length > 11) return false;
      const members = new Set<string>();
      for (const member of interview.members) {
        if (!object(member) || typeof member.id !== "string" || !UUID.test(member.id) || members.has(member.id.toLowerCase())
            || typeof member.name !== "string" || member.name.length > 80 || typeof member.membership !== "string" || typeof member.media !== "string"
            || (member.slot !== undefined && (typeof member.slot !== "string" || !UUID.test(member.slot)))
            || [member.programAllowed, member.monitorAllowed, member.screenApproved, member.screenSharing].some(value => typeof value !== "boolean")) return false;
        members.add(member.id.toLowerCase());
      }
    }
  }
  return true;
}
export function validatePairing(value: unknown): Pairing {
  const candidate = value as Pairing;
  if (!candidate || candidate.version !== 1 || !UUID.test(candidate.clientID) || !/^[0-9a-f]{64}$/.test(candidate.token)
      || (candidate.host !== undefined && candidate.host !== "127.0.0.1")
      || (candidate.port !== undefined && (!Number.isInteger(candidate.port) || candidate.port < 1 || candidate.port > 65535))) {
    throw new Error("Paste version 1 pairing credentials from Stream Studio.");
  }
  return candidate;
}

/** One native session serves every key/device. Reconnect refreshes state and
 * catalog; pending or completed production requests are never replayed. */
export class StudioClient extends EventEmitter {
  status = "Unpaired";
  snapshot?: Snapshot;
  capabilities = new Map<string, Capability>();
  private socket?: net.Socket;
  private buffer = Buffer.alloc(0);
  private sessionID?: string;
  private pending = new Map<string, { type: string; resolve: (value: Response) => void; reject: (reason: Error) => void; timer: NodeJS.Timeout }>();
  private credentials?: Pairing;
  private generation = 0;
  private reconnectTimer?: NodeJS.Timeout;
  private catalogTimer?: NodeJS.Timeout;
  private feedbackTimer?: NodeJS.Timeout;
  private retryMilliseconds = 1000;
  private refreshing = false;
  private queueDepth = 0;
  private nextSendAt = 0;
  private stopped = false;
  private assembler = new NativeResponseAssembler();
  private chunkTimeout?: NodeJS.Timeout;

  configure(pairing: Pairing): void {
    this.credentials = validatePairing(pairing);
    this.stopped = false;
    this.disconnect("Connecting");
    this.connect();
  }
  connect(): void {
    if (this.stopped || this.socket || !this.credentials) return;
    clearTimeout(this.reconnectTimer);
    const generation = ++this.generation;
    this.status = "Connecting"; this.emit("change");
    this.buffer = Buffer.alloc(0);
    const socket = net.createConnection({ host: "127.0.0.1", port: this.credentials.port ?? 32145 });
    this.socket = socket;
    socket.setNoDelay(true);
    socket.on("error", () => { /* close provides one sanitized status update */ });
    socket.on("close", () => {
      if (generation !== this.generation) return;
      this.disconnect(this.status === "Incompatible" || this.status === "Pairing revoked" ? this.status : "Disconnected");
      if (this.status !== "Incompatible" && this.status !== "Pairing revoked") this.scheduleReconnect();
    });
    socket.on("data", (data: Buffer) => { if (generation === this.generation) this.consume(data); });
    socket.on("connect", async () => {
      try {
        const credentials = this.credentials!;
        const authenticated = await this.request("authenticate", { clientID: credentials.clientID, token: credentials.token, responseChunks: true });
        if (!authenticated.sessionID || !UUID.test(authenticated.sessionID)) throw new Error("Invalid session response");
        this.sessionID = authenticated.sessionID;
        this.receiveSnapshot(authenticated.snapshot);
        await this.request("subscribe");
        await this.refreshCatalog();
        if (generation !== this.generation) return;
        this.status = "Connected"; this.retryMilliseconds = 1000; this.emit("change");
        // Age cached audience readings even if the native publisher stalls.
        // This redraws local feedback only; it never polls providers or replays requests.
        this.feedbackTimer = setInterval(() => this.emit("change"), 1000);
        this.feedbackTimer.unref();
      } catch {
        if (generation !== this.generation) return;
        this.socket?.destroy();
      }
    });
  }
  close(): void { this.stopped = true; this.disconnect("Disconnected"); }
  forget(): void { this.credentials = undefined; this.stopped = true; this.disconnect("Unpaired"); }
  private scheduleReconnect(): void {
    if (this.stopped || !this.credentials) return;
    clearTimeout(this.reconnectTimer);
    this.reconnectTimer = setTimeout(() => this.connect(), this.retryMilliseconds);
    this.retryMilliseconds = Math.min(10000, this.retryMilliseconds * 2);
  }
  private disconnect(status: string): void {
    ++this.generation;
    clearTimeout(this.reconnectTimer); clearTimeout(this.catalogTimer); clearInterval(this.feedbackTimer);
    const socket = this.socket; this.socket = undefined; socket?.destroy();
    this.sessionID = undefined; this.snapshot = undefined; this.capabilities.clear(); this.refreshing = false;
    for (const request of this.pending.values()) { clearTimeout(request.timer); request.reject(new Error("Stream disconnected; the command will not be retried.")); }
    clearTimeout(this.chunkTimeout); this.chunkTimeout = undefined; this.assembler = new NativeResponseAssembler();
    this.pending.clear(); this.status = status; this.emit("change");
  }
  private async request(type: string, payload: Record<string, unknown> = {}): Promise<Response> {
    if (!this.socket || (type !== "authenticate" && !this.sessionID)) throw new Error("Stream is disconnected.");
    if (this.queueDepth >= 16) throw new Error("Too many controller requests; wait for authoritative feedback.");
    const generation = this.generation;
    ++this.queueDepth;
    try {
      const wait = Math.max(0, this.nextSendAt - Date.now());
      this.nextSendAt = Math.max(Date.now(), this.nextSendAt) + 25;
      if (wait) await new Promise(resolve => setTimeout(resolve, wait));
      if (generation !== this.generation || !this.socket) throw new Error("Connection changed; the command will not be retried.");
      const id = randomUUID();
      const request = { version: 1, type, id, ...(this.sessionID ? { sessionID: this.sessionID } : {}), ...payload };
      const data = Buffer.from(JSON.stringify(request));
      if (data.byteLength > MAX_FRAME) throw new Error("Controller request is too large.");
      return await new Promise<Response>((resolve, reject) => {
        const timer = setTimeout(() => {
          this.pending.delete(id); reject(new Error("Stream did not acknowledge the request; it will not be retried."));
          if (generation === this.generation) this.socket?.destroy();
        }, 5000);
        this.pending.set(id, { type, resolve, reject, timer });
        this.socket!.write(Buffer.concat([data, Buffer.from("\n")]));
      });
    } finally { --this.queueDepth; }
  }
  private consume(data: Buffer): void {
    this.buffer = Buffer.concat([this.buffer, data]);
    let newline: number;
    while ((newline = this.buffer.indexOf(10)) >= 0) {
      const frame = this.buffer.subarray(0, newline); this.buffer = this.buffer.subarray(newline + 1);
      if (frame.byteLength > MAX_FRAME || !frame.byteLength) { this.socket?.destroy(); return; }
      let candidate: unknown;
      try { candidate = JSON.parse(frame.toString("utf8")); }
      catch { this.socket?.destroy(); return; }
      if (object(candidate) && candidate.type === "responseChunk") {
        if (this.sessionID && candidate.sessionID !== this.sessionID) { this.socket?.destroy(); return; }
        try { candidate = this.assembler.accept(candidate); }
        catch { this.status = "Incompatible"; this.socket?.destroy(); return; }
        if (this.assembler.pendingCount && !this.chunkTimeout) {
          this.chunkTimeout = setTimeout(() => { this.socket?.destroy(); }, 5000);
        } else if (!this.assembler.pendingCount) { clearTimeout(this.chunkTimeout); this.chunkTimeout = undefined; }
        if (this.snapshot && (this.assembler.pendingSnapshotRevision ?? -1) > this.snapshot.revision && !this.snapshot.receiptsPending) {
          this.snapshot = { ...this.snapshot, receiptsPending: true }; this.emit("change");
        }
        if (candidate === undefined) continue;
      }
      if (!validResponse(candidate)) {
        this.status = "Incompatible"; this.socket?.destroy(); return;
      }
      const response = candidate;
      if (this.sessionID && response.sessionID !== this.sessionID) { this.socket?.destroy(); return; }
      if (response.error?.code === "responseLimit" || response.error?.code === "responseChunksRequired") this.status = "Incompatible";
      if (response.error?.code === "versionMismatch") this.status = "Incompatible";
      if (response.error?.code === "unauthorized") this.status = "Pairing revoked";
      this.receiveSnapshot(response.snapshot);
      if (response.id) {
        const pending = this.pending.get(response.id.toLowerCase());
        if (pending) {
          const types: Record<string, string> = { authenticate: "authenticated", subscribe: "snapshot", snapshot: "snapshot", capabilities: "capabilities", command: "result", ping: "pong" };
          const expected = types[pending.type];
          if (response.type !== "error" && response.type !== expected) { this.socket?.destroy(); return; }
          clearTimeout(pending.timer); this.pending.delete(response.id.toLowerCase());
          if (response.error) pending.reject(new Error(response.error.message)); else pending.resolve(response);
        }
      }
      if (response.type === "event") this.scheduleCatalogRefresh();
    }
    if (this.buffer.byteLength > MAX_FRAME) this.socket?.destroy();
  }
  private receiveSnapshot(snapshot?: Snapshot): void {
    if (!snapshot || snapshot.revision < this.assembler.newestSnapshotRevision || (this.snapshot && snapshot.revision < this.snapshot.revision)) return;
    this.assembler.noteCompleteSnapshot(snapshot.revision);
    if (!this.assembler.pendingCount) { clearTimeout(this.chunkTimeout); this.chunkTimeout = undefined; }
    this.snapshot = snapshot; this.emit("change");
  }
  private scheduleCatalogRefresh(): void {
    if (this.catalogTimer || !this.sessionID) return;
    const generation = this.generation;
    this.catalogTimer = setTimeout(() => {
      this.catalogTimer = undefined;
      void this.refreshCatalog().catch(() => { if (generation === this.generation) this.socket?.destroy(); });
    }, 500);
  }
  async refreshCatalog(): Promise<void> {
    if (this.refreshing) return;
    this.refreshing = true;
    const generation = this.generation;
    const commands = new Map<string, Capability>();
    try {
      let cursor = 0;
      for (;;) {
        const response = await this.request("capabilities", { cursor });
        if (!Array.isArray(response.commands) || (response.totalCommands ?? 0) > 10000) throw new Error("Unsupported command catalog.");
        for (const command of response.commands) commands.set(command.id, command);
        if (response.nextCursor === undefined) break;
        if (!Number.isSafeInteger(response.nextCursor) || response.nextCursor <= cursor) throw new Error("Invalid command cursor.");
        cursor = response.nextCursor;
      }
      if (generation === this.generation) { this.capabilities = commands; this.emit("change"); }
    } finally { if (generation === this.generation) this.refreshing = false; }
  }
  async execute(commandID: string, projectID: string, argument?: CommandArgument): Promise<Response> {
    if (this.status !== "Connected" || !this.snapshot) throw new Error("Stream is disconnected.");
    if (this.snapshot.receiptsPending) throw new Error("Stream is updating complete resource state. Try again after feedback refreshes.");
    const configured = this.capabilities.get(commandID);
    if (this.snapshot.projectID !== projectID && !(configured?.scope === "studio" && /^show\.[0-9a-f-]+\.profile\.[0-9a-f-]+\.select$/i.test(commandID))) throw new Error("The configured project is not open in Stream.");
    if (!this.capabilities.has(commandID) || commandID.startsWith("unavailable.")) throw new Error("The bound resource is missing or unsupported.");
    if (configured?.kind === "feedback") {
      if (argument) throw new Error("Feedback controls do not accept mutation arguments.");
      return this.request("snapshot");
    }
    if (argument) {
      const capability = this.capabilities.get(commandID)!;
      if ("value" in argument || "delta" in argument) {
        const value = "value" in argument ? argument.value : argument.delta;
        if (capability.kind !== "value" || !Number.isFinite(value) || value < ("value" in argument ? 0 : -1) || value > 1) throw new Error("Choose a supported normalized value target.");
      } else if ("page" in argument) {
        if (capability.argument !== "page" || !Number.isSafeInteger(argument.page) || argument.page < 0 || argument.page > 100000) throw new Error("Choose a valid PDF jump target and page.");
      } else if (capability.argument === "source") {
        if (!UUID.test(argument.text)) throw new Error("Choose a registered source UUID.");
      } else if (capability.argument !== "text" || !argument.text.trim() || Buffer.byteLength(argument.text) > 512) throw new Error("Marker text needs 1–512 UTF-8 bytes.");
    } else if (this.capabilities.get(commandID)?.kind === "value") throw new Error("This target requires a numeric value.");
    else if (this.capabilities.get(commandID)?.argument === "source") throw new Error("Choose a registered source UUID.");
    // Availability is checked authoritatively by the app at execution, since
    // an output may have changed between catalog refreshes.
    const response = await this.request("command", { commandID, ...argument, ...(configured?.authority ? { authority: configured.authority } : {}) });
    if (!response.result?.succeeded) throw new Error(response.result?.error?.message ?? "The command was rejected.");
    this.scheduleCatalogRefresh();
    return response;
  }
}
