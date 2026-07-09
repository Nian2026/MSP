#!/usr/bin/env node
const { assert, readJSON, withDefaultPage } = require("./browser-harness.cjs");

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function updateProcessing(timeline, suffix) {
  const next = clone(timeline);
  next.revision += 1;
  const block = next.messages[1].blocks.find((entry) => entry.id === "assistant-rich:processing");
  block.items.find((entry) => entry.id === "assistant-rich:processing-note").text += suffix;
  return next;
}

function updateMainText(timeline, suffix) {
  const next = clone(timeline);
  next.revision += 1;
  const block = next.messages[1].blocks.find((entry) => entry.id === "assistant-rich:text");
  block.text += suffix;
  return next;
}

function finalizeAssistant(timeline) {
  const next = clone(timeline);
  next.revision += 1;
  const message = next.messages[1];
  const block = message.blocks.find((entry) => entry.id === "assistant-rich:text");
  message.status = "success";
  block.status = "success";
  block.streaming = false;
  return next;
}

async function updateTimeline(page, timeline) {
  return page.evaluate(async (nextTimeline) => {
    const update = new Promise((resolve) => {
      window.addEventListener("msp-chat-ui-default-updated", (event) => {
        resolve({
          kind: event.detail?.operation?.kind || "",
          updateKind: event.detail?.operation?.update?.updates?.[0]?.kind || "",
          result: event.detail?.result || null
        });
      }, { once: true });
    });
    await window.MSPChatUIDefaultRenderer.updateTimeline(nextTimeline);
    return update;
  }, timeline);
}

async function applyRuntimeEvent(page, event) {
  return page.evaluate(async (runtimeEvent) => {
    const update = new Promise((resolve) => {
      window.addEventListener("msp-chat-ui-default-updated", (domEvent) => {
        resolve({
          kind: domEvent.detail?.operation?.kind || "",
          updateKind: domEvent.detail?.operation?.update?.updates?.[0]?.kind || "",
          result: domEvent.detail?.result || null
        });
      }, { once: true });
    });
    await window.MSPChatUIDefaultRenderer.applyRuntimeEvent(runtimeEvent);
    return update;
  }, event);
}

async function main() {
  const fixture = readJSON("Conformance/fixtures/default-rich.conversation.json");
  await withDefaultPage("../../Conformance/fixtures/default-rich.conversation.json", async ({ page }) => {
    const scrollBeforeProcessing = await page.evaluate(() => {
      const root = document.scrollingElement || document.documentElement;
      root.scrollTop = Math.min(120, Math.max(root.scrollHeight - root.clientHeight, 0));
      return root.scrollTop;
    });
    const processingNext = updateProcessing(fixture, " 直接更新 processing 明细。");
    const processingResult = await updateTimeline(page, processingNext);
    await page.waitForFunction(() => (document.body.textContent || "").includes("直接更新 processing"));
    const processingDOM = await page.evaluate(() => ({
      text: document.body.textContent || "",
      articles: document.querySelectorAll("article.message").length,
      processingDetails: document.querySelectorAll(".readex-processing-details").length
    }));
    const scrollAfterProcessing = await page.evaluate(() => (document.scrollingElement || document.documentElement).scrollTop);
    const iconStatsAfter = await page.evaluate(() => {
      const icons = Array.from(document.querySelectorAll(".readex-tool-activity-item svg"));
      return {
        signatures: new Set(icons.map((icon) => icon.innerHTML.replace(/\s+/g, " ").trim())).size,
        cpuFallback: icons.filter((icon) => icon.outerHTML.includes("M9 1.5v3M15 1.5v3")).length
      };
    });
    assert(processingResult.kind === "directStreamingUpdate" && processingDOM.text.includes("直接更新 processing"), "processing update did not execute");
    assert(processingDOM.articles === 2 && processingDOM.processingDetails >= 1, `processing DOM unstable: ${JSON.stringify(processingDOM)}`);
    assert(Math.abs(scrollAfterProcessing - scrollBeforeProcessing) <= 4, `non-live-edge scroll moved: ${scrollBeforeProcessing} -> ${scrollAfterProcessing}`);
    assert(iconStatsAfter.signatures >= 3 && iconStatsAfter.cpuFallback <= 1, `tool icon diversity regressed: ${JSON.stringify(iconStatsAfter)}`);

    const collapsed = await applyRuntimeEvent(page, {
      type: "interaction.collapse",
      messageID: "assistant-rich",
      blockID: "assistant-rich:processing",
      collapsed: true
    });
    const collapsedDOM = await page.evaluate(() => ({
      kind: document.querySelector(".readex-processing-block .support-line")?.getAttribute("aria-expanded") || "",
      details: document.querySelectorAll(".readex-processing-details").length
    }));
    assert(collapsed.kind === "payloadPatch", `collapse should patch expansion metadata: ${JSON.stringify(collapsed)}`);
    assert(collapsedDOM.kind === "false" || collapsedDOM.details === 0, `processing did not collapse: ${JSON.stringify(collapsedDOM)}`);

    const liveSuffix = "\n\n贴近底部时应该自动跟随。";
    const mainNext = updateMainText(processingNext, liveSuffix);
    const liveEdge = await page.evaluate(async ({ timeline, suffix }) => {
      const root = document.scrollingElement || document.documentElement;
      root.scrollTop = Math.max(root.scrollHeight - root.clientHeight, 0);
      await window.MSPChatUIDefaultRenderer.updateTimeline(timeline);
      await new Promise((resolve, reject) => {
        const started = performance.now();
        function poll() {
          if ((document.body.textContent || "").includes(suffix.trim())) {
            resolve();
            return;
          }
          if (performance.now() - started > 3000) {
            reject(new Error("live-edge text was not visible before timeout"));
            return;
          }
          window.setTimeout(poll, 25);
        }
        poll();
      });
      const max = Math.max(root.scrollHeight - root.clientHeight, 0);
      return { distance: max - root.scrollTop, max, text: document.body.textContent || "" };
    }, { timeline: mainNext, suffix: liveSuffix });
    assert(liveEdge.text.includes("贴近底部") && liveEdge.distance <= 66, `live-edge scroll failed: ${JSON.stringify(liveEdge)}`);
    const finalizeNext = finalizeAssistant(mainNext);
    const finalized = await page.evaluate(async (timeline) => {
      const before = document.querySelector("[data-block-key='assistant-rich:text']");
      const update = new Promise((resolve) => {
        window.addEventListener("msp-chat-ui-default-updated", (event) => {
          resolve({ kind: event.detail?.operation?.kind || "" });
        }, { once: true });
      });
      await window.MSPChatUIDefaultRenderer.updateTimeline(timeline);
      const operation = await update;
      const after = document.querySelector("[data-block-key='assistant-rich:text']");
      return { ...operation, sameBlock: before === after, articles: document.querySelectorAll("article.message").length };
    }, finalizeNext);
    assert(finalized.kind === "directStreamingUpdate" && finalized.sameBlock && finalized.articles === 2, `finalization reflowed DOM: ${JSON.stringify(finalized)}`);
    console.log(JSON.stringify({ ok: true, processingDOM, collapsedDOM, liveEdge, finalized }, null, 2));
  }, { viewport: { width: 900, height: 420 } });
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
