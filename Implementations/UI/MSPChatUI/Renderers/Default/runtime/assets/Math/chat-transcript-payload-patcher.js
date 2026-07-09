(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript payload patcher dependency: ${name}`);
    }
    return value;
  }

  function requiredObject(dependencies, name) {
    const value = dependencies?.[name];
    if (!value || typeof value !== "object") {
      throw new Error(`Missing ChatTranscript payload patcher dependency: ${name}`);
    }
    return value;
  }

  window.ChatTranscriptPayloadPatcherFactory = function createChatTranscriptPayloadPatcher(dependencies) {
    const trimmed = requiredFunction(dependencies, "trimmed");
    const messageDOMKey = requiredFunction(dependencies, "messageDOMKey");
    const conversationLayout = requiredObject(dependencies, "conversationLayout");
    const normalizeDisplayWindow = requiredFunction(conversationLayout, "normalizeDisplayWindow");
    const blockModel = requiredObject(dependencies, "blockModel");
    const normalizedCatalogBlock = requiredFunction(blockModel, "normalizedCatalogBlock");
    const inlineMessageBlocks = requiredFunction(blockModel, "inlineMessageBlocks");
    const messageBlockReferenceIDs = requiredFunction(blockModel, "messageBlockReferenceIDs");
    const setMessageBlockReferences = requiredFunction(blockModel, "setMessageBlockReferences");
    const clearStructuredMessageLegacyState = requiredFunction(blockModel, "clearStructuredMessageLegacyState");
    const messageHasStructuredBlocks = requiredFunction(blockModel, "messageHasStructuredBlocks");
    const postTranscriptProbe = requiredFunction(dependencies, "postTranscriptProbe");
    const payloadModel = requiredObject(dependencies, "payloadModel");
    const resolvePayload = requiredFunction(payloadModel, "resolvePayload");
    const resetResolvedBlockCatalogCache = requiredFunction(payloadModel, "resetResolvedBlockCatalogCache");
    const resolvedBlockCatalogMap = requiredFunction(payloadModel, "resolvedBlockCatalogMap");
    const rebuildPayloadBlockCatalog = requiredFunction(payloadModel, "rebuildPayloadBlockCatalog");
    const rebuildPayloadMessageGroups = requiredFunction(payloadModel, "rebuildPayloadMessageGroups");
    const normalizedPatchMessageGroup = requiredFunction(payloadModel, "normalizedPatchMessageGroup");
    const normalizePayloadForRendering = requiredFunction(payloadModel, "normalizePayloadForRendering");

    function applyPatchMetadataToPayload(payload, metadata) {
      if (!payload || !metadata || typeof metadata !== "object") {
        return payload;
      }

      payload.conversationTitle = typeof metadata.conversationTitle === "string"
        ? metadata.conversationTitle
        : payload.conversationTitle;
      payload.theme = typeof metadata.theme === "string" ? metadata.theme : payload.theme;
      if (Object.prototype.hasOwnProperty.call(metadata, "readexMarkdownRendererProfile")) {
        const rendererProfile = typeof metadata.readexMarkdownRendererProfile === "string"
          ? metadata.readexMarkdownRendererProfile.trim()
          : "";
        if (rendererProfile) {
          payload.readexMarkdownRendererProfile = rendererProfile;
        } else {
          delete payload.readexMarkdownRendererProfile;
        }
      }
      if (Object.prototype.hasOwnProperty.call(metadata, "readexMarkstreamCodeTheme")) {
        const codeTheme = typeof metadata.readexMarkstreamCodeTheme === "string"
          ? metadata.readexMarkstreamCodeTheme.trim()
          : "";
        if (codeTheme) {
          payload.readexMarkstreamCodeTheme = codeTheme;
        } else {
          delete payload.readexMarkstreamCodeTheme;
        }
      }
      if (Object.prototype.hasOwnProperty.call(metadata, "messageActionPolicy")) {
        if (metadata.messageActionPolicy && typeof metadata.messageActionPolicy === "object") {
          payload.messageActionPolicy = metadata.messageActionPolicy;
        } else {
          delete payload.messageActionPolicy;
        }
      }
      payload.style = metadata.style || null;
      if (Object.prototype.hasOwnProperty.call(metadata, "displayWindow")) {
        const displayWindow = normalizeDisplayWindow(metadata.displayWindow);
        if (displayWindow) {
          payload.displayWindow = displayWindow;
        } else {
          delete payload.displayWindow;
        }
      }
      if (Object.prototype.hasOwnProperty.call(metadata, "expandedReadexProcessingBlockIDs")) {
        if (Array.isArray(metadata.expandedReadexProcessingBlockIDs)) {
          payload.expandedReadexProcessingBlockIDs = metadata.expandedReadexProcessingBlockIDs;
        } else {
          delete payload.expandedReadexProcessingBlockIDs;
        }
      }
      if (Object.prototype.hasOwnProperty.call(metadata, "collapsedReadexProcessingBlockIDs")) {
        if (Array.isArray(metadata.collapsedReadexProcessingBlockIDs)) {
          payload.collapsedReadexProcessingBlockIDs = metadata.collapsedReadexProcessingBlockIDs;
        } else {
          delete payload.collapsedReadexProcessingBlockIDs;
        }
      }
      if (Object.prototype.hasOwnProperty.call(metadata, "expandedReadexToolActivityBlockIDs")) {
        if (Array.isArray(metadata.expandedReadexToolActivityBlockIDs)) {
          payload.expandedReadexToolActivityBlockIDs = metadata.expandedReadexToolActivityBlockIDs;
        } else {
          delete payload.expandedReadexToolActivityBlockIDs;
        }
      }
      if (Object.prototype.hasOwnProperty.call(metadata, "collapsedReadexToolActivityBlockIDs")) {
        if (Array.isArray(metadata.collapsedReadexToolActivityBlockIDs)) {
          payload.collapsedReadexToolActivityBlockIDs = metadata.collapsedReadexToolActivityBlockIDs;
        } else {
          delete payload.collapsedReadexToolActivityBlockIDs;
        }
      }
      if (Object.prototype.hasOwnProperty.call(metadata, "expandedReadexNestedDisclosureKeysBySourceBlockID")) {
        const keysBySourceID = metadata.expandedReadexNestedDisclosureKeysBySourceBlockID;
        if (keysBySourceID && typeof keysBySourceID === "object" && !Array.isArray(keysBySourceID)) {
          payload.expandedReadexNestedDisclosureKeysBySourceBlockID = keysBySourceID;
        } else {
          delete payload.expandedReadexNestedDisclosureKeysBySourceBlockID;
        }
      }
      if (Object.prototype.hasOwnProperty.call(metadata, "collapsedReadexNestedDisclosureKeysBySourceBlockID")) {
        const keysBySourceID = metadata.collapsedReadexNestedDisclosureKeysBySourceBlockID;
        if (keysBySourceID && typeof keysBySourceID === "object" && !Array.isArray(keysBySourceID)) {
          payload.collapsedReadexNestedDisclosureKeysBySourceBlockID = keysBySourceID;
        } else {
          delete payload.collapsedReadexNestedDisclosureKeysBySourceBlockID;
        }
      }
      return payload;
    }

    function patchStateHasLegacyFields(state) {
      return Boolean(state && typeof state === "object" && (
        Object.prototype.hasOwnProperty.call(state, "content") ||
        Object.prototype.hasOwnProperty.call(state, "supportBlocks") ||
        Object.prototype.hasOwnProperty.call(state, "isStreaming") ||
        Object.prototype.hasOwnProperty.call(state, "isSearchInProgress")
      ));
    }

    function patchedMessageUsesCatalogBlocks(patchedMessage) {
      return Boolean(patchedMessage && typeof patchedMessage === "object" &&
        Array.isArray(patchedMessage.orderedBlockKeys) &&
        !Object.prototype.hasOwnProperty.call(patchedMessage, "upsertedBlocks") &&
        !Object.prototype.hasOwnProperty.call(patchedMessage, "deletedBlockKeys"));
    }

    function applyPatchedMessageState(message, state, options = {}) {
      if (!message || !state || typeof state !== "object") {
        return message;
      }

      const hasStructuredBlocks = Boolean(options.structuredBlocks) || messageHasStructuredBlocks(message);
      if (typeof state.id === "string") {
        message.id = state.id;
      }
      if (typeof state.patchKey === "string") {
        message.patchKey = state.patchKey;
      } else if (Object.prototype.hasOwnProperty.call(state, "patchKey")) {
        delete message.patchKey;
      }
      message.role = typeof state.role === "string" ? state.role : message.role;
      message.replyToMessageID = typeof state.replyToMessageID === "string" ? state.replyToMessageID : null;
      message.title = typeof state.title === "string" ? state.title : message.title;
      message.timeText = typeof state.timeText === "string" ? state.timeText : message.timeText;
      if (typeof state.renderHarness === "string") {
        message.renderHarness = state.renderHarness;
      } else if (Object.prototype.hasOwnProperty.call(state, "renderHarness")) {
        delete message.renderHarness;
      }
      message.headerPageSummary = typeof state.headerPageSummary === "string" ? state.headerPageSummary : null;
      message.footerPageSummary = typeof state.footerPageSummary === "string" ? state.footerPageSummary : null;
      if (Number.isFinite(state.completedGoalDurationMilliseconds)) {
        message.completedGoalDurationMilliseconds = state.completedGoalDurationMilliseconds;
      } else if (Object.prototype.hasOwnProperty.call(state, "completedGoalDurationMilliseconds")) {
        delete message.completedGoalDurationMilliseconds;
      }
      if (typeof state.branchNoticeText === "string") {
        message.branchNoticeText = state.branchNoticeText;
      } else if (Object.prototype.hasOwnProperty.call(state, "branchNoticeText")) {
        delete message.branchNoticeText;
      }
      if (state.memoryCitation && typeof state.memoryCitation === "object" && !Array.isArray(state.memoryCitation)) {
        message.memoryCitation = state.memoryCitation;
      } else if (Object.prototype.hasOwnProperty.call(state, "memoryCitation")) {
        delete message.memoryCitation;
      }
      message.attachments = Array.isArray(state.attachments) ? state.attachments : [];
      message.status = typeof state.status === "string" ? state.status : message.status;
      if (!hasStructuredBlocks && patchStateHasLegacyFields(state) && typeof state.content === "string") {
        message.content = state.content;
      }
      if (!hasStructuredBlocks && patchStateHasLegacyFields(state) && Array.isArray(state.supportBlocks)) {
        message.supportBlocks = state.supportBlocks;
      }
      if (!hasStructuredBlocks && patchStateHasLegacyFields(state) && typeof state.isStreaming === "boolean") {
        message.isStreaming = state.isStreaming;
      }
      if (!hasStructuredBlocks && patchStateHasLegacyFields(state) && typeof state.isSearchInProgress === "boolean") {
        message.isSearchInProgress = state.isSearchInProgress;
      }
      if (typeof state.hasRenderPatches === "boolean") {
        message.hasRenderPatches = state.hasRenderPatches;
      }
      if (typeof state.hasEnabledRenderPatches === "boolean") {
        message.hasEnabledRenderPatches = state.hasEnabledRenderPatches;
      }
      if (typeof state.expertDomainID === "string") {
        message.expertDomainID = state.expertDomainID;
      } else if (Object.prototype.hasOwnProperty.call(state, "expertDomainID")) {
        delete message.expertDomainID;
      }
      if (typeof state.expertDomainName === "string") {
        message.expertDomainName = state.expertDomainName;
      } else if (Object.prototype.hasOwnProperty.call(state, "expertDomainName")) {
        delete message.expertDomainName;
      }
      if (typeof state.expertDomainUsesGlobalPrompt === "boolean") {
        message.expertDomainUsesGlobalPrompt = state.expertDomainUsesGlobalPrompt;
      } else if (Object.prototype.hasOwnProperty.call(state, "expertDomainUsesGlobalPrompt")) {
        delete message.expertDomainUsesGlobalPrompt;
      }
      if (typeof state.expertRoutingStatus === "string") {
        message.expertRoutingStatus = state.expertRoutingStatus;
      } else if (Object.prototype.hasOwnProperty.call(state, "expertRoutingStatus")) {
        delete message.expertRoutingStatus;
      }
      if (typeof state.expertRoutingSummary === "string") {
        message.expertRoutingSummary = state.expertRoutingSummary;
      } else if (Object.prototype.hasOwnProperty.call(state, "expertRoutingSummary")) {
        delete message.expertRoutingSummary;
      }
      if (typeof state.expertRoutingReason === "string") {
        message.expertRoutingReason = state.expertRoutingReason;
      } else if (Object.prototype.hasOwnProperty.call(state, "expertRoutingReason")) {
        delete message.expertRoutingReason;
      }
      if (typeof state.expertRoutingFailureMessage === "string") {
        message.expertRoutingFailureMessage = state.expertRoutingFailureMessage;
      } else if (Object.prototype.hasOwnProperty.call(state, "expertRoutingFailureMessage")) {
        delete message.expertRoutingFailureMessage;
      }
      if (typeof state.expertRoutingDetail === "string") {
        message.expertRoutingDetail = state.expertRoutingDetail;
      } else if (Object.prototype.hasOwnProperty.call(state, "expertRoutingDetail")) {
        delete message.expertRoutingDetail;
      }
      if (typeof state.expertRoutingConfidence === "number") {
        message.expertRoutingConfidence = state.expertRoutingConfidence;
      } else if (Object.prototype.hasOwnProperty.call(state, "expertRoutingConfidence")) {
        delete message.expertRoutingConfidence;
      }
      if (typeof state.expertRoutingModelName === "string") {
        message.expertRoutingModelName = state.expertRoutingModelName;
      } else if (Object.prototype.hasOwnProperty.call(state, "expertRoutingModelName")) {
        delete message.expertRoutingModelName;
      }

      if (hasStructuredBlocks) {
        clearStructuredMessageLegacyState(message);
      }

      return message;
    }

    function normalizedPatchCatalogBlocks(blocks) {
      if (!Array.isArray(blocks)) {
        return [];
      }

      return blocks
        .map((block) => normalizedCatalogBlock(block))
        .filter(Boolean);
    }

    function normalizedPatchUpsertedGroups(groups) {
      if (!Array.isArray(groups)) {
        return [];
      }

      return groups
        .map((entry) => {
          const key = trimmed(entry?.key);
          const group = normalizedPatchMessageGroup(entry?.group);
          if (!key || !group) {
            return null;
          }
          return { key, group };
        })
        .filter(Boolean);
    }

    function changedCatalogBlockKeysFromPatch(patch) {
      const changedKeys = new Set();
      if (!patch || typeof patch !== "object") {
        return changedKeys;
      }

      normalizedPatchCatalogBlocks(patch.upsertedCatalogBlocks).forEach((block) => {
        changedKeys.add(block.id);
      });
      if (Array.isArray(patch.deletedCatalogBlockKeys)) {
        patch.deletedCatalogBlockKeys.forEach((key) => {
          const normalizedKey = trimmed(key);
          if (normalizedKey) {
            changedKeys.add(normalizedKey);
          }
        });
      }
      return changedKeys;
    }

    function messageReferencesAnyBlock(message, blockKeys) {
      if (!message || !(blockKeys instanceof Set) || blockKeys.size === 0) {
        return false;
      }

      const referencedIDs = messageBlockReferenceIDs(message);
      if (referencedIDs.some((blockID) => blockKeys.has(blockID))) {
        return true;
      }

      return inlineMessageBlocks(message).some((block) => blockKeys.has(block.id));
    }

    function markMessagesReferencingCatalogBlocks(payload, blockKeys, changedMessageKeys) {
      if (!payload || typeof payload !== "object" || !(blockKeys instanceof Set) || blockKeys.size === 0) {
        return [];
      }
      if (!(changedMessageKeys instanceof Set)) {
        return [];
      }

      const addedKeys = [];
      const messages = Array.isArray(payload.messages) ? payload.messages : [];
      messages.forEach((message, index) => {
        if (!messageReferencesAnyBlock(message, blockKeys)) {
          return;
        }

        const messageKey = messageDOMKey(message, index);
        if (!changedMessageKeys.has(messageKey)) {
          addedKeys.push(messageKey);
        }
        changedMessageKeys.add(messageKey);
      });
      return addedKeys;
    }

    function patchMetadataChangesReadexExpansion(metadata) {
      return Boolean(metadata && typeof metadata === "object" && (
        Object.prototype.hasOwnProperty.call(metadata, "expandedReadexProcessingBlockIDs") ||
        Object.prototype.hasOwnProperty.call(metadata, "collapsedReadexProcessingBlockIDs") ||
        Object.prototype.hasOwnProperty.call(metadata, "expandedReadexToolActivityBlockIDs") ||
        Object.prototype.hasOwnProperty.call(metadata, "collapsedReadexToolActivityBlockIDs") ||
        Object.prototype.hasOwnProperty.call(metadata, "expandedReadexNestedDisclosureKeysBySourceBlockID") ||
        Object.prototype.hasOwnProperty.call(metadata, "collapsedReadexNestedDisclosureKeysBySourceBlockID")
      ));
    }

    function stringArrayFromPatch(value) {
      return Array.isArray(value)
        ? value.filter((key) => typeof key === "string" && key.length > 0)
        : [];
    }

    function sameStringArray(lhs, rhs) {
      if (!Array.isArray(lhs) || !Array.isArray(rhs) || lhs.length !== rhs.length) {
        return false;
      }
      return lhs.every((value, index) => value === rhs[index]);
    }

    function stableJSONString(value) {
      if (value === undefined) {
        return "undefined";
      }
      try {
        return JSON.stringify(value ?? null);
      } catch (_) {
        return String(value);
      }
    }

    function normalizedDisplayWindowKey(value) {
      const displayWindow = normalizeDisplayWindow(value);
      if (!displayWindow) {
        return "null";
      }
      return `${displayWindow.startIndex}:${displayWindow.displayCount}`;
    }

    function blockHasReadexExpansionSurface(block) {
      const type = typeof block?.type === "string" ? block.type : "";
      return type === "readex_processing" ||
        type === "readex_tool_call" ||
        type === "readex_tool_activity" ||
        type === "readex_progress";
    }

    function messageHasReadexExpansionSurface(message, catalogMap = null) {
      if (!message || typeof message !== "object") {
        return false;
      }

      const referencedIDs = messageBlockReferenceIDs(message);
      if (referencedIDs.length) {
        const resolvedCatalog = catalogMap instanceof Map ? catalogMap : resolvedBlockCatalogMap();
        if (referencedIDs.some((blockID) => blockHasReadexExpansionSurface(resolvedCatalog.get(blockID)))) {
          return true;
        }
      }

      return inlineMessageBlocks(message).some(blockHasReadexExpansionSurface);
    }

    function markMessagesWithReadexExpansionSurface(payload, catalogMap, changedMessageKeys) {
      if (!payload || typeof payload !== "object" || !(changedMessageKeys instanceof Set)) {
        return [];
      }

      const addedKeys = [];
      const messages = Array.isArray(payload.messages) ? payload.messages : [];
      messages.forEach((message, index) => {
        if (!messageHasReadexExpansionSurface(message, catalogMap)) {
          return;
        }

        const messageKey = messageDOMKey(message, index);
        if (!changedMessageKeys.has(messageKey)) {
          addedKeys.push(messageKey);
        }
        changedMessageKeys.add(messageKey);
      });
      return addedKeys;
    }

    function markMessagesForMarkdownRendererProfileChange(payload, changedMessageKeys) {
      if (!payload || typeof payload !== "object" || !(changedMessageKeys instanceof Set)) {
        return [];
      }

      const addedKeys = [];
      const messages = Array.isArray(payload.messages) ? payload.messages : [];
      messages.forEach((message, index) => {
        const messageKey = messageDOMKey(message, index);
        if (!messageKey) {
          return;
        }
        if (!changedMessageKeys.has(messageKey)) {
          addedKeys.push(messageKey);
        }
        changedMessageKeys.add(messageKey);
      });
      return addedKeys;
    }

    function groupKeyByMessageID(groups) {
      const groupByMessageID = new Map();
      (Array.isArray(groups) ? groups : []).forEach((group) => {
        const groupKey = trimmed(group?.id);
        if (!groupKey) {
          return;
        }
        const messageIDs = Array.isArray(group?.messageIDs)
          ? group.messageIDs.filter((messageID) => typeof messageID === "string" && messageID.trim().length > 0)
          : [];
        messageIDs.forEach((messageID) => {
          groupByMessageID.set(messageID, groupKey);
        });
      });
      return groupByMessageID;
    }

    function mergeCatalogPatchIntoPayload(payload, patch) {
      if (!payload || typeof payload !== "object") {
        return new Map();
      }

      const catalogByKey = new Map(
        (Array.isArray(payload.blockCatalog) ? payload.blockCatalog : [])
          .map((block) => normalizedCatalogBlock(block))
          .filter(Boolean)
          .map((block) => [block.id, block])
      );

      const deletedCatalogBlockKeys = new Set(
        Array.isArray(patch.deletedCatalogBlockKeys)
          ? patch.deletedCatalogBlockKeys.filter((key) => typeof key === "string" && key.length > 0)
          : []
      );
      deletedCatalogBlockKeys.forEach((key) => {
        catalogByKey.delete(key);
      });

      normalizedPatchCatalogBlocks(patch.upsertedCatalogBlocks).forEach((block) => {
        catalogByKey.set(block.id, block);
      });

      const orderedCatalogBlockKeys = Array.isArray(patch.orderedCatalogBlockKeys)
        ? patch.orderedCatalogBlockKeys.filter((key) => typeof key === "string" && key.length > 0)
        : [];
      const orderedCatalogBlocks = orderedCatalogBlockKeys
        .map((key) => catalogByKey.get(key))
        .filter(Boolean);

      if (orderedCatalogBlockKeys.length && orderedCatalogBlocks.length === orderedCatalogBlockKeys.length) {
        payload.blockCatalog = orderedCatalogBlocks;
        resetResolvedBlockCatalogCache();
        return new Map(orderedCatalogBlocks.map((block) => [block.id, block]));
      }

      rebuildPayloadBlockCatalog(payload);
      return resolvedBlockCatalogMap();
    }

    function mergePatchedBlocksIntoMessage(message, patchedMessage, catalogMap = null) {
      if (!message || !patchedMessage || typeof patchedMessage !== "object") {
        return message;
      }

      const fallbackBlockByKey = new Map(
        inlineMessageBlocks(message).map((block) => [block.id, block])
      );

      const deletedBlockKeys = new Set(
        Array.isArray(patchedMessage.deletedBlockKeys)
          ? patchedMessage.deletedBlockKeys.filter((key) => typeof key === "string" && key.length > 0)
          : []
      );
      deletedBlockKeys.forEach((key) => {
        fallbackBlockByKey.delete(key);
      });

      const upsertedBlocks = Array.isArray(patchedMessage.upsertedBlocks)
        ? patchedMessage.upsertedBlocks
            .map((block) => normalizedCatalogBlock(block, message))
            .filter(Boolean)
        : [];
      upsertedBlocks.forEach((block) => {
        fallbackBlockByKey.set(block.id, block);
      });

      const orderedBlockKeys = Array.isArray(patchedMessage.orderedBlockKeys)
        ? patchedMessage.orderedBlockKeys.filter((key) => typeof key === "string" && key.length > 0)
        : [];
      const resolvedBlocks = orderedBlockKeys
        .map((key) => (catalogMap instanceof Map ? catalogMap.get(key) : null) || fallbackBlockByKey.get(key))
        .map((block) => normalizedCatalogBlock(block, message))
        .filter(Boolean);
      const fullyResolvedFromCatalog =
        catalogMap instanceof Map &&
        orderedBlockKeys.length > 0 &&
        orderedBlockKeys.every((key) => catalogMap.has(key));
      if (fullyResolvedFromCatalog) {
        setMessageBlockReferences(message, orderedBlockKeys);
      } else {
        message.blocks = resolvedBlocks;
        setMessageBlockReferences(message, []);
      }
      return message;
    }

    function mergePatchIntoPayload(patch) {
      if (!patch || typeof patch !== "object") {
        return null;
      }

      const payload = resolvePayload();
      if (!payload || typeof payload !== "object") {
        return null;
      }

      const currentMessages = Array.isArray(payload.messages) ? payload.messages : [];
      const previousMessageKeys = currentMessages.map((message, index) => messageDOMKey(message, index));
      const previousCatalogKeys = (Array.isArray(payload.blockCatalog) ? payload.blockCatalog : [])
        .map((block) => trimmed(block?.id))
        .filter(Boolean);
      const existingGroups = Array.isArray(payload.messageGroups) ? payload.messageGroups : [];
      const previousGroupKeys = existingGroups
        .map((group) => trimmed(group?.id))
        .filter(Boolean);
      const previousTheme = payload.theme === "dark" ? "dark" : "light";
      const previousStyleKey = stableJSONString(payload.style || null);
      const previousRendererProfile = trimmed(payload.readexMarkdownRendererProfile);
      const previousDisplayWindowKey = normalizedDisplayWindowKey(payload.displayWindow);

      applyPatchMetadataToPayload(payload, patch.metadata);
      resetResolvedBlockCatalogCache();

      const nextTheme = payload.theme === "dark" ? "dark" : "light";
      const nextStyleKey = stableJSONString(payload.style || null);
      const nextRendererProfile = trimmed(payload.readexMarkdownRendererProfile);
      const nextDisplayWindowKey = normalizedDisplayWindowKey(payload.displayWindow);
      const rendererProfileChanged = previousRendererProfile !== nextRendererProfile;
      const shellLayoutChanged = previousTheme !== nextTheme
        || previousStyleKey !== nextStyleKey
        || rendererProfileChanged;
      const displayWindowChanged = previousDisplayWindowKey !== nextDisplayWindowKey;

      const messageByKey = new Map(currentMessages.map((message, index) => [messageDOMKey(message, index), message]));
      const changedCatalogBlockKeys = changedCatalogBlockKeysFromPatch(patch);
      const deletedKeys = new Set(
        stringArrayFromPatch(patch.deletedMessageKeys)
      );
      deletedKeys.forEach((key) => {
        messageByKey.delete(key);
      });

      const upsertedMessages = Array.isArray(patch.upsertedMessages) ? patch.upsertedMessages : [];
      const changedMessageKeys = new Set();
      const rendererProfileChangedMessageKeys = rendererProfileChanged
        ? markMessagesForMarkdownRendererProfileChange(payload, changedMessageKeys)
        : [];
      upsertedMessages.forEach((entry) => {
        if (!entry || typeof entry.key !== "string" || !entry.key || !entry.message) {
          return;
        }
        changedMessageKeys.add(entry.key);
        messageByKey.set(entry.key, entry.message);
      });

      const patchedMessages = Array.isArray(patch.patchedMessages) ? patch.patchedMessages : [];
      patchedMessages.forEach((entry) => {
        if (!entry || typeof entry.key !== "string" || !entry.key) {
          return;
        }
        const existingMessage = messageByKey.get(entry.key);
        if (!existingMessage) {
          return;
        }
        changedMessageKeys.add(entry.key);
        applyPatchedMessageState(existingMessage, entry.state, {
          structuredBlocks: patchedMessageUsesCatalogBlocks(entry)
        });
      });

      const orderedMessageKeys = stringArrayFromPatch(patch.orderedMessageKeys);
      const messageOrderChanged = !sameStringArray(orderedMessageKeys, previousMessageKeys);
      payload.messages = orderedMessageKeys
        .map((key) => messageByKey.get(key))
        .filter(Boolean);

      const orderedCatalogBlockKeys = stringArrayFromPatch(patch.orderedCatalogBlockKeys);
      const catalogOrderChanged = !sameStringArray(orderedCatalogBlockKeys, previousCatalogKeys);
      const catalogMap = mergeCatalogPatchIntoPayload(payload, patch);
      patchedMessages.forEach((entry) => {
        if (!entry || typeof entry.key !== "string" || !entry.key) {
          return;
        }
        const existingMessage = messageByKey.get(entry.key);
        if (!existingMessage) {
          return;
        }
        mergePatchedBlocksIntoMessage(existingMessage, entry, catalogMap);
      });

      const groupByKey = new Map(
        existingGroups
          .map((group) => {
            const normalizedGroup = normalizedPatchMessageGroup(group);
            return normalizedGroup ? [normalizedGroup.id, normalizedGroup] : null;
          })
          .filter(Boolean)
      );
      const deletedGroupKeys = new Set(
        stringArrayFromPatch(patch.deletedGroupKeys)
      );
      deletedGroupKeys.forEach((key) => {
        groupByKey.delete(key);
      });

      const upsertedGroups = normalizedPatchUpsertedGroups(patch.upsertedGroups);
      const changedGroupKeys = new Set(upsertedGroups.map((entry) => entry.key));
      upsertedGroups.forEach((entry) => {
        groupByKey.set(entry.key, entry.group);
      });

      const orderedGroupKeys = stringArrayFromPatch(patch.orderedGroupKeys);
      const groupOrderChanged = !sameStringArray(orderedGroupKeys, previousGroupKeys);
      const orderedGroups = orderedGroupKeys
        .map((key) => groupByKey.get(key))
        .filter(Boolean);
      if (orderedGroupKeys.length && orderedGroups.length === orderedGroupKeys.length) {
        payload.messageGroups = orderedGroups;
      } else {
        rebuildPayloadMessageGroups(payload);
      }

      normalizePayloadForRendering(payload, catalogMap);
      const catalogChangedMessageKeys = markMessagesReferencingCatalogBlocks(
        payload,
        changedCatalogBlockKeys,
        changedMessageKeys
      );
      const readexExpansionChangedMessageKeys = patchMetadataChangesReadexExpansion(patch.metadata)
        ? markMessagesWithReadexExpansionSurface(payload, catalogMap, changedMessageKeys)
        : [];

      const resolvedGroupByMessageID = groupKeyByMessageID(payload.messageGroups);
      changedMessageKeys.forEach((messageKey) => {
        const message = messageByKey.get(messageKey);
        const messageID = trimmed(message?.id);
        if (!messageID) {
          return;
        }
        const groupKey = resolvedGroupByMessageID.get(messageID);
        if (groupKey) {
          changedGroupKeys.add(groupKey);
        }
      });

      if (
        changedCatalogBlockKeys.size > 0 ||
        catalogChangedMessageKeys.length > 0 ||
        readexExpansionChangedMessageKeys.length > 0 ||
        rendererProfileChangedMessageKeys.length > 0
      ) {
        postTranscriptProbe("patch", "catalog_reference_changes", {
          catalogChangedBlockCount: changedCatalogBlockKeys.size,
          catalogChangedMessageCount: catalogChangedMessageKeys.length,
          catalogChangedBlockKeys: Array.from(changedCatalogBlockKeys).slice(0, 6).join(","),
          catalogChangedMessageKeys: catalogChangedMessageKeys.slice(0, 6).join(","),
          readexExpansionChangedMessageCount: readexExpansionChangedMessageKeys.length,
          rendererProfileChangedMessageCount: rendererProfileChangedMessageKeys.length,
          previousRendererProfile,
          nextRendererProfile,
          changedMessages: changedMessageKeys.size,
          changedGroups: changedGroupKeys.size
        });
      }

      const requiresConversationMutation = Boolean(
        shellLayoutChanged ||
        displayWindowChanged ||
        messageOrderChanged ||
        catalogOrderChanged ||
        groupOrderChanged ||
        deletedKeys.size > 0 ||
        deletedGroupKeys.size > 0 ||
        changedMessageKeys.size > 0 ||
        changedGroupKeys.size > 0
      );

      window.__chatTranscriptPayload = payload;
      resetResolvedBlockCatalogCache();

      return {
        orderedMessageKeys,
        deletedKeys,
        changedMessageKeys,
        changedGroupKeys,
        messageByKey,
        requiresConversationMutation,
        payload
      };
    }

    return Object.freeze({
      applyPatchMetadataToPayload,
      applyPatchedMessageState,
      mergePatchIntoPayload
    });
  };
})();
