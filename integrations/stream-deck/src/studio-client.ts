import { EventEmitter } from "node:events";
import { randomUUID } from "node:crypto";
import net from "node:net";

export type Pairing = { version: 1; clientID: string; token: string; host?: string; port?: number };
export type Capability = { id: string; title: string; category: string; available: boolean; unavailableReason?: string };
export type Snapshot = {
  projectID: string; revision: number; stream: string; recording: string; preview: string;
  stagedSceneID?: string; programSceneID?: string; pendingStagedEdits: boolean;
  layerVisibility: Record<string, boolean>;
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
        && typeof c.available === "boolean" && (c.unavailableReason === undefined || typeof c.unavailableReason === "string")))) return false;
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
  private retryMilliseconds = 1000;
  private refreshing = false;
  private queueDepth = 0;
  private nextSendAt = 0;
  private stopped = false;

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
        const authenticated = await this.request("authenticate", { clientID: credentials.clientID, token: credentials.token });
        if (!authenticated.sessionID || !UUID.test(authenticated.sessionID)) throw new Error("Invalid session response");
        this.sessionID = authenticated.sessionID;
        this.receiveSnapshot(authenticated.snapshot);
        await this.request("subscribe");
        await this.refreshCatalog();
        if (generation !== this.generation) return;
        this.status = "Connected"; this.retryMilliseconds = 1000; this.emit("change");
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
    clearTimeout(this.reconnectTimer); clearTimeout(this.catalogTimer);
    const socket = this.socket; this.socket = undefined; socket?.destroy();
    this.sessionID = undefined; this.snapshot = undefined; this.capabilities.clear(); this.refreshing = false;
    for (const request of this.pending.values()) { clearTimeout(request.timer); request.reject(new Error("Stream disconnected; the command will not be retried.")); }
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
      if (!validResponse(candidate)) {
        this.status = "Incompatible"; this.socket?.destroy(); return;
      }
      const response = candidate;
      if (this.sessionID && response.sessionID !== this.sessionID) { this.socket?.destroy(); return; }
      if (response.error?.code === "versionMismatch") this.status = "Incompatible";
      if (response.error?.code === "unauthorized") this.status = "Pairing revoked";
      this.receiveSnapshot(response.snapshot);
      if (response.id) {
        const pending = this.pending.get(response.id.toLowerCase());
        if (pending) {
          const types: Record<string, string> = { authenticate: "authenticated", subscribe: "snapshot", capabilities: "capabilities", command: "result", ping: "pong" };
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
    if (!snapshot || (this.snapshot && snapshot.revision < this.snapshot.revision)) return;
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
  async execute(commandID: string, projectID: string): Promise<Response> {
    if (this.status !== "Connected" || !this.snapshot) throw new Error("Stream is disconnected.");
    if (this.snapshot.projectID !== projectID) throw new Error("The configured project is not open in Stream.");
    if (!this.capabilities.has(commandID) || commandID.startsWith("unavailable.")) throw new Error("The bound resource is missing or unsupported.");
    // Availability is checked authoritatively by the app at execution, since
    // an output may have changed between catalog refreshes.
    const response = await this.request("command", { commandID });
    if (!response.result?.succeeded) throw new Error(response.result?.error?.message ?? "The command was rejected.");
    this.scheduleCatalogRefresh();
    return response;
  }
}
