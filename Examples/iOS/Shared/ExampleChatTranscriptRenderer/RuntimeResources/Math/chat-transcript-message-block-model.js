(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript message block model dependency: ${name}`);
    }
    return value;
  }

  window.ChatTranscriptMessageBlockModelFactory = function createChatTranscriptMessageBlockModel(dependencies) {
    const trimmed = requiredFunction(dependencies, "trimmed");
    const normalizedStatus = requiredFunction(dependencies, "normalizedStatus");
    const normalizedCatalogBlockStatus = requiredFunction(dependencies, "normalizedCatalogBlockStatus");
    const legacyMessageIsStreaming = requiredFunction(dependencies, "legacyMessageIsStreaming");
    const legacyMessageIsSearchInProgress = requiredFunction(dependencies, "legacyMessageIsSearchInProgress");

    function durationMillisecondsValue(source) {
      const duration = Number(source?.durationMilliseconds);
      if (Number.isFinite(duration)) {
        return duration;
      }
      const codexDuration = Number(source?.durationMs);
      return Number.isFinite(codexDuration) ? codexDuration : null;
    }

    function schemaValue(source, chatKey, legacyKey, alternateLegacyKey = "") {
      if (!source || typeof source !== "object") {
        return undefined;
      }
      if (Object.prototype.hasOwnProperty.call(source, chatKey)) {
        return source[chatKey];
      }
      if (Object.prototype.hasOwnProperty.call(source, legacyKey)) {
        return source[legacyKey];
      }
      if (alternateLegacyKey && Object.prototype.hasOwnProperty.call(source, alternateLegacyKey)) {
        return source[alternateLegacyKey];
      }
      return undefined;
    }

    function normalizedChatSupportKind(block) {
      switch (trimmed(block?.kind)) {
        case "chat_processing":
        case "readex_processing":
          return "chat_processing";
        case "chat_progress":
        case "readex_progress":
          return "chat_progress";
        case "chat_video_progress":
        case "readex_video_progress":
          return "chat_video_progress";
        case "chat_tool_call":
        case "readex_tool_call":
          return "chat_tool_call";
        case "chat_stopped_marker":
        case "readex_stopped_marker":
          return "chat_stopped_marker";
        default:
          return trimmed(block?.kind);
      }
    }

    function schemaTurnStartedAtMilliseconds(source) {
      return schemaValue(source, "chatTurnStartedAtMilliseconds", "readexTurnStartedAtMilliseconds");
    }

    function schemaTurnDurationMilliseconds(source) {
      return schemaValue(source, "chatTurnDurationMilliseconds", "readexTurnDurationMilliseconds");
    }

    function schemaToolBatchID(source) {
      return trimmed(schemaValue(source, "chatToolBatchID", "readexToolBatchID", "readexToolBatchId"))
        || trimmed(source?.toolBatchID)
        || trimmed(source?.toolBatchId);
    }

    function schemaToolName(source) {
      return trimmed(schemaValue(source, "chatToolName", "readexToolName")) || trimmed(source?.toolName);
    }

    function schemaProcessingGroupID(source) {
      return trimmed(schemaValue(source, "chatProcessingGroupId", "readexProcessingGroupId", "readexProcessingGroupID"));
    }

    function schemaProcessingChromeRole(source) {
      return trimmed(schemaValue(source, "chatProcessingChromeRole", "readexProcessingChromeRole"));
    }

    function schemaProcessingActive(source) {
      return schemaValue(source, "chatProcessingActive", "readexProcessingActive") === true;
    }

    function readexProcessingFoldGroupID(source) {
      return trimmed(schemaValue(source, "chatProcessingFoldGroupId", "readexProcessingFoldGroupId", "readexProcessingFoldGroupID"));
    }

    function clearStructuredMessageLegacyState(message) {
      if (!message || typeof message !== "object") {
        return message;
      }

      if (Object.prototype.hasOwnProperty.call(message, "content")) {
        delete message.content;
      }
      if (Object.prototype.hasOwnProperty.call(message, "supportBlocks")) {
        delete message.supportBlocks;
      }
      if (Object.prototype.hasOwnProperty.call(message, "isStreaming")) {
        delete message.isStreaming;
      }
      if (Object.prototype.hasOwnProperty.call(message, "isSearchInProgress")) {
        delete message.isSearchInProgress;
      }

      return message;
    }

    function normalizedCatalogBlock(block, message = null) {
      if (!block || typeof block !== "object") {
        return null;
      }

      const id = trimmed(block.id);
      if (!id) {
        return null;
      }

      const normalized = { ...block, id };
      const explicitMessageID = typeof block.messageId === "string"
        ? block.messageId
        : (typeof block.messageID === "string" ? block.messageID : "");
      const messageID = trimmed(explicitMessageID || message?.id);
      if (messageID) {
        normalized.messageId = messageID;
      } else if (Object.prototype.hasOwnProperty.call(normalized, "messageId")) {
        delete normalized.messageId;
      }
      if (Object.prototype.hasOwnProperty.call(normalized, "messageID")) {
        delete normalized.messageID;
      }

      normalized.status = normalizedCatalogBlockStatus(normalized, message);
      normalized.summaryParts = Array.isArray(block.summaryParts) ? block.summaryParts : [];
      normalized.summaryDurationsMilliseconds = Array.isArray(block.summaryDurationsMilliseconds)
        ? block.summaryDurationsMilliseconds
        : [];
      normalized.searchQueries = Array.isArray(block.searchQueries) ? block.searchQueries : [];
      normalized.searchReferences = Array.isArray(block.searchReferences) ? block.searchReferences : [];
      normalized.webSearchActions = Array.isArray(block.webSearchActions) ? block.webSearchActions : [];
      normalized.items = Array.isArray(block.items) ? block.items : [];
      normalized.attachments = Array.isArray(block.attachments) ? block.attachments : [];
      normalized.images = Array.isArray(block.images) ? block.images : [];
      normalized.textSelection = block.textSelection || null;
      normalized.previewItems = Array.isArray(block.previewItems) ? block.previewItems : [];
      return normalized;
    }

    function inlineMessageBlocks(message) {
      return Array.isArray(message?.blocks)
        ? message.blocks
            .map((block) => normalizedCatalogBlock(block, message))
            .filter(Boolean)
        : [];
    }

    function messageBlockReferenceIDs(message) {
      const blockReferences = Array.isArray(message?.blocks)
        ? message.blocks.filter((blockID) => typeof blockID === "string" && blockID.length > 0)
        : [];
      if (blockReferences.length) {
        return blockReferences;
      }

      return Array.isArray(message?.blockIDs)
        ? message.blockIDs.filter((blockID) => typeof blockID === "string" && blockID.length > 0)
        : [];
    }

    function setMessageBlockReferences(message, blockIDs) {
      if (!message || typeof message !== "object") {
        return message;
      }

      const references = Array.isArray(blockIDs)
        ? blockIDs.filter((blockID) => typeof blockID === "string" && blockID.length > 0)
        : [];

      if (references.length) {
        message.blocks = references;
        clearStructuredMessageLegacyState(message);
      }

      if (Object.prototype.hasOwnProperty.call(message, "blockIDs")) {
        delete message.blockIDs;
      }

      return message;
    }

    function messageHasStructuredBlocks(message) {
      return messageBlockReferenceIDs(message).length > 0 || inlineMessageBlocks(message).length > 0;
    }

    function runtimeBlockNamespace(message) {
      const messageID = trimmed(message?.id);
      if (messageID) {
        return messageID;
      }
      const patchKey = trimmed(message?.patchKey);
      if (patchKey) {
        return patchKey;
      }
      return "";
    }

    function runtimeScopedBlockID(message, localID) {
      const namespace = runtimeBlockNamespace(message);
      const normalizedLocalID = trimmed(localID);
      if (!namespace || !normalizedLocalID) {
        return normalizedLocalID;
      }
      return `${namespace}:${normalizedLocalID}`;
    }

    function legacySupportBlockFragments(message) {
      const blocks = [];
      const supportBlocks = Array.isArray(message?.supportBlocks) ? message.supportBlocks : [];
      const hasInlineTextSegments = supportBlocks.some((block) => block?.kind === "text_segment" && trimmed(block.text));
      let hasImageBlocks = false;
      const reasoningActivity = reasoningActivityBlockFromSupportBlocks(supportBlocks);

      supportBlocks.forEach((block, index) => {
        if (!block || typeof block.kind !== "string") {
          return;
        }

        switch (normalizedChatSupportKind(block)) {
          case "thinking":
            if (trimmed(block.text) || block.durationMilliseconds != null || legacyMessageIsStreaming(message)) {
              blocks.push({
                id: `thinking:${index}`,
                type: "thinking",
                text: block.text || "",
                durationMilliseconds: block.durationMilliseconds,
                searchQueries: [],
                searchReferences: []
              });
            }
            break;
          case "reasoning_summary": {
            if (reasoningActivity) {
              if (reasoningActivity.firstIndex === index) {
                blocks.push(reasoningActivity.block);
              }
              break;
            }
            const summaryParts = Array.isArray(block.summaryParts)
              ? block.summaryParts.map((part) => trimmed(part)).filter(Boolean)
              : [];
            const fallbackText = trimmed(block.text);
            if (summaryParts.length > 0 || fallbackText || block.durationMilliseconds != null) {
              blocks.push({
                id: `reasoning_summary:${index}`,
                type: "reasoning_summary",
                text: fallbackText,
                summaryParts,
                summaryDurationsMilliseconds: Array.isArray(block.summaryDurationsMilliseconds)
                  ? block.summaryDurationsMilliseconds
                  : [],
                durationMilliseconds: block.durationMilliseconds,
                startedAtMilliseconds: block.startedAtMilliseconds,
                searchQueries: [],
                searchReferences: []
              });
            }
            break;
          }
          case "search_results":
            const searchStatus = normalizedStatus(block.status);
            if (
              searchStatus === "processing" ||
              searchStatus === "searching" ||
              (Array.isArray(block.webSearchActions) && block.webSearchActions.length > 0) ||
              (Array.isArray(block.searchReferences) && block.searchReferences.length > 0) ||
              (Array.isArray(block.searchQueries) && block.searchQueries.map((query) => trimmed(query)).filter(Boolean).length > 0) ||
              (Array.isArray(block.items) && block.items.length > 0)
            ) {
              blocks.push({
                id: `search_results:${index}`,
                type: "citation",
                status: searchStatus || "success",
                text: null,
                durationMilliseconds: durationMillisecondsValue(block),
                startedAtMilliseconds: block.startedAtMilliseconds ?? null,
                chatTurnStartedAtMilliseconds: schemaTurnStartedAtMilliseconds(block) ?? null,
                chatTurnDurationMilliseconds: schemaTurnDurationMilliseconds(block) ?? null,
                workedForItem: block.workedForItem || null,
                searchQueries: Array.isArray(block.searchQueries) ? block.searchQueries : [],
                searchReferences: block.searchReferences,
                webSearchActions: Array.isArray(block.webSearchActions) ? block.webSearchActions : [],
                items: Array.isArray(block.items) ? block.items : []
              });
            }
            break;
          case "text_segment":
            if (trimmed(block.text)) {
              blocks.push({
                id: `text_segment:${index}`,
                type: "main_text",
                inlineTextSegment: true,
                text: block.text || "",
                durationMilliseconds: null,
                chatProcessingFoldGroupId: readexProcessingFoldGroupID(block),
                searchQueries: [],
                searchReferences: []
              });
            }
            break;
          case "chat_progress":
            if (trimmed(block.text)) {
              blocks.push({
                id: `chat_progress:${index}`,
                type: "chat_progress",
                text: block.text || "",
                status: legacyMessageIsStreaming(message) && !hasInlineTextSegments ? "streaming" : "success",
                durationMilliseconds: block.durationMilliseconds,
                startedAtMilliseconds: block.startedAtMilliseconds,
                chatTurnStartedAtMilliseconds: schemaTurnStartedAtMilliseconds(block) ?? null,
                chatTurnDurationMilliseconds: schemaTurnDurationMilliseconds(block) ?? null,
                workedForItem: block.workedForItem || null,
                searchQueries: [],
                searchReferences: [],
                items: Array.isArray(block.items) ? block.items : []
              });
            }
            break;
          case "proposed_plan":
            if (trimmed(block.text) || block.status === "streaming") {
              blocks.push({
                id: block.id || `proposed_plan:${index}`,
                type: "proposed_plan",
                text: block.text || "",
                status: block.status || (legacyMessageIsStreaming(message) ? "streaming" : "completed"),
                phaseTitle: block.phaseTitle || "计划",
                durationMilliseconds: durationMillisecondsValue(block),
                startedAtMilliseconds: block.startedAtMilliseconds ?? null,
                chatTurnStartedAtMilliseconds: schemaTurnStartedAtMilliseconds(block) ?? null,
                chatTurnDurationMilliseconds: schemaTurnDurationMilliseconds(block) ?? null,
                workedForItem: block.workedForItem || null,
                searchQueries: [],
                searchReferences: [],
                items: []
              });
            }
            break;
          case "chat_processing":
            if (block.workedForItem || block.startedAtMilliseconds != null || block.durationMilliseconds != null || (Array.isArray(block.items) && block.items.length > 0)) {
              blocks.push({
                id: `chat_processing:${index}`,
                type: "chat_processing",
                text: "",
                status: block.status || (legacyMessageIsStreaming(message) ? "processing" : "success"),
                durationMilliseconds: block.durationMilliseconds,
                startedAtMilliseconds: block.startedAtMilliseconds,
                chatTurnStartedAtMilliseconds: schemaTurnStartedAtMilliseconds(block) ?? null,
                chatTurnDurationMilliseconds: schemaTurnDurationMilliseconds(block) ?? null,
                workedForItem: block.workedForItem || null,
                chatProcessingGroupId: schemaProcessingGroupID(block),
                chatProcessingChromeRole: schemaProcessingChromeRole(block),
                chatProcessingFoldGroupId: readexProcessingFoldGroupID(block),
                chatProcessingActive: schemaProcessingActive(block) || block.status === "processing" || block.status === "streaming" || block.status === "searching",
                searchQueries: [],
                searchReferences: [],
                items: Array.isArray(block.items) ? block.items : []
              });
            }
            break;
          case "chat_stopped_marker":
            blocks.push({
              id: `chat_stopped_marker:${index}`,
              type: "chat_stopped_marker",
              text: "",
              status: block.status || "stopped",
              durationMilliseconds: durationMillisecondsValue(block),
              startedAtMilliseconds: block.startedAtMilliseconds,
              chatTurnStartedAtMilliseconds: schemaTurnStartedAtMilliseconds(block) ?? null,
              chatTurnDurationMilliseconds: schemaTurnDurationMilliseconds(block) ?? null,
              workedForItem: block.workedForItem || null,
              searchQueries: [],
              searchReferences: [],
              items: []
            });
            break;
          case "chat_video_progress":
            if (trimmed(block.text) || trimmed(block.detailText)) {
              const sourceBlockId = trimmed(block.id) || `chat_video_progress:${index}`;
              blocks.push({
                id: sourceBlockId,
                sourceBlockId,
                type: "chat_video_progress",
                text: block.text || "",
                detailText: block.detailText || "",
                subtitleText: block.subtitleText || "",
                status: block.status || (legacyMessageIsStreaming(message) && block.durationMilliseconds == null ? "processing" : "success"),
                progress: Number.isFinite(Number(block.progress)) ? Number(block.progress) : null,
                progressUpdatedAtMilliseconds: Number.isFinite(Number(block.progressUpdatedAtMilliseconds)) ? Number(block.progressUpdatedAtMilliseconds) : null,
                progressRatePerSecond: Number.isFinite(Number(block.progressRatePerSecond)) ? Number(block.progressRatePerSecond) : null,
                batchCurrentItemIndex: block.batchCurrentItemIndex != null && Number.isFinite(Number(block.batchCurrentItemIndex)) ? Number(block.batchCurrentItemIndex) : null,
                batchCompletedItemCount: block.batchCompletedItemCount != null && Number.isFinite(Number(block.batchCompletedItemCount)) ? Number(block.batchCompletedItemCount) : null,
                batchTotalItemCount: block.batchTotalItemCount != null && Number.isFinite(Number(block.batchTotalItemCount)) ? Number(block.batchTotalItemCount) : null,
                batchProgress: block.batchProgress != null && Number.isFinite(Number(block.batchProgress)) ? Number(block.batchProgress) : null,
                phase: block.phase || "",
                phaseTitle: block.phaseTitle || "",
                summaryParts: Array.isArray(block.summaryParts) ? block.summaryParts : [],
                durationMilliseconds: block.durationMilliseconds,
                startedAtMilliseconds: block.startedAtMilliseconds,
                chatTurnStartedAtMilliseconds: schemaTurnStartedAtMilliseconds(block) ?? null,
                chatTurnDurationMilliseconds: schemaTurnDurationMilliseconds(block) ?? null,
                workedForItem: block.workedForItem || null,
                searchQueries: [],
                searchReferences: [],
                items: Array.isArray(block.items) ? block.items : []
              });
            }
            break;
          case "chat_tool_call":
            if (trimmed(block.text) || (Array.isArray(block.items) && block.items.length > 0)) {
              blocks.push({
                id: `chat_tool_call:${index}`,
                type: "chat_tool_call",
                text: block.text || "",
                detailText: block.detailText || "",
                previewItems: Array.isArray(block.previewItems) ? block.previewItems : [],
                shellExecution: block.shellExecution || null,
                commandExecution: block.commandExecution || null,
                toolBatchId: schemaToolBatchID(block),
                status: legacyMessageIsStreaming(message) && block.durationMilliseconds == null ? "processing" : "success",
                durationMilliseconds: block.durationMilliseconds,
                startedAtMilliseconds: block.startedAtMilliseconds,
                chatTurnStartedAtMilliseconds: schemaTurnStartedAtMilliseconds(block) ?? null,
                chatTurnDurationMilliseconds: schemaTurnDurationMilliseconds(block) ?? null,
                workedForItem: block.workedForItem || null,
                searchQueries: [],
                searchReferences: [],
                items: Array.isArray(block.items) ? block.items : []
              });
            }
            break;
          case "image":
            if ((Array.isArray(block.images) && block.images.length > 0) || block.imageStatus === "processing") {
              hasImageBlocks = true;
              blocks.push({
                id: `image:${index}`,
                type: "image",
                status: block.imageStatus === "processing" ? "processing" : "success",
                text: null,
                durationMilliseconds: null,
                searchQueries: [],
                searchReferences: [],
                images: Array.isArray(block.images) ? block.images : []
              });
            }
            break;
          default:
            break;
        }
      });

      return {
        blocks,
        hasInlineTextSegments,
        hasImageBlocks
      };
    }

    function readexToolItemFromMessageBlock(block, message) {
      const text = trimmed(block?.text);
      if (!text) {
        return null;
      }
      const duration = durationMillisecondsValue(block);
      const isLive = legacyMessageIsStreaming(message) && !Number.isFinite(duration);
      return {
        id: trimmed(block?.sourceBlockId) || trimmed(block?.sourceBlockID) || trimmed(block?.id),
        type: "tool",
        text,
        detailText: trimmed(block?.detailText),
        previewItems: Array.isArray(block?.previewItems) ? block.previewItems : [],
        shellExecution: block?.shellExecution || null,
        commandExecution: block?.commandExecution || null,
        toolBatchId: schemaToolBatchID(block),
        status: normalizedCatalogBlockStatus(block, message) || (isLive ? "processing" : "success"),
        durationMilliseconds: duration,
        searchQueries: [],
        searchReferences: []
      };
    }

    function readexToolItemsFromMessageBlock(block, message) {
      const activityItems = Array.isArray(block?.items)
        ? block.items.filter(Boolean)
        : [];
      if (activityItems.length > 0) {
        return activityItems.map((item, index) => ({
          ...item,
          id: trimmed(item?.id)
            || trimmed(item?.sourceBlockId)
            || trimmed(item?.sourceBlockID)
            || [trimmed(block?.id), "item", String(index)].filter(Boolean).join(":"),
          sourceBlockId: trimmed(item?.sourceBlockId)
            || trimmed(item?.sourceBlockID)
            || trimmed(block?.sourceBlockId)
            || trimmed(block?.sourceBlockID)
            || trimmed(block?.id)
        }));
      }
      const item = readexToolItemFromMessageBlock(block, message);
      return item ? [item] : [];
    }

    function groupAdjacentReadexToolCallBlocks(blocks, message) {
      if (!Array.isArray(blocks) || !blocks.length) {
        return [];
      }
      const output = [];
      let index = 0;
      while (index < blocks.length) {
        const block = blocks[index];
        if (!block || (block.type !== "chat_tool_call" && block.type !== "readex_tool_call")) {
          output.push(block);
          index += 1;
          continue;
        }

        const startIndex = index;
        const items = [];
        let durationMilliseconds = null;
        let startedAtMilliseconds = null;
        while (index < blocks.length && (blocks[index]?.type === "chat_tool_call" || blocks[index]?.type === "readex_tool_call")) {
          const currentBlock = blocks[index];
          const nextItems = readexToolItemsFromMessageBlock(currentBlock, message);
          items.push(...nextItems);
          const durationSources = nextItems.length > 0 && Array.isArray(currentBlock?.items) && currentBlock.items.length > 0
            ? nextItems
            : [currentBlock];
          for (const durationSource of durationSources) {
            const itemDuration = durationMillisecondsValue(durationSource);
            if (Number.isFinite(itemDuration)) {
              durationMilliseconds = (durationMilliseconds || 0) + itemDuration;
            }
          }
          const startedSources = nextItems.length > 0 && Array.isArray(currentBlock?.items) && currentBlock.items.length > 0
            ? nextItems
            : [currentBlock];
          const startedValues = startedSources
            .map((source) => Number(source?.startedAtMilliseconds))
            .filter((value) => Number.isFinite(value) && value > 0);
          for (const blockStartedAt of startedValues) {
            startedAtMilliseconds = startedAtMilliseconds == null
              ? blockStartedAt
              : Math.min(startedAtMilliseconds, blockStartedAt);
          }
          index += 1;
        }

        if (!items.length) {
          continue;
        }
        const firstBlock = blocks[startIndex];
        const firstSourceBlockId = trimmed(firstBlock?.sourceBlockId)
          || trimmed(firstBlock?.sourceBlockID)
          || trimmed(items[0]?.id);
        const isLive = items.some((item) => {
          const status = normalizedStatus(item?.status);
          return status === "pending" || status === "processing" || status === "streaming" || status === "searching";
        });
        output.push({
          id: `chat_tool_activity:${trimmed(firstBlock?.id) || startIndex}`,
          sourceBlockId: firstSourceBlockId,
          type: "chat_tool_activity",
          status: isLive ? "processing" : "success",
          text: "",
          durationMilliseconds,
          startedAtMilliseconds,
          searchQueries: [],
          searchReferences: [],
          items
        });
      }
      return output;
    }

    function readexToolItemFromSupportBlock(block, message) {
      const text = trimmed(block?.text);
      if (!text) {
        return null;
      }
      const duration = durationMillisecondsValue(block);
      const isLive = legacyMessageIsStreaming(message) && !Number.isFinite(duration);
      return {
        id: trimmed(block?.sourceBlockId) || trimmed(block?.sourceBlockID) || trimmed(block?.id),
        type: "tool",
        text,
        detailText: trimmed(block?.detailText),
        previewItems: Array.isArray(block?.previewItems) ? block.previewItems : [],
        shellExecution: block?.shellExecution || null,
        commandExecution: block?.commandExecution || null,
        toolName: schemaToolName(block),
        toolBatchId: schemaToolBatchID(block),
        status: isLive ? "processing" : "success",
        durationMilliseconds: duration,
        searchQueries: [],
        searchReferences: []
      };
    }

    function readexToolItemsFromSupportBlock(block, message) {
      const activityItems = Array.isArray(block?.items)
        ? block.items.filter(Boolean)
        : [];
      if (activityItems.length > 0) {
        return activityItems.map((item, index) => ({
          ...item,
          id: trimmed(item?.id)
            || trimmed(item?.sourceBlockId)
            || trimmed(item?.sourceBlockID)
            || [trimmed(block?.id), "item", String(index)].filter(Boolean).join(":"),
          sourceBlockId: trimmed(item?.sourceBlockId)
            || trimmed(item?.sourceBlockID)
            || trimmed(block?.sourceBlockId)
            || trimmed(block?.sourceBlockID)
            || trimmed(block?.id)
        }));
      }
      const item = readexToolItemFromSupportBlock(block, message);
      return item ? [item] : [];
    }

    function readexToolActivityBlockFromSupportBlocks(supportBlocks, message, startIndex = 0) {
      const items = [];
      const firstIndex = Number.isFinite(Number(startIndex)) ? Number(startIndex) : 0;
      let durationMilliseconds = null;
      let startedAtMilliseconds = null;

      if (!Array.isArray(supportBlocks) || !supportBlocks[firstIndex] || normalizedChatSupportKind(supportBlocks[firstIndex]) !== "chat_tool_call") {
        return null;
      }

      for (let index = firstIndex; index < supportBlocks.length; index += 1) {
        const block = supportBlocks[index];
        if (!block || normalizedChatSupportKind(block) !== "chat_tool_call") {
          break;
        }
        const nextItems = readexToolItemsFromSupportBlock(block, message);
        if (!nextItems.length) {
          continue;
        }
        for (const item of nextItems) {
          const itemDuration = durationMillisecondsValue(item);
          if (Number.isFinite(itemDuration)) {
            durationMilliseconds = (durationMilliseconds || 0) + itemDuration;
          }
        }
        const startedValues = nextItems
          .map((item) => Number(item?.startedAtMilliseconds))
          .filter((value) => Number.isFinite(value) && value > 0);
        const resolvedStartedValues = startedValues.length > 0
          ? startedValues
          : [Number(block.startedAtMilliseconds)].filter((value) => Number.isFinite(value) && value > 0);
        for (const blockStartedAt of resolvedStartedValues) {
          startedAtMilliseconds = startedAtMilliseconds == null
            ? blockStartedAt
            : Math.min(startedAtMilliseconds, blockStartedAt);
        }
        items.push(...nextItems);
      }

      if (!items.length) {
        return null;
      }

      const isLive = items.some((item) => {
        const status = normalizedStatus(item?.status);
        return status === "pending" || status === "processing" || status === "streaming" || status === "searching";
      });
      const firstBlock = supportBlocks[firstIndex];
      const firstSourceBlockId = trimmed(firstBlock?.sourceBlockId)
        || trimmed(firstBlock?.sourceBlockID)
        || trimmed(items[0]?.id);
      return {
        firstIndex,
        block: {
          id: `chat_tool_activity:${firstIndex}`,
          sourceBlockId: firstSourceBlockId,
          type: "chat_tool_activity",
          status: isLive ? "processing" : "success",
          text: "",
          durationMilliseconds,
          startedAtMilliseconds,
          searchQueries: [],
          searchReferences: [],
          items
        }
      };
    }

    function normalizedStringArray(values) {
      if (!Array.isArray(values)) {
        return [];
      }
      const seen = new Set();
      return values.map((value) => trimmed(value)).filter((value) => {
        if (!value || seen.has(value)) {
          return false;
        }
        seen.add(value);
        return true;
      });
    }

    function pseudoSearchSummaryTitle(line) {
      let normalized = trimmed(line);
      normalized = normalized.replace(/^#{1,6}\s*/, "");
      normalized = normalized.replace(/^[*_`~\s]+|[*_`~\s]+$/g, "");
      normalized = trimmed(normalized).toLowerCase();
      return normalized.startsWith("searching for ")
        || normalized === "searching the web"
        || normalized === "searching";
    }

    function sanitizeSummaryPart(part) {
      const text = trimmed(part);
      if (!text) {
        return "";
      }
      if (/^[|▌█▋▊▉]+$/u.test(text)) {
        return "";
      }
      if ([...text].length < 2) {
        return "";
      }
      if (!/[0-9A-Za-z\p{L}\p{N}\p{Ideographic}]/u.test(text)) {
        return "";
      }
      const lines = text.split(/\r?\n/);
      const firstContentIndex = lines.findIndex((line) => Boolean(trimmed(line)));
      if (firstContentIndex < 0) {
        return "";
      }
      const hasBodyAfterTitle = lines
        .slice(firstContentIndex + 1)
        .some((line) => Boolean(trimmed(line)));
      if (hasBodyAfterTitle && pseudoSearchSummaryTitle(lines[firstContentIndex])) {
        lines.splice(firstContentIndex, 1);
        return trimmed(lines.join("\n"));
      }
      return text;
    }

    function supportBlockSummaryParts(block) {
      const parts = Array.isArray(block?.summaryParts)
        ? normalizedStringArray(block.summaryParts.map((part) => sanitizeSummaryPart(part)))
        : [];
      if (parts.length) {
        return parts;
      }
      const fallbackText = sanitizeSummaryPart(block?.text);
      return fallbackText ? [fallbackText] : [];
    }

    function summaryDurationForPart(block, partIndex, partCount) {
      const durations = Array.isArray(block?.summaryDurationsMilliseconds)
        ? block.summaryDurationsMilliseconds
        : [];
      const duration = Number(durations[partIndex]);
      if (Number.isFinite(duration)) {
        return duration;
      }
      return partCount === 1 && block?.durationMilliseconds != null
        ? block.durationMilliseconds
        : null;
    }

    function reasoningActivityBlockFromSupportBlocks(supportBlocks) {
      const hasSummary = supportBlocks.some((block) => (
        block?.kind === "reasoning_summary" && supportBlockSummaryParts(block).length > 0
      ));
      if (!hasSummary) {
        return null;
      }

      const items = [];
      let firstIndex = -1;
      let summaryOrdinal = 0;
      let durationMilliseconds = null;
      let startedAtMilliseconds = null;

      supportBlocks.forEach((block, index) => {
        if (!block || block.kind !== "reasoning_summary") {
          return;
        }

        if (firstIndex < 0) {
          firstIndex = index;
        }

        if (block.kind === "reasoning_summary") {
          const blockDuration = Number(block.durationMilliseconds);
          if (Number.isFinite(blockDuration)) {
            durationMilliseconds = Math.max(durationMilliseconds || 0, blockDuration);
          }
          const blockStartedAt = Number(block.startedAtMilliseconds ?? block.startedAtMs);
          if (Number.isFinite(blockStartedAt) && blockStartedAt > 0) {
            startedAtMilliseconds = startedAtMilliseconds == null
              ? blockStartedAt
              : Math.min(startedAtMilliseconds, blockStartedAt);
          }
          const parts = supportBlockSummaryParts(block);
          parts.forEach((part, partIndex) => {
            summaryOrdinal += 1;
            items.push({
              type: "summary",
              ordinal: summaryOrdinal,
              text: part,
              durationMilliseconds: summaryDurationForPart(block, partIndex, parts.length),
              searchQueries: [],
              searchReferences: []
            });
          });
          return;
        }

      });

      if (firstIndex < 0 || !items.length) {
        return null;
      }

      const latestSummary = items
        .slice()
        .reverse()
        .find((item) => item?.type === "summary" && trimmed(item.text));

      return {
        firstIndex,
        block: {
          id: `reasoning_activity:${firstIndex}`,
          type: "reasoning_activity",
          text: latestSummary ? trimmed(latestSummary.text) : "",
          durationMilliseconds,
          startedAtMilliseconds,
          searchQueries: [],
          searchReferences: [],
          items
        }
      };
    }

    function legacyProgressBlocks(message) {
      if (!legacyMessageIsSearchInProgress(message)) {
        return [];
      }

      return [{
        id: "search_progress",
        type: "search_progress",
        text: null,
        durationMilliseconds: null,
        searchReferences: [],
        items: [{
          id: "search_progress:web_search",
          type: "web-search",
          status: "processing",
          completed: false,
          toolName: "web_search"
        }]
      }];
    }

    function legacyContentFallbackBlocks(message, hasInlineTextSegments, hasImageBlocks = false) {
      const blocks = [];

      if (message?.role === "assistant") {
        if (!hasInlineTextSegments) {
          if (trimmed(message?.content)) {
            blocks.push({
              id: "content",
              type: "main_text",
              text: message.content || "",
              durationMilliseconds: null,
              searchReferences: []
            });
          }
        }
      } else if (trimmed(message?.content)) {
        blocks.push({
          id: "content",
          type: "main_text",
          text: message.content || "",
          durationMilliseconds: null,
          searchReferences: []
        });
      }

      return blocks;
    }

    function translatedLegacyInlineBlocks(message) {
      const namespace = runtimeBlockNamespace(message);
      if (!namespace) {
        return [];
      }

      const { blocks: supportBlocks, hasInlineTextSegments, hasImageBlocks } = legacySupportBlockFragments(message);
      const blocks = supportBlocks
        .concat(legacyProgressBlocks(message))
        .concat(legacyContentFallbackBlocks(message, hasInlineTextSegments, hasImageBlocks))
        .map((block) => ({ ...block, id: runtimeScopedBlockID(message, block.id) }))
        .map((block) => normalizedCatalogBlock(block, message))
        .filter(Boolean);
      return groupAdjacentReadexToolCallBlocks(blocks, message);
    }

    function normalizeLegacyMessageToStructuredShell(message) {
      if (!message || typeof message !== "object" || messageHasStructuredBlocks(message)) {
        return false;
      }

      const translatedBlocks = translatedLegacyInlineBlocks(message);
      if (!translatedBlocks.length) {
        return false;
      }

      message.blocks = translatedBlocks;
      clearStructuredMessageLegacyState(message);
      return true;
    }

    return Object.freeze({
      normalizedCatalogBlock,
      inlineMessageBlocks,
      messageBlockReferenceIDs,
      setMessageBlockReferences,
      clearStructuredMessageLegacyState,
      messageHasStructuredBlocks,
      runtimeBlockNamespace,
      runtimeScopedBlockID,
      legacySupportBlockFragments,
      legacyProgressBlocks,
      legacyContentFallbackBlocks,
      translatedLegacyInlineBlocks,
      normalizeLegacyMessageToStructuredShell
    });
  };
})();
