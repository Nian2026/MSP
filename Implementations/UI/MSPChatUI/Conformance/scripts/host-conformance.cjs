#!/usr/bin/env node
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..", "..");

function read(relativePath) {
  return fs.readFileSync(path.join(root, relativePath), "utf8");
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function walk(dir, files = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(fullPath, files);
    else files.push(fullPath);
  }
  return files;
}

const apple = read("Hosts/Apple/Sources/MSPChatUIAppleHost/MSPChatUIWebViewHost.swift");
const windows = read("Hosts/Windows/src/msp-chat-ui-webview2-host.ts");
const android = read("Hosts/Android/src/main/java/dev/msp/chatui/MSPChatUIWebViewHost.java");
const bridge = read("Renderers/Default/runtime/bridge/msp-host-bridge-compat.js");
const loader = read("Renderers/Default/runtime/loader/default-web-loader.js");
const hostFiles = walk(path.join(root, "Hosts"));
const forbiddenCopies = hostFiles.filter((filePath) => (
  /chat-transcript|markstream|readex-markstream|katex|highlight|diff2html/.test(path.basename(filePath)) &&
  !filePath.endsWith("NativeWebViewContract.md")
));

assert(apple.includes("WKWebView"), "Apple host must wrap WKWebView");
assert(apple.includes("waitForRenderer"), "Apple host must call public Web renderer API");
assert(apple.includes("applyRuntimeEvent"), "Apple host must expose runtime event entrypoint");
assert(apple.includes("defaultReadAccessRoot"), "Apple host must grant the packaged renderer asset root");
assert(apple.includes("WeakScriptMessageHandler"), "Apple host must not retain itself through WKScriptMessageHandler");
assert(apple.includes("deinit"), "Apple host must remove WKScriptMessageHandler registrations");
assert(windows.includes("CoreWebView2"), "Windows host must wrap WebView2");
assert(windows.includes("waitForRenderer"), "Windows host must call public Web renderer API");
assert(windows.includes("applyRuntimeEvent"), "Windows host must expose runtime event entrypoint");
assert(android.includes("WebView"), "Android host must wrap WebView");
assert(android.includes("JavascriptInterface"), "Android host must bridge native messages");
assert(android.includes("applyRuntimeEvent"), "Android host must expose runtime event entrypoint");
assert(bridge.includes("MSPChatUIAndroidHost"), "Default bridge must support Android host");
assert(bridge.includes("chrome?.webview"), "Default bridge must support WebView2 host");
assert(bridge.includes("messageHandlers"), "Default bridge must support WKWebView host");
assert(bridge.includes("__CHAT_TRANSCRIPT_SELECTION_CONTEXT_MENU_HANDLER_NAME__"), "Default bridge must expose selection context menu handler");
assert(apple.includes("__CHAT_TRANSCRIPT_SELECTION_CONTEXT_MENU_HANDLER_NAME__"), "Apple host must bridge selection context menu events");
assert(loader.includes("selectionContextMenuUserScriptName"), "Default loader must load selection context menu runtime");
assert(forbiddenCopies.length === 0, `hosts must not copy renderer assets: ${forbiddenCopies.join(", ")}`);

console.log(JSON.stringify({
  ok: true,
  hosts: ["Apple", "Windows", "Android", "Web"],
  hostFiles: hostFiles.length
}, null, 2));
