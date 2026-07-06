(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript presentation controller dependency: ${name}`);
    }
    return value;
  }

  window.ChatTranscriptPresentationControllerFactory = function createChatTranscriptPresentationController(dependencies) {
    const trimmed = requiredFunction(dependencies, "trimmed");
    const transcriptUIState = requiredFunction(dependencies, "transcriptUIState");
    const transcriptPresentation = requiredFunction(dependencies, "transcriptPresentation");
    const hideActiveTooltip = requiredFunction(dependencies, "hideActiveTooltip");
    const postTranscriptProbe = requiredFunction(dependencies, "postTranscriptProbe");
    const scrollRoot = requiredFunction(dependencies, "scrollRoot");
    const transcriptScrollSnapshot = requiredFunction(dependencies, "transcriptScrollSnapshot");
    const applyConversationPresentationStyle = requiredFunction(dependencies, "applyConversationPresentationStyle");
    const hasRenderedMessages = requiredFunction(dependencies, "hasRenderedMessages");
    const syncPresentationState = requiredFunction(dependencies, "syncPresentationState");
    const rerenderConversationPreservingScroll = requiredFunction(dependencies, "rerenderConversationPreservingScroll");
    const messageUIRenderer = requiredFunction(dependencies, "messageUIRenderer");
    const messageArticleRenderer = requiredFunction(dependencies, "messageArticleRenderer");

    function normalizedAssistantModelOptions(options) {
      const safeOptions = Array.isArray(options) ? options : [];
      return safeOptions.map((option) => ({
        id: trimmed(option?.id),
        providerScopedDisplayName: trimmed(option?.providerScopedDisplayName),
        modelID: trimmed(option?.modelID),
        resolvedDisplayName: trimmed(option?.resolvedDisplayName)
      }));
    }

    function renderSensitivePresentationSignature(presentation) {
      if (!presentation) {
        return "";
      }

      return JSON.stringify({
        isConversationGenerating: Boolean(presentation.isConversationGenerating),
        assistantModelOptions: normalizedAssistantModelOptions(presentation.assistantModelOptions)
      });
    }

    const DEFAULT_CHAT_MARKDOWN_RENDERER_PROFILE = "legacy-chat";

    function canonicalRendererProfile(value) {
      const profile = trimmed(value);
      return profile === "legacy-readex" ? DEFAULT_CHAT_MARKDOWN_RENDERER_PROFILE : profile;
    }

    function normalizedRendererProfile(value) {
      return canonicalRendererProfile(value) || DEFAULT_CHAT_MARKDOWN_RENDERER_PROFILE;
    }

    function presentationRendererProfile(presentation) {
      return trimmed(presentation?.chatMarkdownRendererProfile) ||
        trimmed(presentation?.readexMarkdownRendererProfile);
    }

    function syncPayloadPresentationMetadata(presentation) {
      const payload = window.__chatTranscriptPayload;
      if (!payload || typeof payload !== "object") {
        return;
      }

      payload.theme = presentation.theme === "dark" ? "dark" : "light";
      const rendererProfile = canonicalRendererProfile(presentationRendererProfile(presentation));
      if (rendererProfile) {
        payload.chatMarkdownRendererProfile = rendererProfile;
      } else {
        delete payload.chatMarkdownRendererProfile;
      }
      delete payload.readexMarkdownRendererProfile;
      payload.style = presentation.style || null;
    }

    function setConversationPresentation(presentation) {
      if (!presentation) {
        return false;
      }

      const previousPresentation = transcriptPresentation();
      const previousRendererProfile = normalizedRendererProfile(
        presentationRendererProfile(previousPresentation) ||
        trimmed(window.__chatTranscriptPayload?.chatMarkdownRendererProfile) ||
        trimmed(window.__chatTranscriptPayload?.readexMarkdownRendererProfile)
      );
      const nextRendererProfile = normalizedRendererProfile(presentationRendererProfile(presentation));
      const rendererProfileChanged = previousRendererProfile !== nextRendererProfile;
      const previousGenerating = Boolean(previousPresentation?.isConversationGenerating);
      const nextGenerating = Boolean(presentation.isConversationGenerating);
      const previousFocusedMessageID = trimmed(previousPresentation?.focusedMessageID);
      const nextFocusedMessageID = trimmed(presentation.focusedMessageID);
      const previousRenderSensitiveSignature = renderSensitivePresentationSignature(previousPresentation);
      const nextRenderSensitiveSignature = renderSensitivePresentationSignature(presentation);
      const renderSensitiveChanged = previousRenderSensitiveSignature !== nextRenderSensitiveSignature;
      const suppressConversationRerender = Boolean(window.__chatTranscriptSkipPresentationRerender);
      const hasMessages = hasRenderedMessages();
      const shouldRefreshMessageChrome = renderSensitiveChanged && hasMessages;
      const shouldRerenderConversation = rendererProfileChanged && hasMessages && !suppressConversationRerender;
      postTranscriptProbe("presentation", "begin", {
        reason: "set_conversation_presentation",
        suppressConversationRerender,
        previousRendererProfile,
        nextRendererProfile,
        rendererProfileChanged,
        previousGenerating,
        nextGenerating,
        previousFocusedMessageID,
        nextFocusedMessageID,
        previousAssistantModelOptions: Array.isArray(previousPresentation?.assistantModelOptions) ? previousPresentation.assistantModelOptions.length : 0,
        nextAssistantModelOptions: Array.isArray(presentation.assistantModelOptions) ? presentation.assistantModelOptions.length : 0,
        renderSensitiveChanged,
        shouldRefreshMessageChrome,
        shouldRerenderConversation,
        hasMessages,
        ...transcriptScrollSnapshot(scrollRoot())
      });
      window.__chatTranscriptPresentation = presentation;
      if (presentation.isConversationGenerating) {
        const state = transcriptUIState();
        state.visibleUserToolbarMessageIDs = {};
        state.activeModelPickerMessageId = null;
        hideActiveTooltip();
      }
      syncPayloadPresentationMetadata(presentation);
      applyConversationPresentationStyle(presentation);
      syncPresentationState(presentation);

      const articleRenderer = messageArticleRenderer();
      if (shouldRefreshMessageChrome && articleRenderer && typeof articleRenderer.refreshPresentationSensitiveMessageUI === "function") {
        articleRenderer.refreshPresentationSensitiveMessageUI();
      }
      const uiRenderer = messageUIRenderer();
      if (uiRenderer && typeof uiRenderer.syncAssistantModelPickerModal === "function") {
        uiRenderer.syncAssistantModelPickerModal();
      }

      const rerenderResult = shouldRerenderConversation
        ? rerenderConversationPreservingScroll({
            followBottomIfNearBottom: true,
            forceImmediateRender: true,
            debugReason: "presentation_renderer_profile_change"
          })
        : 0;

      const completionSnapshot = transcriptScrollSnapshot(scrollRoot());
      postTranscriptProbe("presentation", "complete", {
        reason: "set_conversation_presentation",
        suppressConversationRerender,
        previousRendererProfile,
        nextRendererProfile,
        rendererProfileChanged,
        previousGenerating,
        nextGenerating,
        previousFocusedMessageID,
        nextFocusedMessageID,
        renderSensitiveChanged,
        shouldRefreshMessageChrome,
        shouldRerenderConversation,
        rerenderResultHeight: Number(rerenderResult) || 0,
        ...completionSnapshot
      });

      return {
        suppressConversationRerender,
        previousGenerating,
        nextGenerating,
        previousFocusedMessageID,
        nextFocusedMessageID,
        renderSensitiveChanged,
        shouldRefreshMessageChrome,
        shouldRerenderConversation,
        rerenderResultHeight: Number(rerenderResult) || 0,
        ...completionSnapshot
      };
    }

    return Object.freeze({
      setConversationPresentation
    });
  };
})();
