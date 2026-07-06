(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript message runtime model dependency: ${name}`);
    }
    return value;
  }

  function requiredObject(dependencies, name) {
    const value = dependencies?.[name];
    if (!value || typeof value !== "object") {
      throw new Error(`Missing ChatTranscript message runtime model dependency: ${name}`);
    }
    return value;
  }

  window.ChatTranscriptMessageRuntimeModelFactory = function createChatTranscriptMessageRuntimeModel(dependencies) {
    const trimmed = requiredFunction(dependencies, "trimmed");
    const blockText = requiredFunction(dependencies, "blockText");
    const normalizedCatalogBlock = requiredFunction(dependencies, "normalizedCatalogBlock");
    const messageHasStructuredBlocks = requiredFunction(dependencies, "messageHasStructuredBlocks");
    const translatedLegacyInlineBlocks = requiredFunction(dependencies, "translatedLegacyInlineBlocks");
    const resolvedMessageBlocks = requiredFunction(dependencies, "resolvedMessageBlocks");
    const statusModel = requiredObject(dependencies, "statusModel");
    const normalizedStatus = requiredFunction(statusModel, "normalizedStatus");
    const legacyMessageStatus = requiredFunction(statusModel, "legacyMessageStatus");
    const structuredMessageShellStatus = requiredFunction(statusModel, "structuredMessageShellStatus");
    const legacyMessageIsStreaming = requiredFunction(statusModel, "legacyMessageIsStreaming");
    const legacyMessageIsSearchInProgress = requiredFunction(statusModel, "legacyMessageIsSearchInProgress");
    const blockIsLive = requiredFunction(statusModel, "blockIsLive");

    function hasRenderableBlockType(blocks, blockType) {
      return Array.isArray(blocks) && blocks.some((block) => block?.type === blockType);
    }

    function supplementalMessageShellBlocks(message, existingBlocks = []) {
      const blocks = [];

      if (Array.isArray(message?.attachments) && message.attachments.length > 0 && !hasRenderableBlockType(existingBlocks, "attachments")) {
        blocks.push({
          id: "attachments",
          type: "attachments",
          text: null,
          durationMilliseconds: null,
          searchQueries: [],
          searchReferences: [],
          attachments: message.attachments
        });
      }

      if (
        trimmed(message?.footerPageSummary)
        && !hasRenderableBlockType(existingBlocks, "footer")
        && !hasRenderableBlockType(existingBlocks, "goal_footer")
      ) {
        blocks.push({
          id: "footer",
          type: "footer",
          text: message.footerPageSummary,
          durationMilliseconds: null,
          searchQueries: [],
          searchReferences: []
        });
      }

      return blocks
        .map((block) => normalizedCatalogBlock(block, message))
        .filter(Boolean);
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

    function searchReferenceSourceKey(reference) {
      return trimmed(reference?.url)
        || trimmed(reference?.title)
        || trimmed(reference?.content);
    }

    function appendUniqueSearchReference(output, seen, reference) {
      if (!reference || typeof reference !== "object") {
        return;
      }
      const key = searchReferenceSourceKey(reference);
      if (!key || seen.has(key)) {
        return;
      }
      seen.add(key);
      output.push(reference);
    }

    function collectSearchReferencesFromActivityItem(item, output, seen) {
      if (!item || typeof item !== "object") {
        return;
      }
      appendUniqueSearchReference(output, seen, item.webSearchReference);
      appendUniqueSearchReference(output, seen, item.reference);
      if (Array.isArray(item.searchReferences)) {
        item.searchReferences.forEach((reference) => appendUniqueSearchReference(output, seen, reference));
      }
      if (Array.isArray(item.childItems)) {
        item.childItems.forEach((childItem) => collectSearchReferencesFromActivityItem(childItem, output, seen));
      }
    }

    function collectSearchReferenceSources(blocks) {
      const output = [];
      const seen = new Set();
      (Array.isArray(blocks) ? blocks : []).forEach((block) => {
        if (Array.isArray(block?.searchReferences)) {
          block.searchReferences.forEach((reference) => appendUniqueSearchReference(output, seen, reference));
        }
        if (Array.isArray(block?.items)) {
          block.items.forEach((item) => collectSearchReferencesFromActivityItem(item, output, seen));
        }
      });
      return output;
    }

    function readexSourcePreviewType(preview) {
      const attachmentKind = trimmed(preview?.attachmentKind);
      if (attachmentKind === "extractedPDF") {
        return "pdf";
      }
      return "";
    }

    function readexSourcePreviewKey(preview) {
      return trimmed(preview?.id)
        || trimmed(preview?.filePath)
        || [
          trimmed(preview?.documentName),
          trimmed(preview?.title),
          trimmed(preview?.subtitle),
          trimmed(preview?.attachmentKind)
        ].join("\u{1f}");
    }

    function appendUniqueReadexSourcePreview(output, seen, preview) {
      const sourceType = readexSourcePreviewType(preview);
      if (!sourceType) {
        return;
      }
      const key = readexSourcePreviewKey(preview);
      if (!key || seen.has(key)) {
        return;
      }
      seen.add(key);
      output.push({
        type: sourceType,
        preview
      });
    }

    function collectReadexSourcePreviewsFromActivityItem(item, output, seen) {
      if (!item || typeof item !== "object") {
        return;
      }
      if (Array.isArray(item.previewItems)) {
        item.previewItems.forEach((preview) => appendUniqueReadexSourcePreview(output, seen, preview));
      }
      if (Array.isArray(item.childItems)) {
        item.childItems.forEach((childItem) => collectReadexSourcePreviewsFromActivityItem(childItem, output, seen));
      }
    }

    function collectReadexSourcePreviews(blocks) {
      const output = [];
      const seen = new Set();
      (Array.isArray(blocks) ? blocks : []).forEach((block) => {
        if (Array.isArray(block?.previewItems)) {
          block.previewItems.forEach((preview) => appendUniqueReadexSourcePreview(output, seen, preview));
        }
        if (Array.isArray(block?.items)) {
          block.items.forEach((item) => collectReadexSourcePreviewsFromActivityItem(item, output, seen));
        }
      });
      return output;
    }

    function messageSourcesBlock(message, existingBlocks = []) {
      if (message?.role !== "assistant" || hasRenderableBlockType(existingBlocks, "sources")) {
        return null;
      }

      const webReferences = collectSearchReferenceSources(existingBlocks);
      const readexSources = collectReadexSourcePreviews(existingBlocks);
      const sections = [];

      if (webReferences.length) {
        sections.push({
          type: "webSearch",
          title: "网页来源",
          items: webReferences.map((reference) => ({
            type: "web",
            reference
          }))
        });
      }

      if (readexSources.length) {
        sections.push({
          type: "readex",
          title: "资料来源",
          items: readexSources.map((source) => ({
            type: source.type,
            preview: source.preview
          }))
        });
      }

      if (!sections.length) {
        return null;
      }

      return normalizedCatalogBlock({
        id: "sources",
        type: "sources",
        status: "success",
        text: null,
        durationMilliseconds: null,
        searchQueries: [],
        searchReferences: [],
        sections
      }, message);
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

    function summaryParts(block) {
      const parts = Array.isArray(block?.summaryParts)
        ? normalizedStringArray(block.summaryParts.map((part) => sanitizeSummaryPart(part)))
        : [];
      if (parts.length) {
        return parts;
      }
      const text = sanitizeSummaryPart(blockText(block));
      return text ? [text] : [];
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

    function combineReasoningActivityBlocks(blocks) {
      if (!Array.isArray(blocks)) {
        return blocks;
      }

      const hasSummary = blocks.some((block) => {
        if (block?.type === "reasoning_summary") {
          return summaryParts(block).length > 0;
        }
        if (block?.type === "reasoning_activity") {
          return Array.isArray(block.items) && block.items.some((item) => (
            item?.type === "summary" && trimmed(item.text)
          ));
        }
        return false;
      });
      if (!hasSummary) {
        return blocks;
      }

      const timelineIndexes = [];
      const items = [];
      let summaryOrdinal = 0;
      let durationMilliseconds = null;
      let startedAtMilliseconds = null;
      blocks.forEach((block, index) => {
        if (
          !block ||
          (
            block.type !== "reasoning_activity" &&
            block.type !== "reasoning_summary"
          )
        ) {
          return;
        }

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

        if (block.type === "reasoning_activity") {
          const activityItems = Array.isArray(block.items) ? block.items : [];
          const normalizedItems = [];
          activityItems.forEach((item) => {
            if (item?.type === "summary") {
              const text = trimmed(item.text);
              if (!text) {
                return;
              }
              summaryOrdinal += 1;
              normalizedItems.push({
                type: "summary",
                ordinal: summaryOrdinal,
                text,
                durationMilliseconds: Number.isFinite(Number(item.durationMilliseconds))
                  ? Number(item.durationMilliseconds)
                  : null,
                searchQueries: [],
                searchReferences: []
              });
              return;
            }
          });

          if (normalizedItems.length) {
            timelineIndexes.push(index);
            items.push(...normalizedItems);
          }
          return;
        }

        if (block.type === "reasoning_summary") {
          const parts = summaryParts(block);
          if (!parts.length) {
            return;
          }
          timelineIndexes.push(index);
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

      if (!timelineIndexes.length || !items.length) {
        return blocks;
      }

      const firstIndex = timelineIndexes[0];
      const skipIndexes = new Set(timelineIndexes);
      const latestSummary = items
        .slice()
        .reverse()
        .find((item) => item?.type === "summary" && trimmed(item.text));
      const activityBlock = normalizedCatalogBlock({
        id: blocks[firstIndex]?.id || "reasoning_activity",
        type: "reasoning_activity",
        text: latestSummary ? trimmed(latestSummary.text) : "",
        durationMilliseconds,
        startedAtMilliseconds,
        searchQueries: [],
        searchReferences: [],
        items
      });

      const combined = [];
      blocks.forEach((block, index) => {
        if (index === firstIndex) {
          combined.push(activityBlock);
        }
        if (!skipIndexes.has(index)) {
          combined.push(block);
        }
      });
      return combined.filter(Boolean);
    }

    function durationMillisecondsValue(source) {
      const duration = Number(source?.durationMilliseconds);
      if (Number.isFinite(duration)) {
        return duration;
      }
      const codexDuration = Number(source?.durationMs);
      return Number.isFinite(codexDuration) ? codexDuration : null;
    }

    function normalizedActivityItemType(item) {
      const type = trimmed(item?.type);
      if (type === "web-search" || type === "webSearch" || type === "web_search") {
        return "web-search";
      }
      if (
        type === "chatToolCall" ||
        type === "chat_tool_call" ||
        type === "readexToolCall" ||
        type === "readex_tool_call" ||
        type === "mcpToolCall" ||
        type === "mcp_tool_call"
      ) {
        return "tool";
      }
      return type;
    }

    function activityToolName(item) {
      return trimmed(item?.chatToolName)
        || trimmed(item?.readexToolName)
        || trimmed(item?.toolName)
        || trimmed(item?.tool)
        || trimmed(item?.name);
    }

    function activitySearchQueries(item) {
      const queries = normalizedStringArray(item?.searchQueries);
      const query = trimmed(item?.query);
      if (query && !queries.includes(query)) {
        return [query].concat(queries);
      }
      return queries;
    }

    function activityItemID(item, block, index) {
      return trimmed(item?.id)
        || trimmed(item?.sourceBlockId)
        || trimmed(item?.sourceBlockID)
        || [
          trimmed(block?.sourceBlockId) || trimmed(block?.sourceBlockID) || trimmed(block?.id),
          "item",
          String(index)
        ].filter(Boolean).join(":");
    }

    function activityToolText(item) {
      const text = trimmed(item?.text);
      if (text) {
        return text;
      }
      const toolName = activityToolName(item);
      const serverName = trimmed(item?.server);
      if (toolName && serverName) {
        return `${serverName}.${toolName}`;
      }
      return toolName || serverName;
    }

    function activityItemStatus(item, block, durationMilliseconds) {
      const status = normalizedStatus(item?.status);
      if (status) {
        return status;
      }
      if (trimmed(item?.error)) {
        return "failed";
      }
      if (item?.completed === true) {
        return "success";
      }
      if (item?.completed === false) {
        return "processing";
      }
      return normalizedStatus(block?.status) || (Number.isFinite(durationMilliseconds) ? "success" : "processing");
    }

    function readexActivityItemFromItem(item, block, index) {
      const type = normalizedActivityItemType(item) || "tool";
      if (type === "web-search" || activityItemIsWebSearch(item)) {
        return webSearchItemFromActivityItem(item, block, index);
      }

      const text = activityToolText(item);
      if (!text) {
        return null;
      }
      const duration = durationMillisecondsValue(item);
      const id = activityItemID(item, block, index);
      const childItems = Array.isArray(item?.childItems)
        ? item.childItems
            .map((childItem, childIndex) => readexActivityItemFromItem(childItem, item, childIndex))
            .filter(Boolean)
        : [];
      const searchQueries = activitySearchQueries(item);
      const searchReferences = Array.isArray(item?.searchReferences) ? item.searchReferences : [];
      const webSearchActions = Array.isArray(item?.webSearchActions) ? item.webSearchActions : [];
      return {
        ...item,
        id,
        sourceBlockId: trimmed(item?.sourceBlockId) || trimmed(item?.sourceBlockID) || id,
        type,
        text,
        detailText: trimmed(item?.detailText),
        previewItems: Array.isArray(item?.previewItems) ? item.previewItems : [],
        shellExecution: item?.shellExecution || null,
        commandExecution: item?.commandExecution || null,
        childItems,
        toolName: activityToolName(item),
        toolBatchId: trimmed(item?.chatToolBatchID) || trimmed(item?.chatToolBatchId) || trimmed(item?.readexToolBatchID) || trimmed(item?.readexToolBatchId) || trimmed(item?.toolBatchID) || trimmed(item?.toolBatchId),
        status: activityItemStatus(item, block, duration),
        durationMilliseconds: duration,
        searchQueries,
        searchReferences,
        webSearchActions,
        webSearchAction: item?.webSearchAction || item?.action || webSearchActions[0] || null,
        webSearchReference: item?.webSearchReference || item?.reference || null
      };
    }

    function readexToolItemFromBlock(block) {
      if (!block || (
        !blockTypeIs(block, "chat_tool_call", "readex_tool_call") &&
        !blockTypeIs(block, "chat_tool_activity", "readex_tool_activity")
      )) {
        return null;
      }

      const text = trimmed(blockText(block));
      if (!text) {
        return null;
      }
      const status = normalizedStatus(block.status);
      const duration = durationMillisecondsValue(block);
      return {
        id: trimmed(block.sourceBlockId) || trimmed(block.sourceBlockID) || trimmed(block.id),
        type: "tool",
        text,
        detailText: trimmed(block.detailText),
        previewItems: Array.isArray(block.previewItems) ? block.previewItems : [],
        shellExecution: block?.shellExecution || null,
        commandExecution: block?.commandExecution || null,
        toolName: activityToolName(block),
        toolBatchId: trimmed(block.chatToolBatchID) || trimmed(block.chatToolBatchId) || trimmed(block.readexToolBatchID) || trimmed(block.readexToolBatchId) || trimmed(block.toolBatchID) || trimmed(block.toolBatchId),
        status: status || (Number.isFinite(duration) ? "success" : "processing"),
        durationMilliseconds: duration,
        searchQueries: [],
        searchReferences: []
      };
    }

    function readexToolItemsFromBlock(block) {
      if (!block) {
        return [];
      }
      if (Array.isArray(block.items) && block.items.length > 0) {
        return block.items
          .map((item, index) => readexActivityItemFromItem(item, block, index))
          .filter(Boolean);
      }
      const item = readexToolItemFromBlock(block);
      return item ? [item] : [];
    }

    function webSearchActivityItemIsLive(item, block) {
      if (trimmed(item?.error)) {
        return false;
      }
      if (item?.completed === true) {
        return false;
      }
      if (item?.completed === false) {
        return true;
      }
      const status = normalizedStatus(item?.status);
      if (status) {
        return status === "processing" || status === "searching" || status === "pending" || status === "streaming";
      }
      return webSearchBlockIsProcessing(block);
    }

    function activityItemIsWebSearch(item) {
      const type = normalizedActivityItemType(item);
      const toolName = activityToolName(item);
      return type === "web-search" || toolName === "web_search";
    }

    function webSearchItemFromActivityItem(item, block, index) {
      if (!activityItemIsWebSearch(item)) {
        return null;
      }
      const queries = activitySearchQueries(item);
      const references = Array.isArray(item.searchReferences) ? item.searchReferences : [];
      const itemActions = Array.isArray(item.webSearchActions) ? item.webSearchActions : [];
      const firstAction = item.webSearchAction || item.action || itemActions[0] || null;
      const actions = firstAction && !itemActions.includes(firstAction)
        ? [firstAction].concat(itemActions)
        : itemActions;
      const isProcessing = webSearchActivityItemIsLive(item, block);
      if (!isProcessing && !queries.length && !references.length && !actions.length && !trimmed(item.text)) {
        return null;
      }
      const duration = durationMillisecondsValue(item);
      const id = trimmed(item.id)
        || trimmed(item.sourceBlockId)
        || trimmed(item.sourceBlockID)
        || [trimmed(block?.sourceBlockId) || trimmed(block?.sourceBlockID) || trimmed(block?.id), "item", String(index)].filter(Boolean).join(":");
      return {
        id,
        sourceBlockId: trimmed(item.sourceBlockId) || trimmed(item.sourceBlockID) || id,
        type: "web-search",
        text: trimmed(item.text) || webSearchItemText(queries, references, isProcessing),
        query: trimmed(item.query) || queries[0] || "",
        action: firstAction,
        completed: !isProcessing,
        detailText: trimmed(item.detailText),
        previewItems: Array.isArray(item.previewItems) ? item.previewItems : [],
        childItems: Array.isArray(item.childItems) ? item.childItems : [],
        toolName: "web_search",
        toolBatchId: trimmed(item.toolBatchId) || trimmed(item.toolBatchID) || trimmed(item.chatToolBatchID) || trimmed(item.chatToolBatchId) || trimmed(item.readexToolBatchID) || trimmed(item.readexToolBatchId),
        status: isProcessing ? "processing" : (normalizedStatus(item.status) || normalizedStatus(block?.status) || "success"),
        durationMilliseconds: isProcessing ? null : (duration != null ? duration : 0),
        searchQueries: queries,
        searchReferences: references,
        webSearchActions: actions,
        webSearchAction: firstAction,
        webSearchReference: item.webSearchReference || item.reference || null
      };
    }

    function readexProgressItemFromBlock(block) {
      const text = trimmed(blockText(block));
      if (!text) {
        return null;
      }
      const duration = durationMillisecondsValue(block);
      return {
        id: trimmed(block?.id),
        sourceBlockId: trimmed(block?.sourceBlockId) || trimmed(block?.sourceBlockID),
        type: "progress",
        text,
        detailText: "",
        status: normalizedStatus(block?.status) || "success",
        durationMilliseconds: duration,
        searchQueries: [],
        searchReferences: []
      };
    }

    function readexVideoProgressItemFromBlock(block) {
      const text = trimmed(blockText(block));
      const detailText = trimmed(block?.detailText);
      const items = Array.isArray(block?.items) ? block.items : [];
      if (!text && !detailText && !items.length) {
        return null;
      }
      const status = normalizedStatus(block?.status) || (durationMillisecondsValue(block) == null ? "processing" : "success");
      const progress = Number(block?.progress);
      const progressUpdatedAtMilliseconds = Number(block?.progressUpdatedAtMilliseconds);
      const progressRatePerSecond = Number(block?.progressRatePerSecond);
      const batchCurrentItemIndex = Number(block?.batchCurrentItemIndex);
      const batchCompletedItemCount = Number(block?.batchCompletedItemCount);
      const batchTotalItemCount = Number(block?.batchTotalItemCount);
      const batchProgress = Number(block?.batchProgress);
      const id = trimmed(block?.sourceBlockId) || trimmed(block?.sourceBlockID) || trimmed(block?.id);
      return {
        id,
        sourceBlockId: id,
        type: "video_progress",
        text,
        detailText,
        subtitleText: trimmed(block?.subtitleText),
        status,
        completed: !readexActivityItemLiveStatus(status),
        durationMilliseconds: durationMillisecondsValue(block),
        startedAtMilliseconds: readexProcessingStartedAtMilliseconds(block),
        summaryParts: Array.isArray(block?.summaryParts) ? block.summaryParts : [],
        progress: Number.isFinite(progress) ? progress : null,
        progressUpdatedAtMilliseconds: Number.isFinite(progressUpdatedAtMilliseconds) ? progressUpdatedAtMilliseconds : null,
        progressRatePerSecond: Number.isFinite(progressRatePerSecond) ? progressRatePerSecond : null,
        phase: trimmed(block?.phase),
        phaseTitle: trimmed(block?.phaseTitle),
        batchCurrentItemIndex: Number.isFinite(batchCurrentItemIndex) ? batchCurrentItemIndex : null,
        batchCompletedItemCount: Number.isFinite(batchCompletedItemCount) ? batchCompletedItemCount : null,
        batchTotalItemCount: Number.isFinite(batchTotalItemCount) ? batchTotalItemCount : null,
        batchProgress: Number.isFinite(batchProgress) ? batchProgress : null,
        items,
        searchQueries: [],
        searchReferences: []
      };
    }

    function webSearchBlockIsProcessing(block) {
      const status = normalizedStatus(block?.status);
      return block?.type === "search_progress"
        || status === "processing"
        || status === "searching"
        || status === "pending"
        || status === "streaming";
    }

    function webSearchItemText(queries, references, isProcessing) {
      return isProcessing ? "正在搜索网页" : `已搜索网页 ${webSearchActivityCount(queries, references)} 次`;
    }

    function webSearchActivityCount(queries, references) {
      const referenceCount = Array.isArray(references) ? references.length : 0;
      if (referenceCount > 0) {
        return referenceCount;
      }
      const queryCount = Array.isArray(queries) ? queries.length : 0;
      return Math.max(1, queryCount);
    }

    function searchQueryChildItems(queries, parentID, isProcessing) {
      return (Array.isArray(queries) ? queries : []).map((query, index) => {
        const text = trimmed(query);
        const action = text
          ? { type: "search", query: text, queries: [text] }
          : null;
        return {
          id: [parentID, "query", String(index), text].filter(Boolean).join(":"),
          type: "web-search",
          text,
          query: text,
          action,
          completed: !isProcessing,
          detailText: "",
          previewItems: [],
          toolName: "web_search",
          toolBatchId: "",
          status: isProcessing ? "processing" : "success",
          durationMilliseconds: isProcessing ? null : 0,
          searchQueries: text ? [text] : [],
          searchReferences: [],
          webSearchActions: action ? [action] : [],
          webSearchAction: action,
          webSearchReference: null
        };
      });
    }

    function activityActionType(action) {
      const type = trimmed(action?.type);
      if (type === "open_page") {
        return "openPage";
      }
      if (type === "find_in_page") {
        return "findInPage";
      }
      return type;
    }

    function activityActionQueries(action) {
      return normalizedStringArray(action?.queries);
    }

    function activitySearchActionDetail(action, fallbackQuery = "") {
      const query = trimmed(action?.query);
      const queries = activityActionQueries(action);
      return query || queries[0] || trimmed(fallbackQuery);
    }

    function activityActionDetail(action, fallbackQuery = "") {
      const type = activityActionType(action);
      const query = activitySearchActionDetail(action, fallbackQuery);
      const url = trimmed(action?.url);
      const pattern = trimmed(action?.pattern);
      if (type === "openPage") {
        return url;
      }
      if (type === "findInPage") {
        if (pattern && url) {
          return `'${pattern}' in ${url}`;
        }
        return pattern ? `'${pattern}'` : url;
      }
      if (type === "search") {
        return query;
      }
      return query || url || pattern || "";
    }

    function webSearchActionDisplayText(action) {
      return activityActionDetail(action);
    }

    function webSearchActionCompleted(action, isProcessing) {
      if (action?.completed === true) {
        return true;
      }
      if (action?.completed === false) {
        return false;
      }
      const status = normalizedStatus(action?.status);
      if (status) {
        return !(status === "processing" || status === "searching" || status === "pending" || status === "streaming");
      }
      return !isProcessing;
    }

    function webSearchActionChildItems(actions, parentID, isProcessing) {
      return (Array.isArray(actions) ? actions : []).map((action, index) => {
        const text = webSearchActionDisplayText(action);
        if (!text) {
          return null;
        }
        const completed = webSearchActionCompleted(action, isProcessing);
        const status = normalizedStatus(action?.status) || (completed ? "success" : "processing");
        return {
          id: trimmed(action?.id) || [parentID, "action", String(index), text].filter(Boolean).join(":"),
          type: "web-search",
          text,
          query: text,
          action,
          completed,
          detailText: "",
          previewItems: [],
          toolName: "web_search",
          toolBatchId: "",
          status,
          durationMilliseconds: completed ? 0 : null,
          searchQueries: [],
          searchReferences: [],
          webSearchActions: [action],
          webSearchAction: action,
          webSearchReference: null
        };
      }).filter(Boolean);
    }

    function webSearchItemFromBlock(block) {
      if (!block || (block.type !== "citation" && block.type !== "search_results" && block.type !== "search_progress")) {
        return null;
      }
      const activityItems = Array.isArray(block.items)
        ? block.items.map((item, index) => webSearchItemFromActivityItem(item, block, index)).filter(Boolean)
        : [];
      if (activityItems.length === 1) {
        return activityItems[0];
      }
      if (activityItems.length > 1) {
        const isProcessing = activityItems.some((item) => webSearchActivityItemIsLive(item, block));
        const queries = normalizedStringArray(activityItems.flatMap((item) => item.searchQueries));
        const references = activityItems.flatMap((item) => Array.isArray(item.searchReferences) ? item.searchReferences : []);
        const actions = activityItems.flatMap((item) => Array.isArray(item.webSearchActions) ? item.webSearchActions : []);
        const id = trimmed(block?.sourceBlockId) || trimmed(block?.sourceBlockID) || trimmed(block?.id);
        return {
          id,
          sourceBlockId: id,
          type: "web-search",
          text: webSearchItemText(queries, references, isProcessing),
          query: queries[0] || "",
          action: actions[0] || null,
          completed: !isProcessing,
          detailText: "",
          previewItems: [],
          childItems: activityItems,
          toolName: "web_search",
          toolBatchId: "",
          status: isProcessing ? "processing" : (normalizedStatus(block.status) || "success"),
          durationMilliseconds: isProcessing ? null : 0,
          searchQueries: queries,
          searchReferences: references,
          webSearchActions: actions
        };
      }
      const queries = normalizedStringArray(block.searchQueries);
      const references = Array.isArray(block.searchReferences) ? block.searchReferences : [];
      const actions = Array.isArray(block.webSearchActions) ? block.webSearchActions : [];
      const isProcessing = webSearchBlockIsProcessing(block);
      if (!isProcessing && !queries.length && !references.length && !actions.length) {
        return null;
      }
      const duration = durationMillisecondsValue(block);
      const id = trimmed(block?.sourceBlockId) || trimmed(block?.sourceBlockID) || trimmed(block?.id);
      return {
        id,
        sourceBlockId: id,
        type: "web-search",
        text: webSearchItemText(queries, references, isProcessing),
        query: queries[0] || "",
        action: actions[0] || null,
        completed: !isProcessing,
        detailText: "",
        previewItems: [],
        toolName: "web_search",
        toolBatchId: "",
        status: isProcessing ? "processing" : (normalizedStatus(block.status) || "success"),
        durationMilliseconds: isProcessing ? null : (duration != null ? duration : 0),
        childItems: actions.length > 0
          ? webSearchActionChildItems(actions, id, isProcessing)
          : searchQueryChildItems(queries, id, isProcessing),
        searchQueries: queries,
        searchReferences: references,
        webSearchActions: actions
      };
    }

    function readexActivityItemLiveStatus(status) {
      return status === "pending" || status === "processing" || status === "streaming" || status === "searching";
    }

    function readexActivityItemFailedStatus(status) {
      return status === "failed";
    }

    function readexActivityItemInterruptedStatus(status) {
      return status === "interrupted";
    }

    function isLiveReadexItem(item) {
      return readexActivityItemLiveStatus(normalizedStatus(item?.status));
    }

    function combinedReadexProcessingStatus(activityBlocks, items, isLive) {
      if (isLive) {
        return "processing";
      }
      const statuses = activityBlocks
        .map((block) => normalizedStatus(block?.status))
        .concat(items.map((item) => normalizedStatus(item?.status)))
        .filter(Boolean);
      if (statuses.some(readexActivityItemFailedStatus)) {
        return "failed";
      }
      if (statuses.some(readexActivityItemInterruptedStatus)) {
        return "interrupted";
      }
      return "success";
    }

    function messageShellIsLive(message) {
      const status = normalizedStatus(structuredMessageShellStatus(message) || legacyMessageStatus(message));
      return status === "pending" || status === "processing" || status === "streaming" || status === "searching";
    }

    function readexProcessingBlockIsActive(block) {
      return block?.chatProcessingActive === true || block?.readexProcessingActive === true;
    }

    function readexProcessingChromeRole(block) {
      return trimmed(block?.chatProcessingChromeRole) || trimmed(block?.readexProcessingChromeRole);
    }

    function readexProcessingBlockOwnsChrome(block) {
      return readexProcessingChromeRole(block) !== "continuation";
    }

    function readexProcessingGroupID(block) {
      return trimmed(block?.chatProcessingGroupId || block?.chatProcessingGroupID) ||
        trimmed(block?.readexProcessingGroupId || block?.readexProcessingGroupID);
    }

    function readexProcessingFoldGroupID(block) {
      return trimmed(block?.chatProcessingFoldGroupId || block?.chatProcessingFoldGroupID) ||
        trimmed(block?.readexProcessingFoldGroupId || block?.readexProcessingFoldGroupID);
    }

    function blockTypeIs(block, chatType, legacyType) {
      const type = trimmed(block?.type || block?.kind);
      return type === chatType || type === legacyType;
    }

    function readexContextStatusText(block) {
      if (!blockTypeIs(block, "chat_progress", "readex_progress")) {
        return "";
      }
      const text = trimmed(blockText(block));
      if (text === "正在自动压缩上下文" || text === "上下文已自动压缩") {
        return text;
      }
      return "";
    }

    function normalizeReadexContextStatusBlocks(blocks, message) {
      return (Array.isArray(blocks) ? blocks : []).filter(Boolean).map((block) => {
        const text = readexContextStatusText(block);
        if (!text) {
          return block;
        }
        return normalizedCatalogBlock({
          ...block,
          type: "chat_context_status",
          text,
          status: text === "正在自动压缩上下文" ? "processing" : "success",
          searchQueries: [],
          searchReferences: []
        }, message) || block;
      });
    }

    function readexProcessingStartedAtMilliseconds(block) {
      const workedForItem = normalizedReadexWorkedForItem(block);
      if (workedForItem) {
        return workedForItem.startedAtMs;
      }
      const startedAt = Number(block?.startedAtMilliseconds);
      return Number.isFinite(startedAt) && startedAt > 0 ? startedAt : null;
    }

    function readexTurnStartedAtMilliseconds(block) {
      const startedAt = Number(block?.chatTurnStartedAtMilliseconds ?? block?.readexTurnStartedAtMilliseconds ?? block?.turnStartedAtMilliseconds);
      return Number.isFinite(startedAt) && startedAt > 0 ? startedAt : null;
    }

    function readexTurnDurationMilliseconds(block) {
      const duration = Number(block?.chatTurnDurationMilliseconds ?? block?.readexTurnDurationMilliseconds ?? block?.turnDurationMilliseconds);
      return Number.isFinite(duration) ? Math.max(0, duration) : null;
    }

    function readexProcessingCompletedAtMilliseconds(source) {
      const completedAt = Number(source?.completedAtMilliseconds ?? source?.completedAtMs);
      return Number.isFinite(completedAt) && completedAt > 0 ? completedAt : null;
    }

    function normalizedReadexWorkedForItem(source) {
      const item = source?.workedForItem;
      if (!item || typeof item !== "object") {
        return null;
      }
      const startedAtMs = Number(item.startedAtMs ?? item.startedAtMilliseconds);
      if (!Number.isFinite(startedAtMs) || startedAtMs <= 0) {
        return null;
      }
      const completedAtMs = Number(item.completedAtMs ?? item.completedAtMilliseconds);
      return {
        type: "worked-for",
        status: trimmed(item.status) === "working" ? "working" : "worked",
        startedAtMs,
        completedAtMs: Number.isFinite(completedAtMs) && completedAtMs > 0 ? completedAtMs : null
      };
    }

    function readexWorkedForItem({
      explicitWorkedForItem = null,
      block,
      isLive,
      startedAtMilliseconds,
      durationMilliseconds
    }) {
      if (explicitWorkedForItem) {
        return explicitWorkedForItem;
      }
      const blockWorkedForItem = normalizedReadexWorkedForItem(block);
      if (blockWorkedForItem) {
        return blockWorkedForItem;
      }

      const startedAtMs = Number(startedAtMilliseconds);
      if (!Number.isFinite(startedAtMs) || startedAtMs <= 0) {
        return null;
      }

      let completedAtMs = isLive ? null : readexProcessingCompletedAtMilliseconds(block);
      const duration = Number(durationMilliseconds);
      if (completedAtMs == null && !isLive && Number.isFinite(duration)) {
        completedAtMs = startedAtMs + Math.max(0, duration);
      }

      return {
        type: "worked-for",
        status: isLive ? "working" : "worked",
        startedAtMs,
        completedAtMs
      };
    }

    function readexProcessingBlockCarriesRunStart(block) {
      return blockTypeIs(block, "chat_tool_call", "readex_tool_call")
        || blockTypeIs(block, "chat_tool_activity", "readex_tool_activity")
        || blockTypeIs(block, "chat_progress", "readex_progress")
        || block?.type === "citation"
        || block?.type === "search_results"
        || block?.type === "search_progress"
        || blockTypeIs(block, "chat_processing", "readex_processing");
    }

    function readexProcessingRunStartedAtMilliseconds(normalizedBlocks) {
      let startedAtMilliseconds = null;
      (Array.isArray(normalizedBlocks) ? normalizedBlocks : []).forEach((block) => {
        if (!readexProcessingBlockCarriesRunStart(block)) {
          return;
        }
        const blockStartedAt = readexTurnStartedAtMilliseconds(block) ?? readexProcessingStartedAtMilliseconds(block);
        if (blockStartedAt == null) {
          return;
        }
        startedAtMilliseconds = startedAtMilliseconds == null
          ? blockStartedAt
          : Math.min(startedAtMilliseconds, blockStartedAt);
      });
      return startedAtMilliseconds;
    }

    function readexBlockIsReadexActivity(block) {
      return blockTypeIs(block, "chat_tool_call", "readex_tool_call") ||
        blockTypeIs(block, "chat_tool_activity", "readex_tool_activity") ||
        blockTypeIs(block, "chat_processing", "readex_processing") ||
        blockTypeIs(block, "chat_progress", "readex_progress") ||
        block?.type === "citation" ||
        block?.type === "search_results" ||
        block?.type === "search_progress";
    }

    function readexBlockHasVisibleMainText(block) {
      return block?.type === "main_text" && Boolean(trimmed(blockText(block)));
    }

    function readexProcessingItemsFromTimelineBlock(block, message) {
      if (!block) {
        return [];
      }
      if (blockTypeIs(block, "chat_processing", "readex_processing")) {
        return readexToolItemsFromBlock(block);
      }
      if (blockTypeIs(block, "chat_tool_call", "readex_tool_call") || blockTypeIs(block, "chat_tool_activity", "readex_tool_activity")) {
        return readexToolItemsFromBlock(block);
      }
      if (blockTypeIs(block, "chat_progress", "readex_progress")) {
        const item = readexProgressItemFromBlock(block);
        return item ? [item] : [];
      }
      if (block.type === "citation" || block.type === "search_results" || block.type === "search_progress") {
        const item = webSearchItemFromBlock(block);
        return item ? [item] : [];
      }
      return [];
    }

    function combineReadexProcessingBlockSegment(
      normalizedBlocks,
      message,
      isTrailingSegment,
      runStartedAtMilliseconds = null
    ) {
      const hasReadexActivity = normalizedBlocks.some((block) => (
        readexBlockIsReadexActivity(block)
      ));
      if (!hasReadexActivity) {
        return normalizedBlocks;
      }

      const textIndexes = normalizedBlocks
        .map((block, index) => (readexBlockHasVisibleMainText(block) ? index : -1))
        .filter((index) => index >= 0);
      const lastMainTextIndex = textIndexes.length ? textIndexes[textIndexes.length - 1] : -1;
      const hasFinalMainText = lastMainTextIndex >= 0 &&
        !normalizedBlocks.slice(lastMainTextIndex + 1).some(readexBlockIsReadexActivity);
      const candidateIndexes = [];
      normalizedBlocks.forEach((block, index) => {
        if (!readexBlockIsReadexActivity(block)) {
          return;
        }
        const nextItems = readexProcessingItemsFromTimelineBlock(block, message);
        const isProcessingShellBlock = blockTypeIs(block, "chat_processing", "readex_processing");
        if (!nextItems.length && !isProcessingShellBlock) {
          return;
        }
        candidateIndexes.push(index);
      });

      if (!candidateIndexes.length) {
        return normalizedBlocks;
      }

      const candidateIndexSet = new Set(candidateIndexes);

      function processingBlockFromActivityRun(activityBlocks, firstIndex, isTrailingActivityRun) {
        const items = [];
        let durationMilliseconds = null;
        let startedAtMilliseconds = null;
        let turnDurationMilliseconds = null;
        let turnStartedAtMilliseconds = null;
        let explicitWorkedForItem = null;
        let isReadexProcessingActive = false;
        let ownsReadexProcessingChrome = false;
        let readexProcessingGroupId = "";
        let readexProcessingFoldGroupId = "";
        let firstActivityBlock = null;
        let processingAnchorBlock = null;

        activityBlocks.forEach((block) => {
          if (!block) {
            return;
          }

          const isActivityBlock = readexBlockIsReadexActivity(block);
          if (!firstActivityBlock && isActivityBlock) {
            firstActivityBlock = block;
          }
          if (!processingAnchorBlock && blockTypeIs(block, "chat_processing", "readex_processing")) {
            processingAnchorBlock = block;
          }

          if (!explicitWorkedForItem) {
            explicitWorkedForItem = normalizedReadexWorkedForItem(block);
          }
          if (isActivityBlock && readexProcessingBlockOwnsChrome(block)) {
            ownsReadexProcessingChrome = true;
          }
          if (!readexProcessingGroupId) {
            readexProcessingGroupId = readexProcessingGroupID(block);
          }
          if (!readexProcessingFoldGroupId) {
            readexProcessingFoldGroupId = readexProcessingFoldGroupID(block);
          }
          if (isTrailingActivityRun && readexProcessingBlockIsActive(block)) {
            isReadexProcessingActive = true;
          }
          const blockDuration = Number(block.durationMilliseconds);
          if (Number.isFinite(blockDuration)) {
            durationMilliseconds = Math.max(durationMilliseconds || 0, blockDuration);
          }
          const blockTurnDuration = readexTurnDurationMilliseconds(block);
          if (blockTurnDuration != null) {
            turnDurationMilliseconds = Math.max(turnDurationMilliseconds || 0, blockTurnDuration);
          }
          const blockStartedAt = readexProcessingStartedAtMilliseconds(block);
          if (blockStartedAt != null) {
            startedAtMilliseconds = startedAtMilliseconds == null
              ? blockStartedAt
              : Math.min(startedAtMilliseconds, blockStartedAt);
          }
          const blockTurnStartedAt = readexTurnStartedAtMilliseconds(block);
          if (blockTurnStartedAt != null) {
            turnStartedAtMilliseconds = turnStartedAtMilliseconds == null
              ? blockTurnStartedAt
              : Math.min(turnStartedAtMilliseconds, blockTurnStartedAt);
          }
          const nextItems = readexProcessingItemsFromTimelineBlock(block, message);
          if (nextItems.length) {
            items.push(...nextItems);
          }
        });

        const firstBlock = processingAnchorBlock || firstActivityBlock || normalizedBlocks[firstIndex];
        const processingTurnStartedAtMilliseconds = runStartedAtMilliseconds == null
          ? (turnStartedAtMilliseconds ?? startedAtMilliseconds)
          : Math.min(turnStartedAtMilliseconds ?? runStartedAtMilliseconds, runStartedAtMilliseconds);
        const hasLiveTurnTimer = processingTurnStartedAtMilliseconds != null
          && turnDurationMilliseconds == null
          && messageShellIsLive(message);
        const isLive = isReadexProcessingActive
          || hasLiveTurnTimer
          || (!hasFinalMainText && ((isTrailingActivityRun && messageShellIsLive(message)) || items.some(isLiveReadexItem)));
        const processingStartedAtMilliseconds = runStartedAtMilliseconds == null
          ? startedAtMilliseconds
          : Math.min(startedAtMilliseconds ?? runStartedAtMilliseconds, runStartedAtMilliseconds);
        const firstSourceBlockId = trimmed(firstBlock?.sourceBlockId)
          || trimmed(firstBlock?.sourceBlockID)
          || trimmed(items[0]?.sourceBlockId)
          || trimmed(items[0]?.sourceBlockID)
          || trimmed(items[0]?.id)
          || trimmed(firstBlock?.id);
        const workedForItem = readexWorkedForItem({
          explicitWorkedForItem,
          block: firstBlock,
          isLive,
          startedAtMilliseconds: processingStartedAtMilliseconds,
          durationMilliseconds
        });
        const status = combinedReadexProcessingStatus(activityBlocks, items, isLive);
        return normalizedCatalogBlock({
          id: firstBlock?.id || "chat_processing",
          sourceBlockId: firstSourceBlockId,
          type: "chat_processing",
          status,
          text: "",
          durationMilliseconds,
          startedAtMilliseconds: processingStartedAtMilliseconds,
          chatTurnStartedAtMilliseconds: processingTurnStartedAtMilliseconds,
          chatTurnDurationMilliseconds: turnDurationMilliseconds,
          workedForItem,
          chatProcessingGroupId: readexProcessingGroupId,
          chatProcessingChromeRole: ownsReadexProcessingChrome ? "" : "continuation",
          chatProcessingFoldGroupId: readexProcessingFoldGroupId,
          activityEntries: items,
          chatProcessingActive: isReadexProcessingActive,
          searchQueries: [],
          searchReferences: [],
          items
        }, message);
      }

      const combined = [];
      let index = 0;
      while (index < normalizedBlocks.length) {
        const block = normalizedBlocks[index];
        if (!candidateIndexSet.has(index)) {
          combined.push(block);
          index += 1;
          continue;
        }

        const firstIndex = index;
        const activityBlocks = [];
        while (
          index < normalizedBlocks.length &&
          candidateIndexSet.has(index) &&
          readexBlockIsReadexActivity(normalizedBlocks[index])
        ) {
          activityBlocks.push(normalizedBlocks[index]);
          index += 1;
        }

        const hasLaterActivity = candidateIndexes.some((candidateIndex) => candidateIndex >= index);
        combined.push(processingBlockFromActivityRun(
          activityBlocks,
          firstIndex,
          isTrailingSegment && !hasLaterActivity
        ));
      }
      return combined.filter(Boolean);
    }

    function combineReadexProcessingBlocks(blocks, message) {
      const normalizedBlocks = normalizeReadexContextStatusBlocks(blocks, message);
      const runStartedAtMilliseconds = readexProcessingRunStartedAtMilliseconds(normalizedBlocks);
      const segments = [];
      let segment = [];

      const flushSegment = () => {
        if (!segment.length) {
          return;
        }
        segments.push(segment);
        segment = [];
      };

      normalizedBlocks.forEach((block) => {
        if (blockTypeIs(block, "chat_context_status", "readex_context_status")) {
          flushSegment();
          segments.push([block]);
          return;
        }
        segment.push(block);
      });
      flushSegment();

      const lastActivitySegmentIndex = segments
        .map((candidate, index) => candidate.some((block) => (
          readexBlockIsReadexActivity(block)
        )) ? index : -1)
        .filter((index) => index >= 0)
        .pop();
      const combined = [];
      let hasSeenContextStatus = false;
      segments.forEach((candidate, index) => {
        if (candidate.length === 1 && blockTypeIs(candidate[0], "chat_context_status", "readex_context_status")) {
          combined.push(candidate[0]);
          hasSeenContextStatus = true;
          return;
        }
        if (hasSeenContextStatus) {
          combined.push(...candidate);
          return;
        }
        combined.push(...combineReadexProcessingBlockSegment(
          candidate,
          message,
          index === lastActivitySegmentIndex,
          runStartedAtMilliseconds
        ));
      });
      return combined.filter(Boolean);
    }

    function appendSupplementalMessageShellBlocks(blocks, message) {
      const normalizedBlocks = Array.isArray(blocks) ? blocks.filter(Boolean) : [];
      return normalizedBlocks.concat(supplementalMessageShellBlocks(message, normalizedBlocks));
    }

    function legacyRenderableMessageBlocks(message) {
      return appendSupplementalMessageShellBlocks(
        combineReadexProcessingBlocks(combineReasoningActivityBlocks(translatedLegacyInlineBlocks(message)), message),
        message
      );
    }

    function structuredRenderableMessageBlocks(message) {
      return appendSupplementalMessageShellBlocks(
        combineReadexProcessingBlocks(combineReasoningActivityBlocks(resolvedMessageBlocks(message)), message),
        message
      );
    }

    function structuredMessageStatus(message) {
      if (!messageHasStructuredBlocks(message)) {
        return "";
      }

      const blocks = structuredRenderableMessageBlocks(message);
      if (!blocks.length) {
        return "";
      }

      if (blocks.some((block) => block?.type === "search_progress" || normalizedStatus(block?.status) === "searching")) {
        return "searching";
      }
      if (blocks.some((block) => normalizedStatus(block?.status) === "pending")) {
        return "pending";
      }
      if (blocks.some((block) => normalizedStatus(block?.status) === "processing")) {
        return "processing";
      }
      if (blocks.some((block) => normalizedStatus(block?.status) === "streaming")) {
        return "streaming";
      }
      return "";
    }

    function messageRenderMode(message) {
      return messageHasStructuredBlocks(message) ? "structured" : "legacy";
    }

    function effectiveMessageStatus(message) {
      if (messageRenderMode(message) === "structured") {
        return structuredMessageStatus(message) || structuredMessageShellStatus(message) || "success";
      }
      return legacyMessageStatus(message) || "success";
    }

    function messageIsStreaming(message) {
      const status = effectiveMessageStatus(message);
      return status === "pending" || status === "processing" || status === "streaming" || status === "searching";
    }

    function messageIsSearchInProgress(message) {
      return effectiveMessageStatus(message) === "searching";
    }

    function renderableMessageBlocks(message) {
      if (messageRenderMode(message) === "structured") {
        return structuredRenderableMessageBlocks(message);
      }
      return legacyRenderableMessageBlocks(message);
    }

    function messagePrimaryTextContent(message) {
      const blockTextSegments = renderableMessageBlocks(message)
        .filter((block) => block?.type === "main_text")
        .map((block) => blockText(block))
        .filter((text) => trimmed(text));
      if (blockTextSegments.length) {
        return blockTextSegments.join("\n\n");
      }
      if (messageRenderMode(message) === "structured") {
        return "";
      }
      return typeof message?.content === "string" ? message.content : "";
    }

    return Object.freeze({
      structuredMessageShellStatus,
      structuredMessageStatus,
      legacyMessageStatus,
      effectiveMessageStatus,
      messageIsStreaming,
      messageIsSearchInProgress,
      legacyMessageIsStreaming,
      legacyMessageIsSearchInProgress,
      blockIsLive,
      legacyRenderableMessageBlocks,
      structuredRenderableMessageBlocks,
      messageRenderMode,
      renderableMessageBlocks,
      messagePrimaryTextContent
    });
  };
})();
