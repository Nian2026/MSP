(function (root, factory) {
  const api = factory({ ids: root.MSPChatUIProjectionIdentity });
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }
  root.MSPChatUIPayloadDiff = api;
})(typeof globalThis !== "undefined" ? globalThis : window, function ({ ids }) {
  function stableJSON(value) {
    return JSON.stringify(value ?? null);
  }

  function keyOfMessage(message, index) {
    return ids.messageKey(message, index);
  }

  function keyed(list, keyOf) {
    const map = new Map();
    list.forEach((item, index) => map.set(keyOf(item, index), item));
    return map;
  }

  function changedEntries(next, previousMap, keyOf) {
    return next
      .map((item, index) => ({ key: keyOf(item, index), item }))
      .filter((entry) => stableJSON(entry.item) !== stableJSON(previousMap.get(entry.key)));
  }

  function removedKeys(previous, nextKeys) {
    return previous.filter((key) => !nextKeys.includes(key));
  }

  function metadata(payload) {
    return {
      conversationTitle: payload.conversationTitle,
      theme: payload.theme,
      readexMarkdownRendererProfile: payload.readexMarkdownRendererProfile,
      readexMarkstreamCodeTheme: payload.readexMarkstreamCodeTheme,
      messageActionPolicy: payload.messageActionPolicy || null,
      style: payload.style || null,
      displayWindow: payload.displayWindow || null,
      expandedReadexProcessingBlockIDs: payload.expandedReadexProcessingBlockIDs,
      collapsedReadexProcessingBlockIDs: payload.collapsedReadexProcessingBlockIDs,
      expandedReadexToolActivityBlockIDs: payload.expandedReadexToolActivityBlockIDs,
      collapsedReadexToolActivityBlockIDs: payload.collapsedReadexToolActivityBlockIDs
    };
  }

  function buildPatch(previousPayload, nextPayload) {
    if (!previousPayload || !nextPayload) return null;

    const previousMessages = Array.isArray(previousPayload.messages) ? previousPayload.messages : [];
    const nextMessages = Array.isArray(nextPayload.messages) ? nextPayload.messages : [];
    const previousBlocks = Array.isArray(previousPayload.blockCatalog) ? previousPayload.blockCatalog : [];
    const nextBlocks = Array.isArray(nextPayload.blockCatalog) ? nextPayload.blockCatalog : [];
    const previousGroups = Array.isArray(previousPayload.messageGroups) ? previousPayload.messageGroups : [];
    const nextGroups = Array.isArray(nextPayload.messageGroups) ? nextPayload.messageGroups : [];

    const messageKeys = nextMessages.map(keyOfMessage);
    const blockKeys = nextBlocks.map((block) => block.id);
    const groupKeys = nextGroups.map((group) => group.id);
    const previousMessageKeys = previousMessages.map(keyOfMessage);
    const previousBlockKeys = previousBlocks.map((block) => block.id);
    const previousGroupKeys = previousGroups.map((group) => group.id);

    return {
      metadata: metadata(nextPayload),
      orderedMessageKeys: messageKeys,
      deletedMessageKeys: removedKeys(previousMessageKeys, messageKeys),
      upsertedMessages: changedEntries(nextMessages, keyed(previousMessages, keyOfMessage), keyOfMessage)
        .map((entry) => ({ key: entry.key, message: entry.item })),
      patchedMessages: [],
      orderedCatalogBlockKeys: blockKeys,
      deletedCatalogBlockKeys: removedKeys(previousBlockKeys, blockKeys),
      upsertedCatalogBlocks: changedEntries(nextBlocks, keyed(previousBlocks, (block) => block.id), (block) => block.id)
        .map((entry) => entry.item),
      orderedGroupKeys: groupKeys,
      deletedGroupKeys: removedKeys(previousGroupKeys, groupKeys),
      upsertedGroups: changedEntries(nextGroups, keyed(previousGroups, (group) => group.id), (group) => group.id)
        .map((entry) => ({ key: entry.key, group: entry.item }))
    };
  }

  function patchHasChanges(patch) {
    return Boolean(patch && (
      patch.deletedMessageKeys.length ||
      patch.upsertedMessages.length ||
      patch.deletedCatalogBlockKeys.length ||
      patch.upsertedCatalogBlocks.length ||
      patch.deletedGroupKeys.length ||
      patch.upsertedGroups.length ||
      stableJSON(patch.metadata) !== "{}"
    ));
  }

  return Object.freeze({
    buildPatch,
    patchHasChanges
  });
});
