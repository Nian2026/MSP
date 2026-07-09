(function (root, factory) {
  const deps = { status: root.MSPChatUIStatus };
  const api = factory(deps);
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }
  root.MSPChatUITimelineContract = api;
})(typeof globalThis !== "undefined" ? globalThis : window, function ({ status }) {
  const VERSION = "msp.chat-ui.timeline.v1";
  const ROLES = new Set(["user", "assistant", "system", "tool"]);
  const BLOCK_TYPES = new Set([
    "markdown",
    "toolCall",
    "toolGroup",
    "processing",
    "reasoning",
    "progress",
    "videoProgress",
    "proposedPlan",
    "notice",
    "attachment",
    "image",
    "searchResults",
    "searchProgress",
    "sources",
    "textSelection",
    "footer"
  ]);

  function text(value) {
    return typeof value === "string" ? value.trim() : "";
  }

  function list(value) {
    return Array.isArray(value) ? value : [];
  }

  function role(value) {
    const normalized = text(value);
    return ROLES.has(normalized) ? normalized : "assistant";
  }

  function blockType(value) {
    const normalized = text(value);
    return BLOCK_TYPES.has(normalized) ? normalized : "markdown";
  }

  function normalizeBlock(block, index, messageID) {
    const source = block && typeof block === "object" ? block : {};
    const type = blockType(source.type);
    const id = text(source.id) || `${messageID}:block-${index}`;
    return {
      ...source,
      id,
      type,
      status: status.normalizeStatus(source.status, "success")
    };
  }

  function normalizeMessage(message, index) {
    const source = message && typeof message === "object" ? message : {};
    const id = text(source.id) || `message-${index}`;
    return {
      ...source,
      id,
      role: role(source.role),
      status: status.normalizeStatus(source.status, "success"),
      blocks: list(source.blocks).map((block, blockIndex) => normalizeBlock(block, blockIndex, id))
    };
  }

  function normalizeTimeline(timeline) {
    const source = timeline && typeof timeline === "object" ? timeline : {};
    const id = text(source.id) || "default";
    return {
      ...source,
      schema: text(source.schema) || VERSION,
      id,
      title: text(source.title || source.conversationTitle) || "MSP Chat",
      revision: Number.isFinite(source.revision) ? source.revision : 0,
      messages: list(source.messages).map(normalizeMessage),
      presentation: source.presentation && typeof source.presentation === "object"
        ? source.presentation
        : {}
    };
  }

  function validateTimeline(timeline) {
    const errors = [];
    const normalized = normalizeTimeline(timeline);
    if (!normalized.messages.length) {
      errors.push("timeline.messages must contain at least one message");
    }
    normalized.messages.forEach((message, index) => {
      if (!message.id) errors.push(`messages[${index}].id is required`);
      message.blocks.forEach((block, blockIndex) => {
        if (!block.id) errors.push(`messages[${index}].blocks[${blockIndex}].id is required`);
      });
    });
    return { ok: errors.length === 0, errors, value: normalized };
  }

  return Object.freeze({
    VERSION,
    normalizeBlock,
    normalizeMessage,
    normalizeTimeline,
    validateTimeline
  });
});
