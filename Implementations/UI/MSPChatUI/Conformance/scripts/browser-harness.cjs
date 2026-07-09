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
  if (filePath.endsWith(".apng")) return "image/apng";
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

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => resolve(server.address().port));
  });
}

function readJSON(relativePath) {
  return JSON.parse(fs.readFileSync(path.join(root, relativePath), "utf8"));
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

async function withDefaultPage(fixturePath, callback, options = {}) {
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
  const page = await browser.newPage({ viewport: options.viewport || { width: 1200, height: 900 } });
  try {
    if (options.reducedMotion) {
      await page.emulateMedia({ reducedMotion: options.reducedMotion });
    }
    const url = new URL(`http://127.0.0.1:${port}/Hosts/Web/default.html`);
    if (fixturePath) url.searchParams.set("fixture", fixturePath);
    await page.goto(url.href, { waitUntil: "networkidle" });
    await page.waitForFunction(() => window.__chatTranscriptRuntimeBootstrap?.stage === "ready");
    await page.waitForFunction(() => document.querySelectorAll("article.message").length > 0);
    return await callback({ page, port, root });
  } finally {
    await browser.close();
    server.close();
  }
}

module.exports = {
  assert,
  readJSON,
  root,
  withDefaultPage
};
