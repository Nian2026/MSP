(function (root, factory) {
  const api = factory({
    ids: root.MSPChatUIProjectionIdentity,
    status: root.MSPChatUIStatus,
    activity: root.MSPChatUIDefaultActivityAdapter
  });
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }
  root.MSPChatUIDefaultBlockAdapter = api;
})(typeof globalThis !== "undefined" ? globalThis : window, function ({ ids, status, activity }) {
  function text(value) {
    return typeof value === "string" ? value : "";
  }

  function toolCallBlock(message, block, id) {
    return {
      id,
      messageID: message.id,
      type: "readex_tool_call",
      sourceBlockId: block.id,
      status: block.status,
      text: text(block.title || block.text || block.toolName),
      detailText: text(block.detailText || block.outputText || block.errorText),
      toolName: text(block.toolName),
      durationMilliseconds: Number.isFinite(block.durationMs) ? block.durationMs : null,
      items: [activity.itemFromToolBlock(block, id)]
    };
  }

  function toolGroupBlock(message, block, id) {
    return {
      id,
      messageID: message.id,
      type: "readex_tool_activity",
      sourceBlockId: block.id,
      status: block.status,
      text: text(block.title),
      items: activity.itemsFromBlock(block, id)
    };
  }

  function processingBlock(message, block, id) {
    return {
      id,
      messageID: message.id,
      type: "readex_processing",
      sourceBlockId: block.id,
      status: block.status,
      text: text(block.title || block.text),
      items: activity.itemsFromBlock(block, id),
      readexProcessingActive: block.active === true || status.isRunning(block.status),
      readexProcessingGroupId: text(block.groupID || block.groupId),
      readexProcessingChromeRole: text(block.chromeRole),
      readexTurnStartedAtMilliseconds: Number.isFinite(block.startedAtMs) ? block.startedAtMs : null,
      readexTurnDurationMilliseconds: Number.isFinite(block.durationMs) ? block.durationMs : null
    };
  }

  function blockToDefault(message, block, index) {
    const id = ids.blockID(message, block, index);
    if (block.type === "toolCall") return toolCallBlock(message, block, id);
    if (block.type === "toolGroup") return toolGroupBlock(message, block, id);
    if (block.type === "processing") return processingBlock(message, block, id);
    if (block.type === "reasoning") {
      return { id, messageID: message.id, type: "thinking", status: block.status, text: text(block.text) };
    }
    if (block.type === "progress") {
      return {
        id,
        messageID: message.id,
        type: "readex_progress",
        status: block.status,
        text: text(block.title),
        detailText: text(block.detailText),
        progress: Number.isFinite(block.progress) ? block.progress : null
      };
    }
    if (block.type === "videoProgress") {
      return { ...block, id, messageID: message.id, type: "readex_video_progress", sourceBlockId: block.id };
    }
    if (block.type === "proposedPlan") {
      return { ...block, id, messageID: message.id, type: "proposed_plan", sourceBlockId: block.id, text: text(block.text) };
    }
    if (block.type === "attachment") {
      return { ...block, id, messageID: message.id, type: "attachments", attachments: Array.isArray(block.attachments) ? block.attachments : [] };
    }
    if (block.type === "image") {
      return { ...block, id, messageID: message.id, type: "image", images: Array.isArray(block.images) ? block.images : [] };
    }
    if (block.type === "searchResults") {
      return { ...block, id, messageID: message.id, type: "search_results" };
    }
    if (block.type === "searchProgress") {
      return { ...block, id, messageID: message.id, type: "search_progress" };
    }
    if (block.type === "sources") {
      return { ...block, id, messageID: message.id, type: "sources" };
    }
    if (block.type === "textSelection") {
      return { ...block, id, messageID: message.id, type: "text_selection" };
    }
    if (block.type === "footer") {
      return { ...block, id, messageID: message.id, type: "footer", text: text(block.text) };
    }
    if (block.type === "notice") {
      return { id, messageID: message.id, type: "readex_context_status", status: block.status, text: text(block.text) };
    }
    return { id, messageID: message.id, type: "main_text", status: block.status, text: text(block.text) };
  }

  function blocksForMessage(message) {
    return message.blocks.map((block, index) => blockToDefault(message, block, index));
  }

  return Object.freeze({
    blockToDefault,
    blocksForMessage
  });
});
