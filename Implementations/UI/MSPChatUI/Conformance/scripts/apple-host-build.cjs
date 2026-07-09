#!/usr/bin/env node
const fs = require("node:fs");
const path = require("node:path");
const childProcess = require("node:child_process");

const root = path.resolve(__dirname, "..", "..");
const packagePath = path.join(root, "Hosts/Apple");
const buildPath = path.join(packagePath, ".build");

const result = childProcess.spawnSync("swift", ["build", "--package-path", packagePath], {
  cwd: root,
  encoding: "utf8"
});

try {
  fs.rmSync(buildPath, { recursive: true, force: true });
} catch (_) {}

if (result.status !== 0) {
  if (result.error) {
    process.stderr.write(`failed to run swift: ${result.error.message}\n`);
    process.exit(1);
  }
  process.stderr.write(result.stderr || result.stdout);
  process.exit(result.status || 1);
}

console.log(JSON.stringify({
  ok: true,
  host: "Apple",
  cleaned: !fs.existsSync(buildPath)
}, null, 2));
