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

    function normalizedUpdates(batch) {
      return Array.isArray(batch?.updates) ? batch.updates.filter(Boolean) : [];
    }

    function kindIsProcessing(kind) {
      return kind === "chat_processing" || kind === "readex_processing";
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
      return Array.from(messagesRoot.querySelectorAll?.("article.message") || [])
        .find((article) => trimmed(article?.dataset?.messageKey) === key) || null;
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
        const blockUpdated = updatePayloadCatalogBlock(payload, update?.block);
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
        let result = kindIsProcessing(kind)
          ? applyProcessingBlockSourceUpdate(update, renderer, messagesRoot)
          : applyMarkdownBlockSourceUpdate(update, renderer, messagesRoot);
        const applied = result && typeof result === "object" && result.applied === true;
        if (!applied) {
          const reason = typeof result?.reason === "string" ? result.reason : "not_applied";
          throw new Error([
            "Streaming markdown direct update missed DOM",
            `kind=${kind || "unknown"}`,
            `messageKey=${String(update?.messageKey || "")}`,
            `blockID=${String(update?.blockID || update?.block?.id || "")}`,
            `reason=${reason}`
          ].join(" "));
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
      const root = streamingScrollRoot();
      const shouldFollowBottom = Boolean(options.followBottomIfNearBottom)
        && Boolean(root)
        && streamingDistanceFromBottom(root) <= 64;
      try {
        window.__chatTranscriptCurrentMutationReason = debugReason;
        payloadUpdateResult = applyStreamingMarkdownPayloadUpdates(batch, payload);
        domUpdateResult = applyStreamingMarkdownDOMUpdates(batch, renderer, messagesRoot, payload, {
          measureDocumentHeight: false
        });
        followStreamingBottomIfNeeded(root, shouldFollowBottom);
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
        textLength: updates.reduce((total, update) => total + String(blockText(update?.block) || update?.text || "").length, 0)
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
