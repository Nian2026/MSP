#!/usr/bin/env node
const { assert, withDefaultPage } = require("./browser-harness.cjs");

async function main() {
  await withDefaultPage("../../Conformance/fixtures/default-rich.conversation.json", async ({ page }) => {
    await page.evaluate(() => {
      window.__chatTranscriptSelectionContextMenuOptions = { usesCodexSelectedTextOverlay: true };
      window.__mspSelectionEvents = [];
      window.addEventListener("msp-chat-ui-host-message", (event) => {
        if (event.detail?.channel === "__CHAT_TRANSCRIPT_SELECTION_CONTEXT_MENU_HANDLER_NAME__") {
          window.__mspSelectionEvents.push(event.detail.payload);
        }
      });
    });
    const box = await page.locator("[data-block-type='main_text'] .text-node").nth(1).boundingBox();
    assert(Boolean(box), "selection target text node missing");
    await page.mouse.move(box.x + 2, box.y + box.height / 2);
    await page.mouse.down();
    await page.mouse.move(box.x + Math.min(130, box.width - 2), box.y + box.height / 2, { steps: 10 });
    await page.mouse.up();
    await page.waitForSelector(".ai-reading-selected-text-overlay");
    const beforeClick = await page.evaluate(() => {
      const overlay = document.querySelector(".ai-reading-selected-text-overlay");
      const selection = window.getSelection();
      const selectedRect = selection?.rangeCount ? selection.getRangeAt(0).getBoundingClientRect() : null;
      const overlayRect = overlay?.getBoundingClientRect();
      return {
        selectedText: String(selection || ""),
        overlay: overlayRect ? {
          left: overlayRect.left,
          right: overlayRect.right,
          top: overlayRect.top,
          bottom: overlayRect.bottom
        } : null,
        selected: selectedRect ? {
          left: selectedRect.left,
          right: selectedRect.right,
          top: selectedRect.top,
          bottom: selectedRect.bottom
        } : null
      };
    });
    await page.click(".ai-reading-selected-text-overlay button");
    const events = await page.evaluate(() => window.__mspSelectionEvents.map((entry) => entry.type || ""));
    const overlay = beforeClick.overlay;
    const selected = beforeClick.selected;
    assert(beforeClick.selectedText.length > 0 && Boolean(overlay) && Boolean(selected), `selection overlay missing: ${JSON.stringify(beforeClick)}`);
    assert(overlay.left >= 0 && overlay.right <= 1200 && overlay.top >= 0, `overlay outside viewport: ${JSON.stringify(beforeClick)}`);
    assert(overlay.bottom <= selected.top || overlay.top >= selected.bottom, `overlay overlaps selected text: ${JSON.stringify(beforeClick)}`);
    assert(events.includes("addToChat"), `overlay action did not reach host bridge: ${JSON.stringify(events)}`);
    console.log(JSON.stringify({ ok: true, beforeClick, events }, null, 2));
  }, { viewport: { width: 1200, height: 900 } });
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
