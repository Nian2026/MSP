#!/usr/bin/env node
const { assert, withDefaultPage } = require("./browser-harness.cjs");

async function main() {
  await withDefaultPage("../../Conformance/fixtures/default-empty-streaming.conversation.json", async ({ page }) => {
    await page.waitForSelector(".readex-processing-block");
    const result = await page.evaluate(() => ({
      articleCount: document.querySelectorAll("article.message").length,
      processingBlocks: document.querySelectorAll(".readex-processing-block").length,
      shimmer: document.querySelector(".readex-tool-shimmer")?.textContent || "",
      bodyText: document.body.textContent || "",
      assistantBubbleBackground: getComputedStyle(document.querySelectorAll(".message-bubble")[1]).backgroundColor
    }));
    assert(result.articleCount === 2, `empty streaming article count mismatch: ${JSON.stringify(result)}`);
    assert(result.processingBlocks === 1, `empty streaming processing line missing: ${JSON.stringify(result)}`);
    assert(result.bodyText.includes("正在思考") && result.shimmer.includes("正在思考"), `empty streaming shimmer missing: ${JSON.stringify(result)}`);
    assert(result.assistantBubbleBackground === "rgba(0, 0, 0, 0)", `assistant bubble should be transparent: ${JSON.stringify(result)}`);
    console.log(JSON.stringify({ ok: true, emptyStreaming: result }, null, 2));
  });
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
