#!/usr/bin/env node
const fs = require("node:fs");
const path = require("node:path");
const childProcess = require("node:child_process");

const root = path.resolve(__dirname, "..", "..");
const repo = path.resolve(root, "..", "..", "..");
const maxAuthoredLines = 220;
const generatedDirectoryNames = new Set(["node_modules", ".build", "build", "dist"]);

function readJSON(relativePath) {
  return JSON.parse(fs.readFileSync(path.join(root, relativePath), "utf8"));
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function walk(dir, files = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const fullPath = path.join(dir, entry.name);
    if (fullPath.includes(`${path.sep}References${path.sep}`)) continue;
    if (fullPath.includes(`${path.sep}Renderers${path.sep}Default${path.sep}runtime${path.sep}assets${path.sep}`)) continue;
    if (entry.isDirectory() && generatedDirectoryNames.has(entry.name)) continue;
    if (entry.isDirectory()) walk(fullPath, files);
    else files.push(fullPath);
  }
  return files;
}

function checkIgnored(relativePath) {
  const output = childProcess.spawnSync("git", ["check-ignore", "-q", relativePath], {
    cwd: repo,
    stdio: "ignore"
  });
  return output.status === 0;
}

function pathParts(filePath) {
  return filePath.split(/[\\/]+/).filter(Boolean);
}

function hasForbiddenPathPart(filePath) {
  return pathParts(filePath).some((part) => part === ".DS_Store" || part === "app.asar");
}

function lineCount(filePath) {
  return fs.readFileSync(filePath, "utf8").split("\n").length;
}

const authoredFiles = walk(root);
const badNames = authoredFiles.filter(hasForbiddenPathPart);
const oversized = authoredFiles
  .filter((filePath) => /\.(js|cjs|json|md|ts)$/.test(filePath))
  .map((filePath) => ({ filePath, lines: lineCount(filePath) }))
  .filter((entry) => entry.lines > maxAuthoredLines);
const manifest = readJSON("Renderers/Default/renderer.manifest.json");
const scripts = [
  ...(manifest.contractScripts || []),
  ...(manifest.projectionScripts || []),
  ...(manifest.rendererAPIScripts || []),
  ...(manifest.hostCompatibilityScripts || [])
];
const missingScripts = scripts.filter((script) => !fs.existsSync(path.resolve(root, "Renderers/Default", script)));

assert(checkIgnored("Implementations/UI/MSPChatUI/References/AIReadingReadexModeSnapshot"), "reference snapshot must be ignored");
assert(badNames.length === 0, `release tree contains generated/private paths: ${badNames.join(", ")}`);
assert(oversized.length === 0, `authored files exceed ${maxAuthoredLines} lines: ${JSON.stringify(oversized)}`);
assert(missingScripts.length === 0, `manifest script paths are missing: ${missingScripts.join(", ")}`);
assert(manifest.capabilities?.runtimeEvents === true, "Default manifest must advertise runtimeEvents");

console.log(JSON.stringify({
  ok: true,
  authoredFiles: authoredFiles.length,
  maxAuthoredLines,
  manifestScripts: scripts.length
}, null, 2));
