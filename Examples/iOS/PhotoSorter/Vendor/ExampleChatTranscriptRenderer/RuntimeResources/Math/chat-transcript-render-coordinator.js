(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript render coordinator dependency: ${name}`);
    }
    return value;
  }

  function requiredObject(dependencies, name) {
    const value = dependencies?.[name];
    if (!value || typeof value !== "object") {
      throw new Error(`Missing ChatTranscript render coordinator dependency: ${name}`);
    }
    return value;
  }

  window.ChatTranscriptRenderCoordinatorFactory = function createChatTranscriptRenderCoordinator(dependencies) {
    const normalizedRenderOptions = requiredFunction(dependencies, "normalizedRenderOptions");
    const trimmed = requiredFunction(dependencies, "trimmed");
    const messageDOMKey = requiredFunction(dependencies, "messageDOMKey");
    const rerenderConversationPreservingScroll = requiredFunction(dependencies, "rerenderConversationPreservingScroll");
    const performConversationMutationPreservingScroll = requiredFunction(dependencies, "performConversationMutationPreservingScroll");
    const payloadModel = requiredObject(dependencies, "payloadModel");
    const payloadPatcher = requiredObject(dependencies, "payloadPatcher");
    const documentRuntime = requiredObject(dependencies, "documentRuntime");
    const conversationRenderer = requiredObject(dependencies, "conversationRenderer");
    const messageBlockRenderer = requiredObject(dependencies, "messageBlockRenderer");
    const messageArticleRenderer = requiredObject(dependencies, "messageArticleRenderer");
    const blockText = requiredFunction(dependencies, "blockText");
    const resolvePayload = requiredFunction(payloadModel, "resolvePayload");
    const normalizePayloadForRendering = requiredFunction(payloadModel, "normalizePayloadForRendering");
    const resetResolvedBlockCatalogCache = requiredFunction(payloadModel, "resetResolvedBlockCatalogCache");
    const mergePatchIntoPayload = requiredFunction(payloadPatcher, "mergePatchIntoPayload");
    const applyPatchedMessageState = requiredFunction(payloadPatcher, "applyPatchedMessageState");
    const applyDocumentPayloadShell = requiredFunction(documentRuntime, "applyDocumentPayloadShell");
    const resolveMarkdownRenderer = requiredFunction(documentRuntime, "resolveMarkdownRenderer");
    const resolveMessagesRoot = requiredFunction(documentRuntime, "resolveMessagesRoot");
    const resolveRenderSurface = requiredFunction(documentRuntime, "resolveRenderSurface");
    const patchFallbackMissingPatchState = requiredFunction(documentRuntime, "patchFallbackMissingPatchState");
    const patchFallbackMissingDOM = requiredFunction(documentRuntime, "patchFallbackMissingDOM");
    const beginPatchCycle = requiredFunction(documentRuntime, "beginPatchCycle");
    const skipPatchMutationCycle = requiredFunction(documentRuntime, "skipPatchMutationCycle");
    const completePatchCycle = requiredFunction(documentRuntime, "completePatchCycle");
    const skipRenderCycle = requiredFunction(documentRuntime, "skipRenderCycle");
    const beginRenderCycle = requiredFunction(documentRuntime, "beginRenderCycle");
    const clearLastRenderError = requiredFunction(documentRuntime, "clearLastRenderError");
    const failRenderCycle = requiredFunction(documentRuntime, "failRenderCycle");
    const completeRenderCycle = requiredFunction(documentRuntime, "completeRenderCycle");
    const currentMutationReason = requiredFunction(documentRuntime, "currentMutationReason");
    const applyConversationPatch = requiredFunction(conversationRenderer, "applyPatch");
    const reconcileConversation = requiredFunction(conversationRenderer, "reconcile");
    const applyMarkdownBlockSourceUpdate = requiredFunction(messageBlockRenderer, "applyMarkdownBlockSourceUpdate");
    const applyProcessingBlockSourceUpdate = requiredFunction(messageBlockRenderer, "applyProcessingBlockSourceUpdate");
    const syncMessageArticleChrome = requiredFunction(messageArticleRenderer, "syncMessageArticleChrome");
    const reconcileMessageBlocks = requiredFunction(messageBlockRenderer, "reconcileMessageBlocks");

    function normalizedUpdates(batch) {
      return Array.isArray(batch?.updates) ? batch.updates.filter(Boolean) : [];
    }

    function kindIsProcessing(kind) {
      return kind === "chat_processing" || kind === "readex_processing";
    }

    function kindIsProgress(kind) {
      return kind === "chat_progress" || kind === "readex_progress";
    }

    function kindIsToolCall(kind) {
      return kind === "chat_tool_call" || kind === "readex_tool_call";
    }

    function kindIsToolActivity(kind) {
      return kind === "chat_tool_activity" || kind === "readex_tool_activity";
    }

    function cssAttributeValue(value) {
      const string = String(value || "");
      if (typeof CSS !== "undefined" && typeof CSS.escape === "function") {
        return CSS.escape(string);
      }
      return string
        .replace(/\\/g, "\\\\")
        .replace(/"/g, "\\\"")
        .replace(/\n/g, "\\A ")
        .replace(/\r/g, "\\D ")
        .replace(/\f/g, "\\C ");
    }

    function dataAttributeSelector(attributeName, value) {
      return `[${attributeName}="${cssAttributeValue(value)}"]`;
    }

    function performanceNow() {
      const value = Number(window.performance?.now?.());
      return Number.isFinite(value) ? value : Date.now();
    }

    function elapsedMilliseconds(start) {
      return Math.max(performanceNow() - start, 0);
    }

    function updatePayloadCatalogBlock(payload, block) {
      if (!payload || !block || typeof block !== "object") {
        return false;
      }
      const blockID = typeof block.id === "string" ? block.id.trim() : "";
      if (!blockID) {
        return false;
      }
      const catalog = Array.isArray(payload.blockCatalog) ? payload.blockCatalog : [];
      const index = catalog.findIndex((entry) => {
        const entryID = typeof entry?.id === "string" ? entry.id.trim() : "";
        return entryID === blockID;
      });
      if (index < 0) {
        return false;
      }
      catalog[index] = block;
      payload.blockCatalog = catalog;
      return true;
    }

    function normalizedID(value) {
      if (value === null || value === undefined) {
        return "";
      }
      return String(value).trim();
    }

    function addID(set, value) {
      const id = normalizedID(value);
      if (id) {
        set.add(id);
      }
    }

    function addNestedID(set, object, key) {
      if (!object || typeof object !== "object") {
        return;
      }
      addID(set, object[key]);
    }

    function collectToolActivityIDs(value) {
      const ids = new Set();
      if (!value || typeof value !== "object") {
        return ids;
      }
      addID(ids, value.id);
      addID(ids, value.sourceBlockId);
      addID(ids, value.sourceBlockID);
      addID(ids, value.callID);
      addID(ids, value.callId);
      const commandExecution = value.commandExecution;
      addNestedID(ids, commandExecution, "callID");
      addNestedID(ids, commandExecution, "callId");
      (Array.isArray(value.items) ? value.items : []).forEach((item) => {
        addID(ids, item?.id);
        addID(ids, item?.sourceBlockId);
        addID(ids, item?.sourceBlockID);
        addID(ids, item?.callID);
        addID(ids, item?.callId);
        addNestedID(ids, item?.commandExecution, "callID");
        addNestedID(ids, item?.commandExecution, "callId");
      });
      return ids;
    }

    function setIntersects(left, right) {
      for (const value of left) {
        if (right.has(value)) {
          return true;
        }
      }
      return false;
    }

    function findToolActivitySupportBlockIndex(supportBlocks, preferredIndex, block) {
      const sourceIDs = collectToolActivityIDs(block);
      const preferredBlock = Number.isInteger(preferredIndex) ? supportBlocks[preferredIndex] : null;
      if (
        preferredBlock &&
        kindIsToolCall(preferredBlock.kind) &&
        (!sourceIDs.size || setIntersects(sourceIDs, collectToolActivityIDs(preferredBlock)))
      ) {
        return preferredIndex;
      }
      if (sourceIDs.size) {
        const matchedIndex = supportBlocks.findIndex((supportBlock) => (
          kindIsToolCall(supportBlock?.kind) &&
          setIntersects(sourceIDs, collectToolActivityIDs(supportBlock))
        ));
        if (matchedIndex >= 0) {
          return matchedIndex;
        }
      }
      return -1;
    }

    function updatedToolActivitySupportBlock(supportBlock, block) {
      return {
        ...supportBlock,
        items: Array.isArray(block.items) ? block.items : supportBlock.items,
        text: blockText(block) || supportBlock.text,
        status: block.status || supportBlock.status,
        durationMilliseconds: block.durationMilliseconds ?? supportBlock.durationMilliseconds,
        startedAtMilliseconds: block.startedAtMilliseconds ?? supportBlock.startedAtMilliseconds,
        sourceBlockId: block.sourceBlockId || supportBlock.sourceBlockId,
        sourceBlockID: block.sourceBlockID || supportBlock.sourceBlockID
      };
    }

    function updatePayloadInlineMessageBlock(payload, update) {
      const payloadMessage = findPayloadMessageByKey(payload, update?.messageKey);
      const block = update?.block && typeof update.block === "object" ? update.block : null;
      const blockID = trimmed(update?.blockID || block?.id);
      const blockType = trimmed(block?.type);
      if (!payloadMessage || !block || !blockID) {
        return false;
      }

      const inlineBlocks = Array.isArray(payloadMessage.blocks) ? payloadMessage.blocks : [];
      for (let index = 0; index < inlineBlocks.length; index += 1) {
        const entry = inlineBlocks[index];
        if (entry && typeof entry === "object" && trimmed(entry.id) === blockID) {
          inlineBlocks[index] = block;
          payloadMessage.blocks = inlineBlocks;
          return true;
        }
      }

      if (blockType === "main_text" && blockID.endsWith(":content")) {
        payloadMessage.content = blockText(block);
        return true;
      }

      const progressMatch = /:(?:chat_progress|readex_progress):(\d+)$/.exec(blockID);
      if (kindIsProgress(blockType) && progressMatch) {
        const supportIndex = Number(progressMatch[1]);
        const supportBlocks = Array.isArray(payloadMessage.supportBlocks) ? payloadMessage.supportBlocks : [];
        const supportBlock = Number.isInteger(supportIndex) ? supportBlocks[supportIndex] : null;
        if (supportBlock && kindIsProgress(supportBlock.kind)) {
          supportBlocks[supportIndex] = {
            ...supportBlock,
            text: blockText(block),
            status: block.status || supportBlock.status
          };
          payloadMessage.supportBlocks = supportBlocks;
          return true;
        }
      }

      const toolActivityMatch = /:(?:chat_tool_activity|readex_tool_activity):(\d+)$/.exec(blockID);
      if (kindIsToolActivity(blockType) && toolActivityMatch) {
        const supportIndex = Number(toolActivityMatch[1]);
        const supportBlocks = Array.isArray(payloadMessage.supportBlocks) ? payloadMessage.supportBlocks : [];
        const matchedIndex = findToolActivitySupportBlockIndex(supportBlocks, supportIndex, block);
        if (matchedIndex >= 0) {
          supportBlocks[matchedIndex] = updatedToolActivitySupportBlock(supportBlocks[matchedIndex], block);
          payloadMessage.supportBlocks = supportBlocks;
          return true;
        }
      }

      return false;
    }

    function findPayloadMessageByKey(payload, messageKey) {
      const key = trimmed(messageKey);
      if (!payload || !key) {
        return null;
      }
      return (Array.isArray(payload.messages) ? payload.messages : [])
        .find((message, index) => messageDOMKey(message, index) === key) || null;
    }

    function findArticleByMessageKey(messagesRoot, messageKey) {
      const key = trimmed(messageKey);
      if (!messagesRoot || !key) {
        return null;
      }
      return messagesRoot.querySelector?.(`article.message${dataAttributeSelector("data-message-key", key)}`) || null;
    }

    function directChildWithClass(element, className) {
      const resolvedClassName = trimmed(className);
      if (!element || !resolvedClassName) {
        return null;
      }
      return Array.from(element.children || [])
        .find((child) => child?.classList?.contains(resolvedClassName)) || null;
    }

    function findArticleMessageMain(article) {
      const bubble = directChildWithClass(article, "message-bubble");
      const layout = directChildWithClass(bubble, "message-layout");
      const main = directChildWithClass(layout, "message-main");
      return main || article?.querySelector?.(".message-main") || null;
    }

    function applyStreamingUpdateMessagePayloadState(update, payload) {
      const state = update?.messageState && typeof update.messageState === "object"
        ? update.messageState
        : null;
      if (!state) {
        return { updated: false, payloadMessage: null };
      }

      const messageKey = trimmed(update?.messageKey);
      const payloadMessage = findPayloadMessageByKey(payload, messageKey);
      if (!payloadMessage) {
        return { updated: false, payloadMessage: null };
      }
      applyPatchedMessageState(payloadMessage, state, { structuredBlocks: true });
      return { updated: true, payloadMessage };
    }

    function syncStreamingUpdateMessageDOMState(update, messagesRoot, payload) {
      const messageKey = trimmed(update?.messageKey);
      const payloadMessage = findPayloadMessageByKey(payload, messageKey);
      if (!payloadMessage) {
        return false;
      }
      const article = findArticleByMessageKey(messagesRoot, messageKey);
      if (article) {
        article.__chatTranscriptMessage = payloadMessage;
        article.dataset.messageStatus = typeof payloadMessage.status === "string"
          ? payloadMessage.status
          : "";
        if (update?.syncMessageChrome === true) {
          syncMessageArticleChrome(article, payloadMessage, messageKey);
        }
        return true;
      }
      return false;
    }

    function applyStreamingMarkdownPayloadUpdates(batch, payload) {
      const updates = normalizedUpdates(batch);
      const results = [];
      let appliedCatalogCount = 0;
      updates.forEach((update) => {
        const kind = typeof update?.kind === "string" ? update.kind.trim() : "";
        const shouldSyncMessageState = update?.syncMessageChrome === true || kindIsProcessing(kind);
        const messageStateResult = shouldSyncMessageState
          ? applyStreamingUpdateMessagePayloadState(update, payload)
          : { updated: false, payloadMessage: null };
        const blockUpdated = updatePayloadCatalogBlock(payload, update?.block)
          || updatePayloadInlineMessageBlock(payload, update);
        if (!blockUpdated) {
          throw new Error([
            "Streaming markdown payload update missed catalog",
            `kind=${kind || "unknown"}`,
            `messageKey=${String(update?.messageKey || "")}`,
            `blockID=${String(update?.blockID || update?.block?.id || "")}`
          ].join(" "));
        }
        appliedCatalogCount += 1;
        results.push({
          kind,
          blockUpdated,
          messageStateUpdated: messageStateResult.updated
        });
      });
      resetResolvedBlockCatalogCache();
      return { appliedCatalogCount, results };
    }

    function applyStreamingMarkdownDOMUpdates(batch, renderer, messagesRoot, payload, options = {}) {
      const updates = normalizedUpdates(batch);
      const results = [];
      updates.forEach((update) => {
        const kind = typeof update?.kind === "string" ? update.kind.trim() : "";
        const messageStateDOMUpdated = update?.syncMessageChrome === true
          ? syncStreamingUpdateMessageDOMState(update, messagesRoot, payload)
          : false;
        let result = null;
        try {
          result = kindIsProcessing(kind)
            ? applyProcessingBlockSourceUpdate(update, renderer, messagesRoot)
            : applyMarkdownBlockSourceUpdate(update, renderer, messagesRoot);
        } catch (error) {
          result = {
            applied: false,
            reason: "direct_update_error",
            errorMessage: error instanceof Error ? error.message : String(error)
          };
        }
        const applied = result && typeof result === "object" && result.applied === true;
        if (!applied) {
          const reason = typeof result?.reason === "string" ? result.reason : "not_applied";
          const fallback = reconcileStreamingUpdateMessageBlocks(update, renderer, messagesRoot, payload, result);
          if (!fallback || fallback.applied !== true) {
            const fallbackReason = typeof fallback?.reason === "string" ? fallback.reason : "not_applied";
            throw new Error([
              "Streaming markdown direct update missed DOM",
              `kind=${kind || "unknown"}`,
              `messageKey=${String(update?.messageKey || "")}`,
              `blockID=${String(update?.blockID || update?.block?.id || "")}`,
              `reason=${reason}`,
              `fallbackReason=${fallbackReason}`
            ].join(" "));
          }
          results.push({
            kind,
            messageStateDOMUpdated,
            directResult: result && typeof result === "object" ? result : { applied: false, reason },
            ...fallback
          });
          return;
        }
        results.push({
          kind,
          messageStateDOMUpdated,
          ...(result && typeof result === "object" ? result : { applied: false, reason: "missing_result" })
        });
      });
      return {
        results,
        resultHeight: options.measureDocumentHeight === false
          ? 0
          : documentRuntime.measureConversationDocumentHeight()
      };
    }

    function reconcileStreamingUpdateMessageBlocks(update, renderer, messagesRoot, payload, directResult = null) {
      const messageKey = trimmed(update?.messageKey);
      const payloadMessage = findPayloadMessageByKey(payload, messageKey);
      const article = findArticleByMessageKey(messagesRoot, messageKey);
      const main = findArticleMessageMain(article);
      if (!payloadMessage || !article || !main) {
        return {
          applied: false,
          reason: !payloadMessage ? "missing_payload_message" : (!article ? "missing_article" : "missing_message_main"),
          directReason: typeof directResult?.reason === "string" ? directResult.reason : "",
          messageKey,
          blockKey: trimmed(update?.blockID || update?.block?.id)
        };
      }
      article.__chatTranscriptMessage = payloadMessage;
      reconcileMessageBlocks(main, payloadMessage, renderer);
      return {
        applied: true,
        reason: "reconciled_message_blocks",
        directReason: typeof directResult?.reason === "string" ? directResult.reason : "",
        messageKey,
        blockKey: trimmed(update?.blockID || update?.block?.id)
      };
    }

    function streamingScrollRoot() {
      return document.scrollingElement || document.documentElement || document.body || null;
    }

    function streamingMaximumScrollOffset(root) {
      return Math.max((Number(root?.scrollHeight) || 0) - (Number(root?.clientHeight) || 0), 0);
    }

    function streamingDistanceFromBottom(root) {
      return Math.max(streamingMaximumScrollOffset(root) - (Number(root?.scrollTop) || 0), 0);
    }

    function followStreamingBottomIfNeeded(root, shouldFollowBottom) {
      if (!root || !shouldFollowBottom) {
        return;
      }
      root.scrollTop = streamingMaximumScrollOffset(root);
    }

    function streamingDocumentHeight(root) {
      return Number(root?.scrollHeight) || 0;
    }

    function applyPatchPreservingScroll(patch, followBottomOrOptions) {
      const options = normalizedRenderOptions(followBottomOrOptions);
      const debugReason = options.debugReason || "apply_conversation_patch";
      const patchState = mergePatchIntoPayload(patch);
      if (!patchState) {
        patchFallbackMissingPatchState(debugReason);
        return rerenderConversationPreservingScroll({
          ...options,
          debugReason: `${debugReason}_fallback_missing_patch_state`
        });
      }

      const renderer = resolveMarkdownRenderer();
      const messagesRoot = resolveMessagesRoot();
      const payload = patchState.payload;
      if (!renderer || !messagesRoot || !payload) {
        patchFallbackMissingDOM(debugReason, {
          hasRenderer: Boolean(renderer),
          hasMessagesRoot: Boolean(messagesRoot),
          hasPayload: Boolean(payload)
        });
        return rerenderConversationPreservingScroll({
          ...options,
          debugReason: `${debugReason}_fallback_missing_dom`
        });
      }

      beginPatchCycle(debugReason, patchState, payload);
      if (patchState.requiresConversationMutation === false) {
        const resultHeight = documentRuntime.measureConversationDocumentHeight();
        skipPatchMutationCycle(debugReason, patchState, resultHeight);
        return completePatchCycle(debugReason, resultHeight);
      }

      const result = performConversationMutationPreservingScroll(
        options,
        () => applyConversationPatch(messagesRoot, patchState, renderer)
      );
      return completePatchCycle(debugReason, result);
    }

    function updateStreamingMarkdownBlocks(batch, followBottomOrOptions) {
      const startedAt = performanceNow();
      const options = normalizedRenderOptions(followBottomOrOptions);
      const renderer = resolveMarkdownRenderer();
      const messagesRoot = resolveMessagesRoot();
      const payload = resolvePayload();
      if (!renderer || !messagesRoot || !payload) {
        patchFallbackMissingDOM("update_streaming_markdown_blocks", {
          hasRenderer: Boolean(renderer),
          hasMessagesRoot: Boolean(messagesRoot),
          hasPayload: Boolean(payload)
        });
        return rerenderConversationPreservingScroll({
          ...options,
          debugReason: "update_streaming_markdown_blocks_fallback_missing_dom"
        });
      }

      const debugReason = options.debugReason || "update_streaming_markdown_blocks";
      const previousMutationReason = window.__chatTranscriptCurrentMutationReason;
      let payloadUpdateResult = null;
      let domUpdateResult = null;
      let payloadElapsedMilliseconds = 0;
      let domElapsedMilliseconds = 0;
      let followBottomElapsedMilliseconds = 0;
      const root = streamingScrollRoot();
      const shouldFollowBottom = Boolean(options.followBottomIfNearBottom)
        && Boolean(root)
        && streamingDistanceFromBottom(root) <= 64;
      try {
        window.__chatTranscriptCurrentMutationReason = debugReason;
        const payloadStartedAt = performanceNow();
        payloadUpdateResult = applyStreamingMarkdownPayloadUpdates(batch, payload);
        payloadElapsedMilliseconds = elapsedMilliseconds(payloadStartedAt);
        const domStartedAt = performanceNow();
        domUpdateResult = applyStreamingMarkdownDOMUpdates(batch, renderer, messagesRoot, payload, {
          measureDocumentHeight: false
        });
        domElapsedMilliseconds = elapsedMilliseconds(domStartedAt);
        const followBottomStartedAt = performanceNow();
        followStreamingBottomIfNeeded(root, shouldFollowBottom);
        followBottomElapsedMilliseconds = elapsedMilliseconds(followBottomStartedAt);
      } finally {
        window.__chatTranscriptCurrentMutationReason = previousMutationReason;
      }
      const updates = normalizedUpdates(batch);
      return {
        updateCount: updates.length,
        appliedCatalogCount: Number(payloadUpdateResult?.appliedCatalogCount) || 0,
        results: Array.isArray(payloadUpdateResult?.results) ? payloadUpdateResult.results : [],
        directDOMResults: Array.isArray(domUpdateResult?.results) ? domUpdateResult.results : [],
        resultHeight: Number(domUpdateResult?.resultHeight) || streamingDocumentHeight(root),
        textLength: updates.reduce((total, update) => total + String(blockText(update?.block) || update?.text || "").length, 0),
        timings: {
          totalMs: elapsedMilliseconds(startedAt),
          payloadMs: payloadElapsedMilliseconds,
          domMs: domElapsedMilliseconds,
          followBottomMs: followBottomElapsedMilliseconds
        }
      };
    }

    function renderConversation() {
      const payload = resolvePayload();
      const renderer = resolveMarkdownRenderer();
      if (!payload || !renderer) {
        return skipRenderCycle(
          currentMutationReason("render_conversation"),
          Boolean(payload),
          Boolean(renderer)
        );
      }

      normalizePayloadForRendering(payload);
      const debugReason = currentMutationReason("render_conversation");
      beginRenderCycle(debugReason, payload);

      const { messagesRoot, page } = resolveRenderSurface();
      if (!messagesRoot || !page) {
        return 0;
      }

      clearLastRenderError();
      try {
        reconcileConversation(messagesRoot, payload.messages || [], renderer);
      } catch (error) {
        failRenderCycle(debugReason, error);
        throw error;
      }

      return completeRenderCycle(debugReason, messagesRoot);
    }

    return Object.freeze({
      applyDocumentPayloadShell,
      applyPatchPreservingScroll,
      updateStreamingMarkdownBlocks,
      renderConversation
    });
  };
})();
