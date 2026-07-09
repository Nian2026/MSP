#!/usr/bin/env node
const fs = require("node:fs");
const path = require("node:path");
const childProcess = require("node:child_process");

const root = path.resolve(__dirname, "..", "..");

function readJSON(relativePath) {
  return JSON.parse(fs.readFileSync(path.join(root, relativePath), "utf8"));
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function runPack(command, args) {
  if (process.platform === "win32") {
    return childProcess.spawnSync(process.env.ComSpec || "cmd.exe", ["/d", "/s", "/c", [command, ...args].join(" ")], {
      cwd: root,
      encoding: "utf8"
    });
  }
  return childProcess.spawnSync(command, args, {
    cwd: root,
    encoding: "utf8"
  });
}

function parsePackFiles(stdout) {
  const records = JSON.parse(stdout || "[]");
  const record = Array.isArray(records) ? records[0] : records;
  return (record?.files || []).map((entry) => entry.path).sort();
}

function isCommandUnavailable(result) {
  return Boolean(result.error) || /not recognized|not found|ENOENT/i.test(result.stderr || "");
}

function packFiles() {
  const npmCommand = process.platform === "win32" ? "npm.cmd" : "npm";
  const result = runPack(npmCommand, ["pack", "--dry-run", "--json"]);
  if (isCommandUnavailable(result)) {
    const pnpmCommand = process.platform === "win32" ? "pnpm.cmd" : "pnpm";
    const fallback = runPack(pnpmCommand, ["pack", "--dry-run", "--json"]);
    if (isCommandUnavailable(fallback)) {
      throw new Error(`failed to run ${npmCommand} or ${pnpmCommand}: ${fallback.error?.message || fallback.stderr}`);
    }
    if (fallback.status !== 0) {
      throw new Error(fallback.stderr || fallback.stdout || "pnpm pack --dry-run failed");
    }
    return parsePackFiles(fallback.stdout);
  }
  if (result.status !== 0) {
    throw new Error(result.stderr || result.stdout || "npm pack --dry-run failed");
  }
  return parsePackFiles(result.stdout);
}

const pkg = readJSON("package.json");
const entrypoint = require(path.join(root, "index.js"));
const version = fs.readFileSync(path.join(root, "VERSION"), "utf8").trim();
const files = packFiles();
const required = [
  "index.js",
  "index.d.ts",
  "API.md",
  "RELEASE.md",
  "Conformance/fixtures/markstream-bundle-license-audit.json",
  "Contracts/types/msp-chat-ui.d.ts",
  "Renderers/Default/renderer.manifest.json",
  "Renderers/Default/runtime/loader/default-web-loader.js",
  "Renderers/Default/runtime/assets/Math/readex-markstream-sdk.js",
  "Hosts/Web/default.html",
  "Hosts/Apple/Package.swift",
  "Conformance/DefaultParityChecklist.md"
];
const forbidden = files.filter((file) => (
  file.startsWith("References/") ||
  file.includes("AIReadingReadexModeSnapshot") ||
  /(^|\/)(node_modules|\.build|build|dist|app\.asar|\.DS_Store)(\/|$)/.test(file)
));
const missing = required.filter((file) => !files.includes(file));

assert(pkg.private === false, "package must be publishable");
assert(pkg.version === version, "package.json version must match VERSION");
assert(pkg.main === "index.js" && pkg.types === "index.d.ts", "package must expose main and types");
assert(pkg.exports?.["."]?.require === "./index.js", "package exports must expose root require entry");
assert(pkg.exports?.["./renderers/default/manifest"], "package must export Default manifest");
assert(typeof entrypoint.projection?.projectTimeline === "function", "root package entry must expose projection API");
assert(typeof entrypoint.registry?.validateManifest === "function", "root package entry must expose registry API");
assert(missing.length === 0, `npm package is missing required files: ${missing.join(", ")}`);
assert(forbidden.length === 0, `npm package contains forbidden files: ${forbidden.join(", ")}`);

console.log(JSON.stringify({
  ok: true,
  version,
  files: files.length,
  required: required.length
}, null, 2));
