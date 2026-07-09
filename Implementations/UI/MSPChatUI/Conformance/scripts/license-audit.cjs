#!/usr/bin/env node
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");

const root = path.resolve(__dirname, "..", "..");
const repo = path.resolve(root, "..", "..", "..");
const allowedLicenses = new Set(["MIT", "ISC", "(MPL-2.0 OR Apache-2.0)", "BSD-2-Clause", "BSD-3-Clause"]);
const noticeFiles = [
  "Renderers/Default/runtime/assets/Math/diff2html-LICENSE.md",
  "Renderers/Default/runtime/assets/Math/highlightjs-LICENSE.txt",
  "Renderers/Default/runtime/assets/Math/prettier-LICENSE.txt",
  "Renderers/Default/runtime/assets/KnowledgeMap/d3-LICENSE.txt",
  "Renderers/Default/runtime/assets/KnowledgeMap/markmap-view-LICENSE.txt"
];

function read(relativePath) {
  return fs.readFileSync(path.join(root, relativePath), "utf8");
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function countLicenses(packages) {
  const counts = {};
  packages.forEach((entry) => {
    counts[entry.license] = (counts[entry.license] || 0) + 1;
  });
  return counts;
}

const rootLicense = fs.readFileSync(path.join(repo, "LICENSE"), "utf8");
const vendorManifest = read("Renderers/Default/VENDOR_MANIFEST.md");
const notices = read("THIRD_PARTY_NOTICES.md");
const audit = JSON.parse(read("Conformance/fixtures/markstream-bundle-license-audit.json"));
const bundlePath = path.join(root, audit.bundle?.path || "");
const bundle = Buffer.from(fs.readFileSync(bundlePath, "utf8").replace(/\r\n/g, "\n"), "utf8");
const packageEntries = audit.packages || [];
const missing = [];
const unapproved = [];
const counts = countLicenses(packageEntries);

packageEntries.forEach((entry) => {
  const license = entry.license || "";
  if (!entry.path || !entry.version || !license) missing.push(entry.path || "(unknown)");
  if (license && !allowedLicenses.has(license)) unapproved.push({ path: entry.path, license });
});

assert(rootLicense.includes("Apache License"), "repository LICENSE must be Apache-2.0");
assert(!vendorManifest.includes("Before a public release"), "vendor manifest must not contain public-release TODO text");
assert(notices.includes("Markstream Bundle Audit"), "third-party notices must document Markstream audit");
noticeFiles.forEach((noticeFile) => {
  assert(fs.existsSync(path.join(root, noticeFile)), `missing notice file: ${noticeFile}`);
});
assert(audit.schemaVersion === 1, "Markstream license audit fixture schema is unsupported");
assert(packageEntries.length > 0, "Markstream license audit fixture must list packages");
assert(bundle.length === audit.bundle.bytes, "Markstream bundle byte size changed without audit update");
assert(
  crypto.createHash("sha256").update(bundle).digest("hex") === audit.bundle.sha256,
  "Markstream bundle hash changed without audit update"
);
assert(
  JSON.stringify(counts) === JSON.stringify(audit.licenseCounts),
  "Markstream license counts do not match package list"
);
audit.allowedLicenses.forEach((license) => {
  assert(allowedLicenses.has(license), `audit fixture allows unapproved license: ${license}`);
});
assert(missing.length === 0, `Markstream lockfile packages missing license metadata: ${missing.join(", ")}`);
assert(unapproved.length === 0, `unapproved license metadata: ${JSON.stringify(unapproved)}`);

console.log(JSON.stringify({
  ok: true,
  packages: packageEntries.length,
  licenseCounts: counts
}, null, 2));
