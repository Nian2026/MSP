import { createServer } from "node:http";
import { mkdir, writeFile } from "node:fs/promises";
import { readFile } from "node:fs/promises";
import { extname, join, normalize, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";
import assert from "node:assert/strict";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const resultsDir = resolve(root, "results");
const report = {
  status: "running",
  checked_at: new Date().toISOString(),
  screenshots: [],
  assertions: []
};

await mkdir(resultsDir, { recursive: true });

const mime = new Map([
  [".html", "text/html; charset=utf-8"],
  [".css", "text/css; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
  [".ndjson", "application/x-ndjson; charset=utf-8"]
]);

const server = createServer(async (request, response) => {
  try {
    const url = new URL(request.url || "/", "http://127.0.0.1");
    const requested = normalize(decodeURIComponent(url.pathname.replace(/^\/+/u, "")) || "index.html");
    const filePath = resolve(root, requested);
    if (!filePath.startsWith(root + sep) && filePath !== root) {
      response.writeHead(403);
      response.end("Forbidden");
      return;
    }
    const data = await readFile(filePath);
    response.writeHead(200, { "content-type": mime.get(extname(filePath)) || "application/octet-stream" });
    response.end(data);
  } catch {
    response.writeHead(404);
    response.end("Not found");
  }
});

await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
const { port } = server.address();
const baseURL = `http://127.0.0.1:${port}/`;

let browser;
try {
  browser = await chromium.launch();
  await runDesktopChecks(browser);
  await runMobileChecks(browser);
  report.status = "pass";
  await writeFile(join(resultsDir, "lightweight-reader-ui-report.json"), JSON.stringify(report, null, 2) + "\n");
  console.log("lightweight_reader_ui=pass");
} finally {
  await browser?.close();
  await new Promise((resolveClose) => server.close(resolveClose));
}

async function runDesktopChecks(browser) {
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 }, deviceScaleFactor: 1 });
  await page.goto(baseURL, { waitUntil: "networkidle" });
  const desktopScreenshot = join(resultsDir, "desktop-ui-conformance.png");
  await page.screenshot({ path: desktopScreenshot, fullPage: true });
  report.screenshots.push("desktop-ui-conformance.png");

  const eventTypes = await page.locator("[data-event-type]").evaluateAll((nodes) => nodes.map((node) => node.dataset.eventType));
  assert.deepEqual(eventTypes, [
    "message",
    "message",
    "tool_call",
    "tool_output",
    "command_call",
    "command_output",
    "message",
    "tool_call",
    "tool_output",
    "command_output",
    "command_complete",
    "error",
    "artifact_ref",
    "x-demo-extension",
    "message"
  ]);
  report.assertions.push("desktop true timeline event type order");

  const seqs = await page.locator("[data-event-type]").evaluateAll((nodes) => nodes.map((node) => Number(node.dataset.seq)));
  assert.deepEqual(seqs, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]);
  report.assertions.push("desktop seq order");

  const stdoutIndex = eventTypes.findIndex((type, index) => type === "command_output" && seqs[index] === 6);
  const intermediateIndex = eventTypes.findIndex((type, index) => type === "message" && seqs[index] === 7);
  const secondToolCallIndex = eventTypes.findIndex((type, index) => type === "tool_call" && seqs[index] === 8);
  const secondToolOutputIndex = eventTypes.findIndex((type, index) => type === "tool_output" && seqs[index] === 9);
  const stderrIndex = eventTypes.findIndex((type, index) => type === "command_output" && seqs[index] === 10);
  const finalAnswerIndex = eventTypes.findIndex((type, index) => type === "message" && seqs[index] === 15);
  assert.ok(stdoutIndex < intermediateIndex);
  assert.ok(intermediateIndex < secondToolCallIndex);
  assert.ok(secondToolCallIndex < secondToolOutputIndex);
  assert.ok(secondToolOutputIndex < stderrIndex);
  assert.ok(stderrIndex < finalAnswerIndex);
  report.assertions.push("stdout assistant intermediate tool stderr final interleave");

  const messageSeqs = eventTypes
    .map((type, index) => (type === "message" ? seqs[index] : null))
    .filter((seq) => seq !== null);
  const toolSeqs = eventTypes
    .map((type, index) => (type.startsWith("tool_") ? seqs[index] : null))
    .filter((seq) => seq !== null);
  assert.deepEqual(messageSeqs, [1, 2, 7, 15]);
  assert.deepEqual(toolSeqs, [3, 4, 8, 9]);
  report.assertions.push("messages and tool events are not grouped by type");

  await expectVisibleText(page, "Tool call metadata.read");
  await expectVisibleText(page, "Tool call attachment.inspect");
  await expectVisibleText(page, "stdout: ok");
  await expectVisibleText(page, "stderr: warn");
  await expectVisibleText(page, "sample_warning");
  await expectVisibleText(page, "Command transcript artifact");
  await expectVisibleText(page, "Unknown event preserved: x-demo-extension");
  await expectVisibleText(page, "Projection is truncated; canonical timeline data remains intact.");
  report.assertions.push("tool command output error artifact unknown projection warning visible");

  await page.locator("#search-input").fill("stderr");
  assert.equal(await page.locator("[data-event-type]:visible").count(), 2);
  assert.equal(await page.locator("#match-count").textContent(), "2");
  report.assertions.push("search filters canonical timeline text");

  await page.locator("#search-input").fill("");
  await page.locator("#composer-input").fill("Continue from the lightweight reader.");
  await page.locator("#append-user").click();
  assert.equal(await page.locator("[data-seq='16']").count(), 1);
  await expectVisibleText(page, "user: Continue from the lightweight reader.");

  await page.locator("#export-button").click();
  const exportText = await page.locator("#export-output").inputValue();
  const exportBundle = JSON.parse(exportText);
  assert.ok(exportBundle.files["timeline.ndjson"].includes("Continue from the lightweight reader."));
  assert.ok(exportBundle.files["projections/chat-read.ndjson"].includes("truncated"));
  report.assertions.push("append and export preserve projection file");

  await assertNoOverlap(page);
  report.assertions.push("desktop no event card overlap");
  await page.close();
}

async function runMobileChecks(browser) {
  const page = await browser.newPage({ viewport: { width: 390, height: 844 }, isMobile: true });
  await page.goto(baseURL, { waitUntil: "networkidle" });
  const mobileScreenshot = join(resultsDir, "mobile-ui-conformance.png");
  await page.screenshot({ path: mobileScreenshot, fullPage: true });
  report.screenshots.push("mobile-ui-conformance.png");
  await expectVisibleText(page, "Lightweight Reader");
  await expectVisibleText(page, "MSP command: printf ok && printf warn >&2");
  await assertNoOverlap(page);
  report.assertions.push("mobile renders command timeline without overlap");
  await page.close();
}

async function expectVisibleText(page, text) {
  await page.locator(`text=${text}`).first().waitFor({ state: "visible", timeout: 5000 });
}

async function assertNoOverlap(page) {
  const boxes = await page.locator(".event-card:visible").evaluateAll((nodes) => nodes.map((node) => {
    const rect = node.getBoundingClientRect();
    return { top: rect.top, bottom: rect.bottom, height: rect.height };
  }));
  for (const box of boxes) {
    assert.ok(box.height > 24);
  }
  for (let index = 1; index < boxes.length; index += 1) {
    assert.ok(boxes[index].top >= boxes[index - 1].bottom - 0.5, `event cards overlap at ${index}`);
  }
}
