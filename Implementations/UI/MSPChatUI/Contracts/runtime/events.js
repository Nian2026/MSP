(function (root, factory) {
  const api = factory({
    status: root.MSPChatUIStatus
  });
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }
  root.MSPChatUIRuntimeEvents = api;
})(typeof globalThis !== "undefined" ? globalThis : window, function ({ status }) {
  const VERSION = "msp.chat-ui.event.v1";
  const EVENT_TYPES = new Set([
    "timeline.replace",
    "presentation.update",
    "message.upsert",
    "message.remove",
    "message.status",
    "message.patch",
    "block.upsert",
    "block.remove",
    "block.status",
    "block.patch",
    "stream.delta",
    "tool.lifecycle",
    "interaction.collapse",
    "selection.update",
    "scroll.sync"
  ]);

  function text(value) {
    return typeof value === "string" ? value.trim() : "";
  }

  function eventType(value) {
    const normalized = text(value);
    return EVENT_TYPES.has(normalized) ? normalized : "";
  }

  function normalizeRuntimeEvent(event, index = 0) {
    const source = event && typeof event === "object" ? event : {};
    return {
      ...source,
      schema: text(source.schema) || VERSION,
      id: text(source.id) || `event-${index}`,
      type: eventType(source.type),
      messageID: text(source.messageID || source.messageId),
      blockID: text(source.blockID || source.blockId),
      status: source.status === undefined ? undefined : status.normalizeStatus(source.status, "success"),
      textDelta: typeof source.textDelta === "string" ? source.textDelta : "",
      collapsed: typeof source.collapsed === "boolean" ? source.collapsed : undefined,
      patch: source.patch && typeof source.patch === "object" ? source.patch : undefined,
      timestamp: text(source.timestamp)
    };
  }

  function validateRuntimeEvent(event, index = 0) {
    const normalized = normalizeRuntimeEvent(event, index);
    const errors = [];
    if (!normalized.type) errors.push("event.type is required");
    if (normalized.type.startsWith("message.") && normalized.type !== "message.upsert" && !normalized.messageID) {
      errors.push(`${normalized.type} requires messageID`);
    }
    if (
      (
        normalized.type.startsWith("block.") ||
        normalized.type === "stream.delta" ||
        normalized.type === "tool.lifecycle" ||
        normalized.type === "interaction.collapse"
      ) && !normalized.messageID
    ) {
      errors.push(`${normalized.type} requires messageID`);
    }
    if (
      (
        normalized.type.startsWith("block.") ||
        normalized.type === "stream.delta" ||
        normalized.type === "tool.lifecycle" ||
        normalized.type === "interaction.collapse"
      ) && !normalized.blockID
    ) {
      errors.push(`${normalized.type} requires blockID`);
    }
    return { ok: errors.length === 0, errors, value: normalized };
  }

  return Object.freeze({
    VERSION,
    normalizeRuntimeEvent,
    validateRuntimeEvent
  });
});
