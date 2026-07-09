#!/usr/bin/env node
const { assert, readJSON, withDefaultPage } = require("./browser-harness.cjs");

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function longTimeline() {
  const messages = [];
  for (let index = 0; index < 12; index += 1) {
    messages.push({
      id: `user-${index}`,
      role: "user",
      blocks: [{ id: `user-${index}:text`, type: "markdown", text: `user ${index}` }]
    });
    messages.push({
      id: `assistant-${index}`,
      role: "assistant",
      status: "success",
      blocks: [{ id: `assistant-${index}:text`, type: "markdown", text: `assistant ${index}` }]
    });
  }
  return {
    schema: "msp.chat-ui.timeline.v1",
    id: "windowing",
    revision: 1,
    presentation: { displayWindow: { startIndex: 0, displayCount: 4 } },
    messages
  };
}

async function main() {
  const fixture = readJSON("Conformance/fixtures/default-rich.conversation.json");
  await withDefaultPage("../../Conformance/fixtures/default-rich.conversation.json", async ({ page }) => {
    const first = await page.evaluate(() => {
      window.__mspActionEvents = [];
      window.addEventListener("msp-chat-ui-host-message", (event) => {
        window.__mspActionEvents.push(event.detail);
      });
      const actions = Array.from(document.querySelectorAll(".readex-assistant-footer-surface .message-action-button"))
        .map((button) => button.dataset.action || "");
      const userActions = Array.from(document.querySelectorAll("article.message:first-of-type .message-action-button"))
        .map((button) => button.dataset.action || "");
      return {
        actions,
        userActions,
        policy: window.__chatTranscriptPresentation?.messageActionPolicy || null,
        payloadPolicy: window.__chatTranscriptPayload?.messageActionPolicy || null
      };
    });
    assert(first.actions.includes("copyMessage") && first.userActions.includes("editUserMessage"), `action slots missing: ${JSON.stringify(first)}`);
    assert(first.policy?.assistantPlacement === "readexAssistantFooter", `presentation policy missing: ${JSON.stringify(first)}`);
    assert(first.payloadPolicy?.assistantActions?.includes("branchConversation"), `payload policy missing: ${JSON.stringify(first)}`);

    await page.hover(".readex-assistant-footer-surface .message-action-button[data-action='copyMessage']");
    await page.waitForTimeout(850);
    const tooltip = await page.evaluate(() => document.querySelector(".readex-assistant-footer-tooltip")?.textContent || "");
    assert(tooltip.includes("复制"), `footer tooltip missing: ${tooltip}`);

    await page.click(".readex-assistant-footer-surface .message-action-button[data-action='copyMessage']");
    await page.click(".readex-assistant-footer-surface .message-action-button[data-action='branchConversation']");
    const clicked = await page.evaluate(() => window.__mspActionEvents.map((entry) => entry.payload?.action || entry.channel));
    assert(clicked.includes("copyMessage") && clicked.includes("branchConversation"), `footer click bridge missing: ${JSON.stringify(clicked)}`);

    const patchResult = await page.evaluate(async (timeline) => {
      const next = JSON.parse(JSON.stringify(timeline));
      next.revision += 1;
      next.messages[1].blocks.push({
        id: "assistant-rich:patch-notice",
        type: "notice",
        status: "success",
        text: "patch metadata check"
      });
      const event = new Promise((resolve) => {
        window.addEventListener("msp-chat-ui-default-updated", (update) => resolve(update.detail?.operation || null), { once: true });
      });
      await window.MSPChatUIDefaultRenderer.updateTimeline(next);
      return event;
    }, fixture);
    assert(patchResult.kind === "payloadPatch", `metadata update did not use payloadPatch: ${JSON.stringify(patchResult)}`);
    assert(patchResult.patch?.metadata?.messageActionPolicy?.assistantActions?.includes("copyMessage"), "patch metadata lost action policy");

    const stableColor = await page.evaluate(async (timeline) => {
      const before = getComputedStyle(document.querySelector(".readex-subagent-title-name")).color;
      const next = JSON.parse(JSON.stringify(timeline));
      next.revision += 1;
      const block = next.messages[1].blocks.find((entry) => entry.id === "assistant-rich:processing");
      block.items.find((entry) => entry.id === "assistant-rich:processing-note").text += " 稳定色检查。";
      await window.MSPChatUIDefaultRenderer.updateTimeline(next);
      await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      const after = getComputedStyle(document.querySelector(".readex-subagent-title-name")).color;
      return { before, after };
    }, fixture);
    assert(stableColor.before && stableColor.before === stableColor.after, `subagent color changed: ${JSON.stringify(stableColor)}`);

    const windowed = await page.evaluate(async (timeline) => {
      await window.MSPChatUIDefaultRenderer.renderTimeline(timeline);
      await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      const text = document.body.textContent || "";
      return {
        articleCount: document.querySelectorAll("article.message").length,
        hasLast: text.includes("assistant 11"),
        hasFirst: text.includes("assistant 0"),
        displayWindow: window.__chatTranscriptPayload?.displayWindow || null
      };
    }, longTimeline());
    assert(windowed.articleCount <= 6 && windowed.hasLast && !windowed.hasFirst, `displayWindow failed: ${JSON.stringify(windowed)}`);
    assert(windowed.displayWindow?.displayCount === 4, `displayWindow metadata missing: ${JSON.stringify(windowed)}`);
    console.log(JSON.stringify({ ok: true, actions: first.actions, clicked, stableColor, windowed }, null, 2));
  }, { viewport: { width: 960, height: 620 } });
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
