#!/usr/bin/env node
const { assert, withDefaultPage } = require("./browser-harness.cjs");

async function main() {
  await withDefaultPage("../../Conformance/fixtures/default-rich.conversation.json", async ({ page }) => {
    const result = await page.evaluate(async () => {
      const events = [];
      window.addEventListener("msp-chat-ui-host-message", (event) => {
        events.push(event.detail);
      });
      window.webkit.messageHandlers.copyCode.postMessage({ text: "abc" });
      window.MSPChatUIHostBridgeCompat.postMessage("openAttachment", { messageID: "m1", attachmentIndex: 0 });
      const customCalls = [];
      window.MSPChatUIHost = {
        postMessage(channel, payload) {
          customCalls.push({ channel, payload });
        }
      };
      window.MSPChatUIHostBridgeCompat.postMessage("messageAction", { action: "copy" });
      await new Promise((resolve) => setTimeout(resolve, 0));
      return { events, customCalls, channels: window.MSPChatUIHostBridgeCompat.channels };
    });
    assert(result.events.length === 2, `browser fallback events missing: ${JSON.stringify(result)}`);
    assert(result.customCalls.length === 1 && result.customCalls[0].channel === "messageAction", `custom host bridge missing: ${JSON.stringify(result)}`);
    assert(result.channels.includes("presentationProbe") && result.channels.includes("copyCode"), `bridge channels incomplete: ${JSON.stringify(result)}`);
    console.log(JSON.stringify({ ok: true, hostBridge: result }, null, 2));
  });
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
