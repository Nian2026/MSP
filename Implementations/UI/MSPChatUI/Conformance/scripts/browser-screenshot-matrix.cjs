#!/usr/bin/env node
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { assert, readJSON, withDefaultPage } = require("./browser-harness.cjs");

function outputDir() {
  const dir = path.join(os.tmpdir(), "msp-chat-ui-screenshots");
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

async function capture(page, name, viewport, theme = "light") {
  await page.setViewportSize(viewport);
  if (theme === "dark") {
    const fixture = readJSON("Conformance/fixtures/default-rich.conversation.json");
    await page.evaluate(async (timeline) => {
      const next = {
        ...timeline,
        revision: timeline.revision + 1,
        presentation: { ...(timeline.presentation || {}), theme: "dark" }
      };
      await window.MSPChatUIDefaultRenderer.renderTimeline(next);
    }, fixture);
  }
  await page.waitForFunction(() => document.querySelectorAll("article.message").length > 0);
  await page.screenshot({ path: path.join(outputDir(), `${name}.png`), fullPage: true });
  const stat = fs.statSync(path.join(outputDir(), `${name}.png`));
  return { name, bytes: stat.size, viewport, theme };
}

async function main() {
  await withDefaultPage("../../Conformance/fixtures/default-rich.conversation.json", async ({ page }) => {
    const captures = [];
    captures.push(await capture(page, "default-rich-desktop", { width: 1200, height: 900 }));
    captures.push(await capture(page, "default-rich-mobile", { width: 390, height: 760 }));
    captures.push(await capture(page, "default-rich-dark", { width: 960, height: 720 }, "dark"));
    const dom = await page.evaluate(() => ({
      articles: document.querySelectorAll("article.message").length,
      hasFooter: Boolean(document.querySelector(".readex-assistant-footer-surface")),
      hasProcessing: Boolean(document.querySelector(".readex-processing-block")),
      theme: document.documentElement.dataset.theme || ""
    }));
    assert(captures.every((entry) => entry.bytes > 1000), `screenshots are empty: ${JSON.stringify(captures)}`);
    assert(dom.articles >= 2 && dom.hasFooter && dom.hasProcessing && dom.theme === "dark", `screenshot DOM invalid: ${JSON.stringify(dom)}`);
    console.log(JSON.stringify({ ok: true, outputDir: outputDir(), captures, dom }, null, 2));
  });
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
