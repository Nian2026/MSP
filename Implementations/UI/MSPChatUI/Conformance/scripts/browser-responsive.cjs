#!/usr/bin/env node
const { assert, withDefaultPage } = require("./browser-harness.cjs");

async function checkViewport(viewport) {
  return withDefaultPage("../../Conformance/fixtures/default-rich.conversation.json", async ({ page }) => {
    const result = await page.evaluate(() => {
      const articles = Array.from(document.querySelectorAll("article.message"));
      const rects = articles.map((article) => article.getBoundingClientRect());
      const codeBlocks = Array.from(document.querySelectorAll(".code-block-shell, [data-readex-markstream-code-block='1']"));
      const maxCodeRight = Math.max(0, ...codeBlocks.map((node) => node.getBoundingClientRect().right));
      return {
        width: window.innerWidth,
        articleCount: articles.length,
        minLeft: Math.min(...rects.map((rect) => rect.left)),
        maxRight: Math.max(...rects.map((rect) => rect.right)),
        maxCodeRight
      };
    });
    assert(result.articleCount === 2, `responsive article count mismatch: ${JSON.stringify(result)}`);
    assert(result.minLeft >= -1 && result.maxRight <= result.width + 1, `message overflow at ${viewport.width}: ${JSON.stringify(result)}`);
    assert(result.maxCodeRight <= result.width + 1, `code overflow at ${viewport.width}: ${JSON.stringify(result)}`);
    return result;
  }, { viewport });
}

async function main() {
  const tablet = await checkViewport({ width: 768, height: 900 });
  const wide = await checkViewport({ width: 1600, height: 950 });
  console.log(JSON.stringify({ ok: true, tablet, wide }, null, 2));
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
