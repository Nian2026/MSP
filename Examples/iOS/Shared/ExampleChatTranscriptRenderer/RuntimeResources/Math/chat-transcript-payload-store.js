(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript payload store dependency: ${name}`);
    }
    return value;
  }

  function requiredObject(dependencies, name) {
    const value = dependencies?.[name];
    if (!value || typeof value !== "object") {
      throw new Error(`Missing ChatTranscript payload store dependency: ${name}`);
    }
    return value;
  }

  window.ChatTranscriptPayloadStoreFactory = function createChatTranscriptPayloadStore(dependencies) {
    const payloadModel = requiredObject(dependencies, "payloadModel");
    const payloadPatcher = requiredObject(dependencies, "payloadPatcher");
    const resolvePayload = requiredFunction(payloadModel, "resolvePayload");
    const orderedMessages = requiredFunction(payloadModel, "orderedMessages");
    const messageByID = requiredFunction(payloadModel, "messageByID");
    const resolvedBlockCatalogMap = requiredFunction(payloadModel, "resolvedBlockCatalogMap");
    const resolvedMessageBlocks = requiredFunction(payloadModel, "resolvedMessageBlocks");
    const normalizedPatchMessageGroup = requiredFunction(payloadModel, "normalizedPatchMessageGroup");
    const rebuildPayloadBlockCatalog = requiredFunction(payloadModel, "rebuildPayloadBlockCatalog");
    const rebuildPayloadMessageGroups = requiredFunction(payloadModel, "rebuildPayloadMessageGroups");
    const normalizePayloadMessageBlockReferences = requiredFunction(payloadModel, "normalizePayloadMessageBlockReferences");
    const normalizePayloadForRendering = requiredFunction(payloadModel, "normalizePayloadForRendering");
    const applyPatchMetadataToPayload = requiredFunction(payloadPatcher, "applyPatchMetadataToPayload");
    const mergePatchIntoPayload = requiredFunction(payloadPatcher, "mergePatchIntoPayload");

    return Object.freeze({
      resolvePayload,
      orderedMessages,
      messageByID,
      resolvedBlockCatalogMap,
      resolvedMessageBlocks,
      applyPatchMetadataToPayload,
      normalizedPatchMessageGroup,
      rebuildPayloadBlockCatalog,
      rebuildPayloadMessageGroups,
      normalizePayloadMessageBlockReferences,
      normalizePayloadForRendering,
      mergePatchIntoPayload
    });
  };
})();
