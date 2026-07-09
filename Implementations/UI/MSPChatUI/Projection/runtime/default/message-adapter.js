(function (root, factory) {
  const api = factory({
    ids: root.MSPChatUIProjectionIdentity,
    status: root.MSPChatUIStatus,
    blockAdapter: root.MSPChatUIDefaultBlockAdapter
  });
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }
  root.MSPChatUIDefaultMessageAdapter = api;
})(typeof globalThis !== "undefined" ? globalThis : window, function ({ ids, status, blockAdapter }) {
  function text(value) {
    return typeof value === "string" ? value : "";
  }

  function optionalObject(value) {
    return value && typeof value === "object" && !Array.isArray(value) ? value : undefined;
  }

  function optionalNumber(value) {
    return Number.isFinite(value) ? value : undefined;
  }

  function titleForMessage(message) {
    if (message.role === "assistant") {
      return text(message.modelName) || "Assistant";
    }
    return message.role === "user" ? "You" : message.role;
  }

  function messageToDefault(message, index) {
    const key = ids.messageKey(message, index);
    const blockCatalog = visibleBlocksOrStatus(message, key, blockAdapter.blocksForMessage(message));
    return {
      message: {
        id: message.id,
        patchKey: key,
        role: message.role,
        title: titleForMessage(message),
        status: message.status,
        isStreaming: status.isRunning(message.status),
        timeText: text(message.timeText || message.createdAt),
        completedGoalDurationMilliseconds: optionalNumber(
          message.completedGoalDurationMs ?? message.completedGoalDurationMilliseconds
        ),
        memoryCitation: optionalObject(message.memoryCitation),
        hasRenderPatches: message.hasRenderPatches === true,
        hasEnabledRenderPatches: message.hasEnabledRenderPatches === true,
        blocks: blockCatalog.map((block) => block.id)
      },
      blocks: blockCatalog
    };
  }

  function blockHasVisibleContent(block) {
    if (!block || typeof block !== "object") return false;
    if (block.type === "main_text") return Boolean(text(block.text));
    if (Array.isArray(block.items) && block.items.length > 0) return true;
    if (Array.isArray(block.images) && block.images.length > 0) return true;
    return block.type !== "main_text";
  }

  function emptyStreamingStatusBlock(message, key) {
    const id = ids.stableID([key, "streaming-status"]);
    return {
      id,
      messageID: message.id,
      type: "readex_processing",
      sourceBlockId: id,
      status: "running",
      readexProcessingActive: true,
      items: [{
        id: `${id}:thinking`,
        sourceBlockId: `${id}:thinking`,
        type: "progress",
        status: "running",
        text: "正在思考",
        detailText: "",
        completed: false
      }]
    };
  }

  function visibleBlocksOrStatus(message, key, blocks) {
    if (blocks.some(blockHasVisibleContent)) return blocks;
    if (message.role === "assistant" && status.isRunning(message.status)) {
      return [emptyStreamingStatusBlock(message, key)];
    }
    return blocks;
  }

  return Object.freeze({
    messageToDefault
  });
});
