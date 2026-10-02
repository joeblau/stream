import { build } from "esbuild";
import { execFileSync } from "node:child_process";
import { mkdir, readFile, writeFile, rm } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const plugin = resolve(root, "com.joeblau.stream-studio.sdPlugin");
process.chdir(root);
if (process.platform !== "darwin") throw new Error("Build the native macOS plugin on a Mac with Xcode command-line tools.");
await mkdir(resolve(plugin, "bin"), { recursive: true });
await build({ entryPoints: ["src/plugin.ts"], bundle: true, platform: "node", format: "esm", target: "node24",
  outfile: resolve(plugin, "bin/plugin.js"), legalComments: "linked",
  banner: { js: 'import {createRequire} from "node:module"; const require = createRequire(import.meta.url);' } });
for (const architecture of ["arm64", "x86_64"]) {
  execFileSync("xcrun", ["swiftc", "-O", "-target", `${architecture}-apple-macos14.0`,
    "src/keychain-helper.swift", "-o", resolve(plugin, `bin/keychain-helper-${architecture}`)], { stdio: "inherit" });
}
execFileSync("xcrun", ["lipo", "-create", resolve(plugin, "bin/keychain-helper-arm64"), resolve(plugin, "bin/keychain-helper-x86_64"),
  "-output", resolve(plugin, "bin/keychain-helper")]);
for (const architecture of ["arm64", "x86_64"]) await rm(resolve(plugin, `bin/keychain-helper-${architecture}`));
execFileSync("python3", ["scripts/build-icons.py"]);
let licenses = "Stream Studio uses the following pinned, permissively licensed runtime packages.\n\n";
for (const name of ["@elgato/streamdeck", "@elgato/utils", "@elgato/schemas", "ws"]) {
  const pkg = JSON.parse(await readFile(resolve(root, `node_modules/${name}/package.json`), "utf8"));
  const notice = (await readFile(resolve(root, `node_modules/${name}/LICENSE`), "utf8")).replaceAll("\r\n", "\n").trimEnd();
  licenses += `${name} ${pkg.version} (${pkg.license})\n${notice}\n\n`;
}
await writeFile(resolve(plugin, "THIRD_PARTY_LICENSES.txt"), licenses.trimEnd() + "\n");
console.log("Built plugin and universal macOS Keychain helper.");
