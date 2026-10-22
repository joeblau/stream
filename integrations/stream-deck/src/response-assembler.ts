const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const object = (value: unknown): value is Record<string, unknown> => !!value && typeof value === "object" && !Array.isArray(value);
const CHUNK_BYTES = 24 * 1024;
const MAX_BYTES = 16 * 1024 * 1024;
const TYPES = ["authenticated", "capabilities", "snapshot", "event", "result", "error", "pong"];
type Transfer = { id?: string; sessionID?: string; responseType: string; revision?: number; count: number; bytes: number; chunks: Map<number, Buffer> };
/** Reconstruct complete protocol responses, never partial resource state. */
export class NativeResponseAssembler {
  private transfers = new Map<string, Transfer>();
  newestSnapshotRevision = 0;
  get pendingCount(): number { return this.transfers.size; }
  get pendingSnapshotRevision(): number | undefined {
    const revisions = [...this.transfers.values()].flatMap(value => value.revision === undefined ? [] : [value.revision]);
    return revisions.length ? Math.max(...revisions) : undefined;
  }
  noteCompleteSnapshot(revision: number): void {
    this.newestSnapshotRevision = Math.max(this.newestSnapshotRevision, revision);
    this.retireEvents(revision);
  }
  private retireEvents(revision: number): void {
    for (const [id, transfer] of this.transfers) if (transfer.responseType === "event" && transfer.revision !== undefined && transfer.revision < revision) this.transfers.delete(id);
  }
  accept(value: unknown): unknown | undefined {
    if (!object(value) || value.version !== 1 || value.type !== "responseChunk" || !object(value.responseChunk)) throw new Error("Invalid response chunk envelope");
    const part = value.responseChunk;
    if (typeof part.transferID !== "string" || !UUID.test(part.transferID)
        || !Number.isSafeInteger(part.index) || !Number.isSafeInteger(part.count) || !Number.isSafeInteger(part.totalBytes)
        || (part.totalBytes as number) <= 65536 || (part.totalBytes as number) > MAX_BYTES
        || (part.count as number) !== Math.ceil((part.totalBytes as number) / CHUNK_BYTES)
        || (part.index as number) < 0 || (part.index as number) >= (part.count as number)
        || typeof part.responseType !== "string" || !TYPES.includes(part.responseType)
        || (part.snapshotRevision !== undefined && (!Number.isSafeInteger(part.snapshotRevision) || (part.snapshotRevision as number) < 0))
        || [value.id, value.sessionID].some(id => id !== undefined && (typeof id !== "string" || !UUID.test(id)))
        || typeof part.body !== "string" || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(part.body)) throw new Error("Invalid response chunk metadata");
    const index = part.index as number, count = part.count as number, bytes = part.totalBytes as number, revision = part.snapshotRevision as number | undefined;
    const body = Buffer.from(part.body, "base64");
    if (body.byteLength !== (index === count - 1 ? bytes - index * CHUNK_BYTES : CHUNK_BYTES) || body.toString("base64") !== part.body) throw new Error("Invalid response chunk length");
    if (revision !== undefined) {
      if (part.responseType === "event" && revision < this.newestSnapshotRevision) return undefined;
      this.newestSnapshotRevision = Math.max(this.newestSnapshotRevision, revision); this.retireEvents(revision);
    }
    const key = part.transferID.toLowerCase();
    let transfer = this.transfers.get(key);
    if (!transfer) {
      if (this.transfers.size >= 8) throw new Error("Too many incomplete native responses");
      transfer = { id: value.id as string | undefined, sessionID: value.sessionID as string | undefined, responseType: part.responseType,
        revision, count, bytes, chunks: new Map() };
      this.transfers.set(key, transfer);
    }
    if (transfer.id !== value.id || transfer.sessionID !== value.sessionID || transfer.responseType !== part.responseType
        || transfer.revision !== revision || transfer.count !== count || transfer.bytes !== bytes || transfer.chunks.has(index)) throw new Error("Mixed or duplicate response chunks");
    transfer.chunks.set(index, body);
    if (transfer.chunks.size !== count) return undefined;
    this.transfers.delete(key);
    const joined = Buffer.concat(Array.from({ length: count }, (_, index) => transfer!.chunks.get(index)!));
    let response: unknown;
    try { response = JSON.parse(joined.toString("utf8")); } catch { throw new Error("Invalid assembled native response"); }
    if (!object(response) || response.version !== 1 || response.type !== transfer.responseType || response.id !== transfer.id || response.sessionID !== transfer.sessionID
        || (revision !== undefined && (!object(response.snapshot) || response.snapshot.revision !== revision))) throw new Error("Assembled response identity mismatch");
    return response;
  }
}
