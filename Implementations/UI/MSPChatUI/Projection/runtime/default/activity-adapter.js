(function (root, factory) {
  const api = factory({
    ids: root.MSPChatUIProjectionIdentity,
    status: root.MSPChatUIStatus
  });
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }
  root.MSPChatUIDefaultActivityAdapter = api;
})(typeof globalThis !== "undefined" ? globalThis : window, function ({ ids, status }) {
  function text(value) {
    return typeof value === "string" ? value : "";
  }

  function duration(source) {
    const value = Number(source?.durationMilliseconds ?? source?.durationMs);
    return Number.isFinite(value) ? value : null;
  }

  function itemType(value) {
    const type = text(value?.type);
    if (type === "mainText" || type === "markdown") return "main_text";
    if (type === "webSearch" || type === "web_search") return "web-search";
    if (type === "videoProgress") return "video_progress";
    if (type === "operationSummary") return "operation_summary";
    if (type === "progress") return "progress";
    if (type === "main_text" || type === "web-search" || type === "video_progress" || type === "operation_summary") {
      return type;
    }
    return "tool";
  }

  function title(source) {
    return text(source?.text || source?.title || source?.toolName || source?.name || source?.server);
  }

  function detail(source) {
    return text(source?.detailText || source?.outputText || source?.errorText || source?.error);
  }

  function itemID(source, parentID, index) {
    return text(source?.id || source?.sourceBlockId || source?.sourceBlockID) ||
      ids.stableID([parentID, "item", String(index)]);
  }

  function itemFrom(source, parentID, index, parentStatus = "success") {
    const raw = source && typeof source === "object" ? source : {};
    const id = itemID(raw, parentID, index);
    const resolvedStatus = status.normalizeStatus(raw.status, status.normalizeStatus(parentStatus, "success"));
    const resolvedDuration = duration(raw);
    return {
      ...raw,
      id,
      sourceBlockId: text(raw.sourceBlockId || raw.sourceBlockID) || id,
      type: itemType(raw),
      text: title(raw),
      detailText: detail(raw),
      completed: typeof raw.completed === "boolean" ? raw.completed : !status.isRunning(resolvedStatus),
      status: resolvedStatus,
      durationMilliseconds: resolvedDuration,
      toolName: text(raw.toolName || raw.tool || raw.name),
      toolBatchId: text(raw.toolBatchId || raw.toolBatchID || raw.readexToolBatchId || raw.readexToolBatchID),
      previewItems: Array.isArray(raw.previewItems) ? raw.previewItems : [],
      childItems: Array.isArray(raw.childItems)
        ? raw.childItems.map((child, childIndex) => itemFrom(child, id, childIndex, resolvedStatus)).filter((item) => item.text)
        : [],
      searchQueries: Array.isArray(raw.searchQueries) ? raw.searchQueries : [],
      searchReferences: Array.isArray(raw.searchReferences) ? raw.searchReferences : [],
      webSearchActions: Array.isArray(raw.webSearchActions) ? raw.webSearchActions : []
    };
  }

  function itemFromToolBlock(block, id) {
    return itemFrom({
      ...block,
      id,
      type: "tool",
      text: text(block?.title || block?.text || block?.toolName),
      detailText: detail(block)
    }, id, 0, block?.status);
  }

  function itemsFromBlock(block, id) {
    const candidates = Array.isArray(block?.items) ? block.items
      : (Array.isArray(block?.activities) ? block.activities
        : (Array.isArray(block?.toolCalls) ? block.toolCalls : []));
    if (candidates.length) {
      return candidates.map((item, index) => itemFrom(item, id, index, block?.status)).filter((item) => item.text);
    }
    const item = itemFromToolBlock(block, id);
    return item.text ? [item] : [];
  }

  return Object.freeze({
    itemFrom,
    itemFromToolBlock,
    itemsFromBlock
  });
});
