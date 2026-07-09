(function (root, factory) {
  const api = factory({
    diff: root.MSPChatUIPayloadDiff,
    ids: root.MSPChatUIProjectionIdentity
  });
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }
  root.MSPChatUIRenderPlanner = api;
})(typeof globalThis !== "undefined" ? globalThis : window, function ({ diff, ids }) {
  function stableJSON(value) {
    return JSON.stringify(value ?? null);
  }

  function onlyPresentationChanged(previous, next) {
    return stableJSON(previous.payload) === stableJSON(next.payload) &&
      stableJSON(previous.presentation) !== stableJSON(next.presentation);
  }

  function catalogMap(payload) {
    return new Map((payload.blockCatalog || []).map((block) => [block.id, block]));
  }

  function comparableMessage(message) {
    const next = { ...(message || {}) };
    delete next.status;
    delete next.isStreaming;
    return next;
  }

  function directUpdateKind(afterBlock) {
    if (afterBlock?.type === "main_text") return "main_text";
    if (afterBlock?.type === "readex_processing") return "readex_processing";
    return "";
  }

  function directStreamingUpdate(previous, next) {
    const previousMessages = previous.payload.messages || [];
    const nextMessages = next.payload.messages || [];
    if (previousMessages.length !== nextMessages.length) return null;

    const beforeCatalog = catalogMap(previous.payload);
    const afterCatalog = catalogMap(next.payload);
    let changed = null;
    for (let index = 0; index < nextMessages.length; index += 1) {
      const before = previousMessages[index];
      const after = nextMessages[index];
      if (ids.messageKey(before, index) !== ids.messageKey(after, index)) return null;
      if (stableJSON(comparableMessage(before)) !== stableJSON(comparableMessage(after))) return null;

      const blockIDs = Array.isArray(after.blocks) ? after.blocks : [];
      for (const blockID of blockIDs) {
        const beforeBlock = beforeCatalog.get(blockID);
        const afterBlock = afterCatalog.get(blockID);
        if (stableJSON(beforeBlock) !== stableJSON(afterBlock)) {
          if (changed) return null;
          changed = { before, after, beforeBlock, afterBlock, index };
        }
      }
    }
    if (!changed || changed.after.role !== "assistant") return null;
    if (changed.before.isStreaming !== true && changed.after.isStreaming !== true) return null;
    const { beforeBlock, afterBlock } = changed;
    if (!beforeBlock || !afterBlock || beforeBlock.id !== afterBlock.id) return null;
    const kind = directUpdateKind(afterBlock);
    if (!kind) return null;
    if (kind === "main_text" && !String(afterBlock.text || "").startsWith(String(beforeBlock.text || ""))) return null;

    return {
      updates: [{
        kind,
        messageKey: ids.messageKey(changed.after, changed.index),
        blockID: afterBlock.id,
        block: afterBlock,
        messageState: changed.after,
        syncMessageChrome: true
      }]
    };
  }

  function plan(previous, next) {
    if (!previous) {
      return { kind: "fullRender", payload: next.payload, presentation: next.presentation };
    }
    if (stableJSON(previous.payload) === stableJSON(next.payload) &&
      stableJSON(previous.presentation) === stableJSON(next.presentation)) {
      return { kind: "scrollSync" };
    }
    if (onlyPresentationChanged(previous, next)) {
      return { kind: "presentationOnlyUpdate", presentation: next.presentation };
    }
    const streamingUpdate = directStreamingUpdate(previous, next);
    if (streamingUpdate) {
      return { kind: "directStreamingUpdate", update: streamingUpdate, presentation: next.presentation };
    }
    const patch = diff.buildPatch(previous.payload, next.payload);
    if (diff.patchHasChanges(patch)) {
      return { kind: "payloadPatch", patch, presentation: next.presentation };
    }
    return { kind: "scrollSync" };
  }

  return Object.freeze({
    plan
  });
});
