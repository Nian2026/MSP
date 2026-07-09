#!/usr/bin/env node
const { assert, withDefaultPage } = require("./browser-harness.cjs");

async function main() {
  await withDefaultPage("../../Conformance/fixtures/default-rich.conversation.json", async ({ page }) => {
    await page.waitForSelector(".readex-codex-stream-text, .readex-codex-fade-in");
    const result = await page.evaluate(() => {
      const fade = document.querySelector(".readex-codex-fade-in, .readex-codex-code-fade-in");
      const shimmer = document.querySelector(".readex-tool-shimmer");
      return {
        reduced: window.matchMedia("(prefers-reduced-motion: reduce)").matches,
        fadeDuration: fade ? getComputedStyle(fade).animationDuration : "",
        shimmerActive: shimmer?.classList.contains("readex-tool-shimmer-active") || false
      };
    });
    assert(result.reduced, `reduced motion media emulation failed: ${JSON.stringify(result)}`);
    assert(!result.fadeDuration || result.fadeDuration === "0s", `fade animation should be disabled: ${JSON.stringify(result)}`);
    assert(!result.shimmerActive, `shimmer should not animate in reduced motion: ${JSON.stringify(result)}`);
    console.log(JSON.stringify({ ok: true, reducedMotion: result }, null, 2));
  }, { reducedMotion: "reduce" });
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
