(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript payload model dependency: ${name}`);
    }
    return value;
  }

  function requiredObject(dependencies, name) {
    const value = dependencies?.[name];
    if (!value || typeof value !== "object") {
      throw new Error(`Missing ChatTranscript payload model dependency: ${name}`);
    }
    return value;
  }

  window.ChatTranscriptPayloadModelFactory = function createChatTranscriptPayloadModel(dependencies) {
    const trimmed = requiredFunction(dependencies, "trimmed");
    const conversationLayout = requiredObject(dependencies, "conversationLayout");
    const buildDerivedConversationGroups = requiredFunction(conversationLayout, "buildDerivedConversationGroups");
    const blockModel = requiredObject(dependencies, "blockModel");
    const normalizedCatalogBlock = requiredFunction(blockModel, "normalizedCatalogBlock");
    const inlineMessageBlocks = requiredFunction(blockModel, "inlineMessageBlocks");
    const messageBlockReferenceIDs = requiredFunction(blockModel, "messageBlockReferenceIDs");
    const setMessageBlockReferences = requiredFunction(blockModel, "setMessageBlockReferences");
    const clearStructuredMessageLegacyState = requiredFunction(blockModel, "clearStructuredMessageLegacyState");
    const messageHasStructuredBlocks = requiredFunction(blockModel, "messageHasStructuredBlocks");
    const normalizeLegacyMessageToStructuredShell = requiredFunction(blockModel, "normalizeLegacyMessageToStructuredShell");
    const structuredMessageStatus = requiredFunction(dependencies, "structuredMessageStatus");
    const structuredMessageShellStatus = requiredFunction(dependencies, "structuredMessageShellStatus");
    let resolvedBlockCatalogSource = null;
    let resolvedBlockCatalogMapCache = null;

    function normalizedMessageGroupRole(value) {
      const role = trimmed(value);
      if (role === "assistant" || role === "steered") {
        return role;
      }
      return "user";
    }

    function resolvePayload() {
      return window.__chatTranscriptPayload || null;
    }

    function orderedMessages() {
      const payload = resolvePayload();
      return Array.isArray(payload?.messages) ? payload.messages : [];
    }

    function messageByID(messageID) {
      const normalizedMessageID = trimmed(messageID);
      if (!normalizedMessageID) {
        return null;
      }

      return orderedMessages().find((message) => trimmed(message?.id) === normalizedMessageID) || null;
    }

    function resetResolvedBlockCatalogCache() {
      resolvedBlockCatalogSource = null;
      resolvedBlockCatalogMapCache = null;
    }

    function resolvedBlockCatalogMap() {
      const payload = resolvePayload();
      const catalog = Array.isArray(payload?.blockCatalog) ? payload.blockCatalog : [];
      if (
        resolvedBlockCatalogSource === catalog &&
        resolvedBlockCatalogMapCache instanceof Map
      ) {
        return resolvedBlockCatalogMapCache;
      }

      const map = new Map();
      catalog.forEach((block) => {
        if (!block || typeof block.id !== "string" || !block.id.length) {
          return;
        }
        map.set(block.id, block);
      });
      resolvedBlockCatalogSource = catalog;
      resolvedBlockCatalogMapCache = map;
      return map;
    }

    function resolvedMessageBlocks(message) {
      const blockIDs = messageBlockReferenceIDs(message);
      if (blockIDs.length) {
        const catalog = resolvedBlockCatalogMap();
        const blocks = blockIDs
          .map((blockID) => catalog.get(blockID))
          .map((block) => normalizedCatalogBlock(block, message))
          .filter((block) => block && typeof block.type === "string");
        if (blocks.length === blockIDs.length) {
          return blocks;
        }
      }

      return inlineMessageBlocks(message).filter((block) => typeof block.type === "string");
    }

    function rebuildPayloadBlockCatalog(payload) {
      if (!payload || typeof payload !== "object") {
        return payload;
      }

      const existingCatalog = new Map(
        (Array.isArray(payload.blockCatalog) ? payload.blockCatalog : [])
          .map((block) => normalizedCatalogBlock(block))
          .filter(Boolean)
          .map((block) => [block.id, block])
      );
      const catalog = [];
      const seenIDs = new Set();
      const messages = Array.isArray(payload.messages) ? payload.messages : [];
      messages.forEach((message) => {
        const inlineBlocks = inlineMessageBlocks(message);
        const inlineBlockByID = new Map(inlineBlocks.map((block) => [block.id, block]));
        const referencedBlockIDs = messageBlockReferenceIDs(message);
        const blockIDs = referencedBlockIDs.length ? referencedBlockIDs : inlineBlocks.map((block) => block.id);

        let resolvedFromCatalog = blockIDs.length > 0;
        blockIDs.forEach((blockID) => {
          const block = existingCatalog.get(blockID) || inlineBlockByID.get(blockID);
          if (!block) {
            resolvedFromCatalog = false;
            return;
          }
          if (seenIDs.has(block.id)) {
            return;
          }
          seenIDs.add(block.id);
          catalog.push(block);
        });

        if (blockIDs.length && resolvedFromCatalog) {
          setMessageBlockReferences(message, blockIDs);
        } else if (!blockIDs.length) {
          message.blocks = inlineBlocks;
          setMessageBlockReferences(message, []);
        }
      });
      payload.blockCatalog = catalog;
      resetResolvedBlockCatalogCache();
      return payload;
    }

    function rebuildPayloadMessageGroups(payload) {
      if (!payload || typeof payload !== "object") {
        return payload;
      }

      const messages = Array.isArray(payload.messages) ? payload.messages : [];
      payload.messageGroups = buildDerivedConversationGroups(messages).map((group) => ({
        id: group.key,
        role: normalizedMessageGroupRole(group.role),
        replyToMessageID: group.replyToMessageID || null,
        messageIDs: group.items
          .map((entry) => trimmed(entry?.message?.id))
          .filter((messageID) => Boolean(messageID))
      }));
      return payload;
    }

    function normalizeStructuredMessageShell(message) {
      if (!message || typeof message !== "object" || !messageHasStructuredBlocks(message)) {
        return message;
      }

      const blockIDs = messageBlockReferenceIDs(message);
      if (blockIDs.length) {
        setMessageBlockReferences(message, blockIDs);
      } else {
        message.blocks = inlineMessageBlocks(message);
        clearStructuredMessageLegacyState(message);
      }

      message.status = structuredMessageStatus(message) || structuredMessageShellStatus(message) || "success";
      return message;
    }

    function normalizedPatchMessageGroup(group) {
      const id = trimmed(group?.id);
      const role = normalizedMessageGroupRole(group?.role);
      const replyToMessageID = trimmed(group?.replyToMessageID);
      const messageIDs = Array.isArray(group?.messageIDs)
        ? group.messageIDs.filter((messageID) => typeof messageID === "string" && messageID.trim().length > 0)
        : [];
      if (!id || !messageIDs.length) {
        return null;
      }
      return {
        id,
        role,
        replyToMessageID: role === "assistant" ? (replyToMessageID || null) : null,
        messageIDs
      };
    }

    function normalizePayloadMessageGroups(payload) {
      if (!payload || typeof payload !== "object") {
        return payload;
      }

      const messages = Array.isArray(payload.messages) ? payload.messages : [];
      const normalizedGroups = (Array.isArray(payload.messageGroups) ? payload.messageGroups : [])
        .map((group) => normalizedPatchMessageGroup(group))
        .filter(Boolean);
      const messageIDs = messages
        .map((message) => trimmed(message?.id))
        .filter((messageID) => Boolean(messageID));

      if (!messageIDs.length) {
        payload.messageGroups = [];
        return payload;
      }

      if (!normalizedGroups.length) {
        rebuildPayloadMessageGroups(payload);
        return payload;
      }

      const messageIDSet = new Set(messageIDs);
      const consumedMessageIDs = new Set();
      const hasValidCoverage = normalizedGroups.every((group) => group.messageIDs.every((messageID) => {
        if (!messageIDSet.has(messageID) || consumedMessageIDs.has(messageID)) {
          return false;
        }
        consumedMessageIDs.add(messageID);
        return true;
      }));

      if (!hasValidCoverage || consumedMessageIDs.size !== messageIDSet.size) {
        rebuildPayloadMessageGroups(payload);
        return payload;
      }

      payload.messageGroups = normalizedGroups;
      return payload;
    }

    function normalizePayloadMessageBlockReferences(payload, catalogMap = null) {
      if (!payload || typeof payload !== "object") {
        return payload;
      }

      let resolvedCatalog = catalogMap instanceof Map
        ? catalogMap
        : new Map(
            (Array.isArray(payload.blockCatalog) ? payload.blockCatalog : [])
              .map((block) => normalizedCatalogBlock(block))
              .filter(Boolean)
              .map((block) => [block.id, block])
          );

      const messages = Array.isArray(payload.messages) ? payload.messages : [];
      const needsCatalogRebuild = messages.some((message) => {
        const legacyBlocks = inlineMessageBlocks(message);
        if (!legacyBlocks.length) {
          return false;
        }

        const blockIDs = messageBlockReferenceIDs(message);
        if (!blockIDs.length) {
          return true;
        }

        return !blockIDs.every((blockID) => resolvedCatalog.has(blockID));
      });

      if (needsCatalogRebuild) {
        rebuildPayloadBlockCatalog(payload);
        resolvedCatalog = resolvedBlockCatalogMap();
      }

      messages.forEach((message) => {
        const inlineBlocks = inlineMessageBlocks(message);
        const blockIDs = messageBlockReferenceIDs(message);

        if (!blockIDs.length) {
          const inlineBlockIDs = inlineBlocks.map((block) => block.id).filter((blockID) => blockID.length > 0);
          if (inlineBlockIDs.length && inlineBlockIDs.every((blockID) => resolvedCatalog.has(blockID))) {
            setMessageBlockReferences(message, inlineBlockIDs);
          } else if (inlineBlockIDs.length) {
            if (Object.prototype.hasOwnProperty.call(message, "blockIDs")) {
              delete message.blockIDs;
            }
            clearStructuredMessageLegacyState(message);
          } else {
            setMessageBlockReferences(message, []);
          }
          return;
        }

        if (blockIDs.every((blockID) => resolvedCatalog.has(blockID))) {
          setMessageBlockReferences(message, blockIDs);
        }
      });

      return payload;
    }

    function normalizePayloadForRendering(payload, catalogMap = null) {
      if (!payload || typeof payload !== "object") {
        return payload;
      }

      normalizePayloadMessageBlockReferences(payload, catalogMap);
      const messages = Array.isArray(payload.messages) ? payload.messages : [];
      let translatedLegacyMessages = false;
      messages.forEach((message) => {
        if (normalizeLegacyMessageToStructuredShell(message)) {
          translatedLegacyMessages = true;
        }
      });
      if (translatedLegacyMessages) {
        rebuildPayloadBlockCatalog(payload);
        normalizePayloadMessageBlockReferences(payload);
      }
      messages.forEach((message) => {
        normalizeStructuredMessageShell(message);
      });
      normalizePayloadMessageGroups(payload);
      return payload;
    }

    return Object.freeze({
      resolvePayload,
      orderedMessages,
      messageByID,
      resetResolvedBlockCatalogCache,
      resolvedBlockCatalogMap,
      resolvedMessageBlocks,
      rebuildPayloadBlockCatalog,
      rebuildPayloadMessageGroups,
      normalizedPatchMessageGroup,
      normalizePayloadMessageBlockReferences,
      normalizePayloadForRendering
    });
  };
})();
