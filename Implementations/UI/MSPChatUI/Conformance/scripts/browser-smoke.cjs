#!/usr/bin/env node
const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..", "..");
const requireBrowser = process.env.MSP_CHAT_UI_REQUIRE_BROWSER === "1";

function contentType(filePath) {
  if (filePath.endsWith(".html")) return "text/html";
  if (filePath.endsWith(".js")) return "text/javascript";
  if (filePath.endsWith(".css")) return "text/css";
  if (filePath.endsWith(".json")) return "application/json";
  if (filePath.endsWith(".woff2")) return "font/woff2";
  if (filePath.endsWith(".woff")) return "font/woff";
  if (filePath.endsWith(".ttf")) return "font/ttf";
  return "application/octet-stream";
}

function createServer() {
  return http.createServer((request, response) => {
    const url = new URL(request.url, "http://127.0.0.1");
    const relativePath = decodeURIComponent(url.pathname.replace(/^\/+/, ""));
    const filePath = path.join(root, relativePath || "Hosts/Web/default.html");
    if (!filePath.startsWith(root) || !fs.existsSync(filePath) || fs.statSync(filePath).isDirectory()) {
      response.writeHead(404);
      response.end("Not found");
      return;
    }
    response.writeHead(200, { "content-type": contentType(filePath) });
    fs.createReadStream(filePath).pipe(response);
  });
}

async function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => resolve(server.address().port));
  });
}

async function main() {
  let playwright;
  try {
    playwright = require("playwright");
  } catch (error) {
    if (requireBrowser) throw error;
    console.log(JSON.stringify({ ok: true, skipped: "playwright unavailable" }, null, 2));
    return;
  }

  const server = createServer();
  const port = await listen(server);
  const executablePath = process.env.CHROME_PATH || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
  const launchOptions = fs.existsSync(executablePath) ? { executablePath } : {};
  const browser = await playwright.chromium.launch({ headless: true, ...launchOptions });
  const page = await browser.newPage({ viewport: { width: 1200, height: 900 } });
  try {
    const url = `http://127.0.0.1:${port}/Hosts/Web/default.html`;
    await page.goto(url, { waitUntil: "networkidle" });
    await page.waitForFunction(() => window.__chatTranscriptRuntimeBootstrap?.stage === "ready");
    await page.waitForFunction(() => document.querySelectorAll("article.message").length >= 3);
    const result = await page.evaluate(() => {
      const bubbles = Array.from(document.querySelectorAll(".message-bubble"));
      const userBubble = bubbles[0] ? getComputedStyle(bubbles[0]) : null;
      const assistantBubble = bubbles[1] ? getComputedStyle(bubbles[1]) : null;
      const toolIcons = Array.from(document.querySelectorAll(".readex-tool-activity-item svg"));
      const toolIconSignatures = new Set(toolIcons.map((icon) => icon.innerHTML.replace(/\s+/g, " ").trim()));
      const toolCpuFallbackCount = toolIcons
        .filter((icon) => icon.outerHTML.includes("M9 1.5v3M15 1.5v3"))
        .length;
      return {
        stage: window.__chatTranscriptRuntimeBootstrap?.stage,
        articleCount: document.querySelectorAll("article.message").length,
        profile: window.__chatTranscriptPayload?.readexMarkdownRendererProfile,
        hasKatex: document.querySelectorAll(".katex").length > 0,
        hasCode: document.querySelectorAll("pre code, .code-block-container").length > 0,
        hasTable: document.querySelectorAll("table").length > 0,
        hasTool: document.querySelectorAll(".readex-tool-activity-item").length > 0,
        hasShimmer: document.querySelectorAll(".readex-tool-shimmer").length > 0,
        toolItemCount: document.querySelectorAll(".readex-tool-activity-item").length,
        toolIconCount: toolIcons.length,
        toolIconSignatureCount: toolIconSignatures.size,
        toolCpuFallbackCount,
        hasFailedToolText: (document.body.textContent || "").includes("permission denied"),
        userBubbleBackground: userBubble?.backgroundColor || "",
        assistantBubbleBackground: assistantBubble?.backgroundColor || ""
      };
    });
    if (
      result.stage !== "ready" ||
      result.articleCount < 3 ||
      !result.hasTool ||
      !result.hasShimmer ||
      !result.hasCode ||
      !result.hasTable ||
      !result.hasKatex ||
      !result.hasFailedToolText ||
      result.toolIconSignatureCount < 3 ||
      result.toolCpuFallbackCount !== 0
    ) {
      throw new Error(`Browser smoke failed: ${JSON.stringify(result)}`);
    }
    const fixture = JSON.parse(fs.readFileSync(path.join(root, "Conformance/fixtures/default-basic.conversation.json"), "utf8"));
    const darkResult = await page.evaluate(async (timeline) => {
      const darkTimeline = {
        ...timeline,
        revision: timeline.revision + 1,
        presentation: { ...(timeline.presentation || {}), theme: "dark" }
      };
      await window.MSPChatUIDefaultRenderer.updateTimeline(darkTimeline);
      await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      return {
        rootTheme: document.documentElement.dataset.theme || "",
        colorScheme: getComputedStyle(document.documentElement).colorScheme || "",
        background: getComputedStyle(document.body).backgroundColor || "",
        appBackgroundToken: getComputedStyle(document.documentElement).getPropertyValue("--app-bg").trim()
      };
    }, fixture);
    if (
      darkResult.rootTheme !== "dark" ||
      !darkResult.colorScheme.includes("dark") ||
      darkResult.background === "rgb(244, 241, 234)" ||
      darkResult.appBackgroundToken === "#f4f1ea"
    ) {
      throw new Error(`Browser dark theme failed: ${JSON.stringify(darkResult)}`);
    }
    await page.setViewportSize({ width: 390, height: 760 });
    const mobileResult = await page.evaluate(() => {
      const articles = Array.from(document.querySelectorAll("article.message"));
      const maxRight = Math.max(...articles.map((article) => article.getBoundingClientRect().right));
      const minLeft = Math.min(...articles.map((article) => article.getBoundingClientRect().left));
      return {
        innerWidth: window.innerWidth,
        minLeft,
        maxRight,
        articleCount: articles.length
      };
    });
    if (mobileResult.articleCount < 3 || mobileResult.minLeft < -1 || mobileResult.maxRight > mobileResult.innerWidth + 1) {
      throw new Error(`Browser mobile layout failed: ${JSON.stringify(mobileResult)}`);
    }
    const updateText = " 浏览器 conformance 追加的流式内容。";
    const updateResult = await page.evaluate(async ({ updateText }) => {
      const operationPromise = new Promise((resolve) => {
        window.addEventListener("msp-chat-ui-default-updated", (event) => {
          resolve({
            operationKind: event.detail?.operation?.kind || "",
            updateCount: event.detail?.operation?.update?.updates?.length || 0,
            commandResult: event.detail?.result || null
          });
        }, { once: true });
      });
      await window.MSPChatUIDefaultRenderer.applyRuntimeEvent({
        type: "stream.delta",
        messageID: "assistant-2",
        blockID: "assistant-2:text",
        textDelta: updateText,
        status: "running"
      });
      const operation = await operationPromise;
      await new Promise((resolve, reject) => {
        const started = performance.now();
        const needle = updateText.trim();
        function poll() {
          if ((document.body.textContent || "").includes(needle)) {
            resolve();
            return;
          }
          if (performance.now() - started > 3000) {
            reject(new Error("streaming text did not become visible before timeout"));
            return;
          }
          window.setTimeout(poll, 25);
        }
        poll();
      });
      const bodyText = document.body.textContent || "";
      return {
        ...operation,
        domContainsAppend: bodyText.includes(updateText.trim())
      };
    }, { updateText });
    if (updateResult.operationKind !== "directStreamingUpdate" || !updateResult.domContainsAppend) {
      throw new Error(`Browser streaming update failed: ${JSON.stringify(updateResult)}`);
    }
    console.log(JSON.stringify({ ok: true, ...result, dark: darkResult, mobile: mobileResult, streamingUpdate: updateResult }, null, 2));
  } finally {
    await browser.close();
    server.close();
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
