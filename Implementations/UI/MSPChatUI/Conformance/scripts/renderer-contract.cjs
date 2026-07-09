#!/usr/bin/env node
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..", "..");

function load(relativePath) {
  return require(path.join(root, relativePath));
}

load("Registry/runtime/renderer-registry.js");
const registry = globalThis.MSPChatUIRendererRegistry;

function readJSON(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function rendererManifests() {
  const renderersRoot = path.join(root, "Renderers");
  return fs.readdirSync(renderersRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => path.join(renderersRoot, entry.name, "renderer.manifest.json"))
    .filter((filePath) => fs.existsSync(filePath));
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const manifests = rendererManifests().map((filePath) => ({ filePath, manifest: readJSON(filePath) }));
manifests.forEach(({ filePath, manifest }) => {
  const validation = registry.validateManifest(manifest);
  assert(validation.ok, `${filePath} failed validation: ${validation.errors.join("; ")}`);
  const rendererRoot = path.dirname(filePath);
  [
    ...(manifest.contractScripts || []),
    ...(manifest.projectionScripts || []),
    ...(manifest.rendererAPIScripts || []),
    ...(manifest.hostCompatibilityScripts || [])
  ].forEach((script) => {
    assert(fs.existsSync(path.resolve(rendererRoot, script)), `${manifest.id} missing script ${script}`);
  });
  assert(manifest.capabilities?.timeline === true, `${manifest.id} must support timeline`);
  assert(manifest.capabilities?.runtimeEvents === true, `${manifest.id} must support runtimeEvents`);
});

console.log(JSON.stringify({
  ok: true,
  renderers: manifests.map((entry) => entry.manifest.id)
}, null, 2));
