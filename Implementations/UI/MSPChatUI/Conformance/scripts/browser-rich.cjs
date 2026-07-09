#!/usr/bin/env node
const { assert, withDefaultPage } = require("./browser-harness.cjs");

async function main() {
  await withDefaultPage("../../Conformance/fixtures/default-rich.conversation.json", async ({ page }) => {
    await page.waitForSelector(".readex-processing-block");
    await page.waitForSelector(".readex-proposed-plan-card");
    await page.waitForSelector(".readex-markstream-root");
    await page.click("[data-readex-processing-item-key*='scan-tool'] .readex-tool-activity-item");
    await page.waitForSelector(".readex-image-view-preview");
    const result = await page.evaluate(() => {
      const text = document.body.textContent || "";
      const processingLine = document.querySelector(".readex-processing-block .support-line");
      const shimmer = document.querySelector(".readex-tool-shimmer");
      const codeShell = document.querySelector(".code-block-shell, .readex-markstream-code-block-shell, [data-readex-markstream-code-block='1']");
      const mathContent = document.querySelector(".math-block__content");
      const toolIcons = Array.from(document.querySelectorAll(".readex-tool-activity-item svg"));
      const toolIconSignatures = new Set(toolIcons.map((icon) => icon.innerHTML.replace(/\s+/g, " ").trim()));
      const footerActions = Array.from(document.querySelectorAll(".readex-assistant-footer-surface .message-action-button"))
        .map((button) => button.dataset.action || "");
      const subagentName = document.querySelector(".readex-subagent-title-name");
      const articleRects = Array.from(document.querySelectorAll("article.message"))
        .map((node) => node.getBoundingClientRect());
      return {
        articleCount: document.querySelectorAll("article.message").length,
        processingBlocks: document.querySelectorAll(".readex-processing-block").length,
        processingSupportLines: document.querySelectorAll(".readex-processing-block > .support-line").length,
        continuationText: text.includes("同组 continuation"),
        processingExpanded: processingLine?.getAttribute("aria-expanded") || "",
        processingDetails: document.querySelectorAll(".readex-processing-details").length,
        toolItems: document.querySelectorAll(".readex-tool-activity-item").length,
        toolIconSignatureCount: toolIconSignatures.size,
        failedToolText: text.includes("exit 1"),
        proposedPlan: Boolean(document.querySelector(".readex-proposed-plan-card .readex-proposed-plan-action")),
        imagePlaceholder: text.includes("正在生成图片") || text.includes("图片暂不可用"),
        unsafeLinks: document.querySelectorAll("a[href^='javascript:']").length,
        safeLinks: document.querySelectorAll("a[href^='https://example.com']").length,
        mathRendered: document.querySelectorAll(".katex-display, .math-block").length,
        mathOverflow: mathContent ? getComputedStyle(mathContent).overflowX : "",
        codeHeader: Boolean(codeShell?.querySelector(".code-block-header")),
        codeCopy: Boolean(codeShell?.querySelector(".code-block-copy")),
        codeCollapse: Boolean(codeShell?.querySelector(".code-block-toggle")),
        fadeNodes: document.querySelectorAll(".readex-codex-fade-in, .readex-codex-stream-text").length,
        shimmerText: shimmer?.dataset?.shimmerText || shimmer?.textContent || "",
        footerActions,
        assistantFooter: Boolean(document.querySelector(".readex-assistant-footer-surface")),
        footerGoal: Boolean(document.querySelector(".readex-assistant-footer-goal-achieved")),
        footerTime: document.querySelector(".readex-assistant-footer-time")?.textContent || "",
        textSelection: Boolean(document.querySelector(
          ".text-selection-attachment, .text-selection-excerpt-card, .selected-text-reference-chip"
        )),
        videoProgress: Boolean(document.querySelector(".readex-video-progress-card")),
        supportPreview: Boolean(document.querySelector(".readex-image-view-preview, .readex-video-frame-preview")),
        subagentColor: subagentName ? getComputedStyle(subagentName).color : "",
        heading: Boolean(document.querySelector(".readex-markstream-root h2")),
        nestedList: Boolean(document.querySelector(".readex-markstream-root li li")),
        blockquote: Boolean(document.querySelector(".readex-markstream-root blockquote")),
        horizontalRule: Boolean(document.querySelector(".readex-markstream-root hr")),
        footnote: text.includes("脚注用于确认"),
        pagePaddingBottom: getComputedStyle(document.documentElement).getPropertyValue("--chat-page-padding-bottom").trim(),
        maxRight: Math.max(...articleRects.map((rect) => rect.right)),
        minLeft: Math.min(...articleRects.map((rect) => rect.left)),
        width: window.innerWidth
      };
    });
    assert(result.articleCount === 2, `rich fixture article count mismatch: ${JSON.stringify(result)}`);
    assert(result.processingBlocks >= 1 && result.processingDetails >= 1, `processing UI missing: ${JSON.stringify(result)}`);
    assert(result.processingExpanded === "true", `processing should default expanded: ${JSON.stringify(result)}`);
    assert(result.continuationText && result.processingSupportLines === 1, `processing continuation chrome duplicated: ${JSON.stringify(result)}`);
    assert(result.toolItems >= 4 && result.toolIconSignatureCount >= 3, `rich tool rows missing: ${JSON.stringify(result)}`);
    assert(result.failedToolText, `failed tool state missing: ${JSON.stringify(result)}`);
    assert(result.proposedPlan, `proposed plan actions missing: ${JSON.stringify(result)}`);
    assert(result.imagePlaceholder, `image placeholder missing: ${JSON.stringify(result)}`);
    assert(result.unsafeLinks === 0 && result.safeLinks >= 1, `link safety failed: ${JSON.stringify(result)}`);
    assert(result.mathRendered > 0, `math rendering missing: ${JSON.stringify(result)}`);
    assert(result.codeHeader && result.codeCopy && result.codeCollapse, `code controls missing: ${JSON.stringify(result)}`);
    assert(result.fadeNodes > 0, `Codex fade nodes missing: ${JSON.stringify(result)}`);
    assert(result.shimmerText.includes("正在"), `shimmer text missing: ${JSON.stringify(result)}`);
    assert(result.assistantFooter && result.footerGoal && result.footerTime === "刚刚", `assistant footer missing: ${JSON.stringify(result)}`);
    assert(["copyMessage", "branchConversation", "regenerateAssistantMessage", "toggleAssistantModelPicker"]
      .every((action) => result.footerActions.includes(action)), `footer actions missing: ${JSON.stringify(result)}`);
    assert(result.textSelection, `text selection rendering missing: ${JSON.stringify(result)}`);
    assert(result.videoProgress, `video progress rendering missing: ${JSON.stringify(result)}`);
    assert(result.supportPreview, `support preview rendering missing: ${JSON.stringify(result)}`);
    assert(result.subagentColor && result.subagentColor !== "rgba(0, 0, 0, 0)", `subagent accent missing: ${JSON.stringify(result)}`);
    assert(result.heading && result.nestedList && result.blockquote && result.horizontalRule && result.footnote, `markdown spacing fixtures missing: ${JSON.stringify(result)}`);
    assert(result.pagePaddingBottom === "50px", `bottom slack was not applied: ${JSON.stringify(result)}`);
    assert(result.minLeft >= -1 && result.maxRight <= result.width + 1, `layout containment failed: ${JSON.stringify(result)}`);
    console.log(JSON.stringify({ ok: true, rich: result }, null, 2));
  });
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
