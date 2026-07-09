(function (root, factory) {
  const api = factory({
    timeline: root.MSPChatUITimelineContract,
    store: root.MSPChatUITimelineStore
  });
  root.MSPChatUIExampleMinimalRenderer = api;
})(typeof globalThis !== "undefined" ? globalThis : window, function ({ timeline, store }) {
  let lastTimeline = null;

  function ensureRoot() {
    let root = document.getElementById("msp-chat-ui-example-minimal");
    if (!root) {
      root = document.createElement("main");
      root.id = "msp-chat-ui-example-minimal";
      document.body.appendChild(root);
    }
    return root;
  }

  function renderBlock(block) {
    const element = document.createElement("section");
    element.dataset.blockId = block.id;
    element.dataset.blockType = block.type;
    element.textContent = block.text || block.title || block.toolName || "";
    return element;
  }

  function renderTimeline(input) {
    const normalized = timeline.normalizeTimeline(input);
    const root = ensureRoot();
    root.replaceChildren();
    normalized.messages.forEach((message) => {
      const article = document.createElement("article");
      article.dataset.messageId = message.id;
      article.dataset.role = message.role;
      article.dataset.status = message.status;
      message.blocks.forEach((block) => article.appendChild(renderBlock(block)));
      root.appendChild(article);
    });
    lastTimeline = normalized;
    return { messageCount: normalized.messages.length };
  }

  function applyRuntimeEvent(event) {
    if (!lastTimeline && event?.type !== "timeline.replace") {
      throw new Error("ExampleMinimal requires renderTimeline before incremental events.");
    }
    const nextTimeline = store.applyRuntimeEvent(lastTimeline || event.timeline, event);
    return renderTimeline(nextTimeline);
  }

  function reset() {
    lastTimeline = null;
    const root = document.getElementById("msp-chat-ui-example-minimal");
    if (root) root.replaceChildren();
  }

  return Object.freeze({
    renderTimeline,
    applyRuntimeEvent,
    reset
  });
});
