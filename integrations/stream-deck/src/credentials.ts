import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { validatePairing, type Pairing } from "./studio-client.js";
const helper = fileURLToPath(new URL("./keychain-helper", import.meta.url));
function keychain(operation: "read" | "store" | "delete", input?: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(helper, [operation], { stdio: ["pipe", "pipe", "pipe"] });
    let data = "";
    child.stdout.on("data", chunk => {
      data += chunk.toString();
      if (Buffer.byteLength(data) > 4096) { child.kill(); reject(new Error("Invalid pairing credential response.")); }
    });
    // Never surface helper payloads or OS dialogs into plugin logs.
    child.stderr.resume();
    child.on("error", () => reject(new Error("The native Keychain helper is unavailable.")));
    child.on("close", code => code === 0 ? resolve(data) : reject(new Error("The pairing credential is unavailable in Keychain.")));
    child.stdin.end(input ?? "");
  });
}
export async function loadPairing(): Promise<Pairing | undefined> {
  try { return validatePairing(JSON.parse(await keychain("read"))); } catch { return undefined; }
}
export async function savePairing(value: unknown): Promise<Pairing> {
  const pairing = validatePairing(value);
  await keychain("store", JSON.stringify(pairing)); return pairing;
}
export async function forgetPairing(): Promise<void> { await keychain("delete"); }
