(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript document runtime dependency: ${name}`);
    }
    return value;
  }

  function requiredObject(dependencies, name) {
    const value = dependencies?.[name];
    if (!value || typeof value !== "object") {
      throw new Error(`Missing ChatTranscript document runtime dependency: ${name}`);
    }
    return value;
  }

  window.ChatTranscriptDocumentRuntimeFactory = function createChatTranscriptDocumentRuntime(dependencies) {
    const documentShell = requiredObject(dependencies, "documentShell");
    const trimmed = requiredFunction(dependencies, "trimmed");
    const postTranscriptProbe = requiredFunction(dependencies, "postTranscriptProbe");
    const transcriptScrollSnapshot = requiredFunction(dependencies, "transcriptScrollSnapshot");
    const scrollRoot = requiredFunction(dependencies, "scrollRoot");
    const currentConversationDocumentHeight = requiredFunction(dependencies, "currentConversationDocumentHeight");
    const markdownRenderer = requiredFunction(dependencies, "markdownRenderer");
    const messagesRootElement = requiredFunction(dependencies, "messagesRootElement");
    const pageElement = requiredFunction(dependencies, "pageElement");
    const applyDocumentPayloadShell = requiredFunction(documentShell, "applyPayload");

    function resolveMarkdownRenderer() {
      return markdownRenderer();
    }

    function resolveMessagesRoot() {
      return messagesRootElement();
    }

    function resolveRenderSurface() {
      return {
        messagesRoot: messagesRootElement(),
        page: pageElement()
      };
    }

    function measureConversationDocumentHeight() {
      return currentConversationDocumentHeight();
    }

    function patchFallbackMissingPatchState(reason) {
      postTranscriptProbe("patch", "fallback_rerender_missing_patch_state", {
        reason
      });
    }

    function patchFallbackMissingDOM(reason, details = {}) {
      postTranscriptProbe("patch", "fallback_rerender_missing_dom", {
        reason,
        ...details
      });
    }

    function beginPatchCycle(reason, patchState, payload) {
      applyDocumentPayloadShell(payload);
      postTranscriptProbe("patch", "begin", {
        reason,
        orderedMessages: patchState?.orderedMessageKeys?.length || 0,
        deletedMessages: patchState?.deletedKeys?.size || 0,
        changedMessages: patchState?.changedMessageKeys?.size || 0,
        changedGroups: patchState?.changedGroupKeys?.size || 0,
        requiresConversationMutation: patchState?.requiresConversationMutation !== false,
        payloadMessages: Array.isArray(payload?.messages) ? payload.messages.length : 0,
        payloadGroups: Array.isArray(payload?.messageGroups) ? payload.messageGroups.length : 0,
        payloadBlockCatalog: Array.isArray(payload?.blockCatalog) ? payload.blockCatalog.length : 0,
        ...transcriptScrollSnapshot(scrollRoot())
      });
    }

    function skipPatchMutationCycle(reason, patchState, resultHeight) {
      postTranscriptProbe("patch", "metadata_only", {
        reason,
        resultHeight: Number(resultHeight) || 0,
        orderedMessages: patchState?.orderedMessageKeys?.length || 0,
        deletedMessages: patchState?.deletedKeys?.size || 0,
        changedMessages: patchState?.changedMessageKeys?.size || 0,
        changedGroups: patchState?.changedGroupKeys?.size || 0,
        ...transcriptScrollSnapshot(scrollRoot())
      });
      return resultHeight;
    }

    function completePatchCycle(reason, resultHeight) {
      postTranscriptProbe("patch", "complete", {
        reason,
        resultHeight: Number(resultHeight) || 0,
        ...transcriptScrollSnapshot(scrollRoot())
      });
      return resultHeight;
    }

    function skipRenderCycle(reason, hasPayload, hasRenderer) {
      postTranscriptProbe("render", "skipped", {
        reason,
        hasPayload: Boolean(hasPayload),
        hasRenderer: Boolean(hasRenderer)
      });
      return 0;
    }

    function beginRenderCycle(reason, payload) {
      applyDocumentPayloadShell(payload);
      postTranscriptProbe("render", "begin", {
        reason,
        payloadMessages: Array.isArray(payload?.messages) ? payload.messages.length : 0,
        payloadGroups: Array.isArray(payload?.messageGroups) ? payload.messageGroups.length : 0,
        payloadBlockCatalog: Array.isArray(payload?.blockCatalog) ? payload.blockCatalog.length : 0,
        ...transcriptScrollSnapshot(scrollRoot())
      });
    }

    function clearLastRenderError() {
      window.__chatTranscriptLastRenderError = null;
    }

    function failRenderCycle(reason, error) {
      const message = error instanceof Error
        ? `${error.name}: ${error.message}`
        : String(error);
      window.__chatTranscriptLastRenderError = message;
      console.error("[ChatTranscriptRenderError]", error);
      postTranscriptProbe("render", "failed", {
        reason,
        error: message,
        ...transcriptScrollSnapshot(scrollRoot())
      });
      return message;
    }

    function completeRenderCycle(reason, messagesRoot) {
      const resultHeight = measureConversationDocumentHeight();
      postTranscriptProbe("render", "complete", {
        reason,
        resultHeight: Number(resultHeight) || 0,
        renderedMessages: Array.from(messagesRoot?.children || []).length,
        ...transcriptScrollSnapshot(scrollRoot())
      });
      return resultHeight;
    }

    function currentMutationReason(fallback) {
      return trimmed(window.__chatTranscriptCurrentMutationReason) || fallback;
    }

    return Object.freeze({
      applyDocumentPayloadShell,
      resolveMarkdownRenderer,
      resolveMessagesRoot,
      resolveRenderSurface,
      measureConversationDocumentHeight,
      patchFallbackMissingPatchState,
      patchFallbackMissingDOM,
      beginPatchCycle,
      skipPatchMutationCycle,
      completePatchCycle,
      skipRenderCycle,
      beginRenderCycle,
      clearLastRenderError,
      failRenderCycle,
      completeRenderCycle,
      currentMutationReason
    });
  };
})();
