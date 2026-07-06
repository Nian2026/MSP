(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript render pipeline dependency: ${name}`);
    }
    return value;
  }

  function requiredObject(dependencies, name) {
    const value = dependencies?.[name];
    if (!value || typeof value !== "object") {
      throw new Error(`Missing ChatTranscript render pipeline dependency: ${name}`);
    }
    return value;
  }

  function stageFailure(kind, error) {
    const normalizedError = error instanceof Error ? error : new Error(String(error));
    normalizedError.chatTranscriptBootstrapKind = kind;
    throw normalizedError;
  }

  window.ChatTranscriptRenderPipelineFactory = function createChatTranscriptRenderPipeline(dependencies) {
    const createMessageBlockSupportRenderer = requiredFunction(dependencies, "createMessageBlockSupportRenderer");
    const createMessageBlockRenderer = requiredFunction(dependencies, "createMessageBlockRenderer");
    const createMessageUIRenderer = requiredFunction(dependencies, "createMessageUIRenderer");
    const createMessageArticleRenderer = requiredFunction(dependencies, "createMessageArticleRenderer");
    const createVideoProgressRenderer = requiredFunction(dependencies, "createVideoProgressRenderer");
    const createRendererComponents = requiredFunction(dependencies, "createRendererComponents");
    const createConversationRenderer = requiredFunction(dependencies, "createConversationRenderer");
    const trimmed = requiredFunction(dependencies, "trimmed");
    const blockText = requiredFunction(dependencies, "blockText");
    const currentConversationDocumentHeight = requiredFunction(dependencies, "currentConversationDocumentHeight");
    const scrollRoot = requiredFunction(dependencies, "scrollRoot");
    const resolveMarkdownRenderer = requiredFunction(dependencies, "resolveMarkdownRenderer");
    const visualSupport = requiredObject(dependencies, "visualSupport");
    const statusModel = requiredObject(dependencies, "statusModel");
    const runtimeModel = requiredObject(dependencies, "runtimeModel");
    const renderSupport = requiredObject(dependencies, "renderSupport");
    const hostBridge = requiredObject(dependencies, "hostBridge");
    const interactionState = requiredObject(dependencies, "interactionState");
    const conversationController = requiredObject(dependencies, "conversationController");
    const overlayController = requiredObject(dependencies, "overlayController");
    const payloadModel = requiredObject(dependencies, "payloadModel");
    const resolvePayload = requiredFunction(payloadModel, "resolvePayload");
    const conversationLayout = requiredObject(dependencies, "conversationLayout");

    let messageBlockSupportRenderer = null;
    let messageBlockRenderer = null;
    let messageUIRenderer = null;
    let messageArticleRenderer = null;
    let videoProgressRenderer = null;
    let rendererComponents = null;
    let conversationRenderer = null;

    function transcriptDisplayMessages(messages) {
      return conversationLayout.displayMessages(
        messages,
        resolvePayload(),
        window.__chatTranscriptDisplayWindow
      );
    }

    function groupedConversationMessages(messages) {
      return conversationLayout.groupedMessages(
        messages,
        resolvePayload()?.messageGroups
      );
    }

    function afterMessagesUpdated() {
      overlayController.syncCitationPreviewChipStates();
      overlayController.syncCitationPreviewModal();
      if (messageUIRenderer && typeof messageUIRenderer.syncAssistantModelPickerModal === "function") {
        messageUIRenderer.syncAssistantModelPickerModal();
      }
    }

    try {
      videoProgressRenderer = createVideoProgressRenderer({
        trimmed,
        makeIcon: visualSupport.makeIcon
      });
    } catch (error) {
      stageFailure("video_progress_renderer", error);
    }

    try {
      messageBlockSupportRenderer = createMessageBlockSupportRenderer({
        trimmed,
        blockText,
        makeIcon: visualSupport.makeIcon,
        appendIcon: visualSupport.appendIcon,
        readexAccentColor: visualSupport.readexAccentColor,
        blockIsLive: statusModel.blockIsLive,
        messageIsStreaming: runtimeModel.messageIsStreaming,
        markdownRenderOptions: renderSupport.markdownRenderOptions,
        renderMarkdownIntoElement: renderSupport.renderMarkdownIntoElement,
        formatThinkingSeconds: visualSupport.formatThinkingSeconds,
        directChildByClass: renderSupport.directChildByClass,
        removeDirectChild: renderSupport.removeDirectChild,
        replaceElementIfSignatureChanged: renderSupport.replaceElementIfSignatureChanged,
        transcriptUIState: hostBridge.transcriptUIState,
        citationPreviewStateKey: overlayController.citationPreviewStateKey,
        toggleCitationPreview: overlayController.toggleCitationPreview,
        populateReferenceAvatar: visualSupport.populateReferenceAvatar,
        displayTitleForReference: visualSupport.displayTitleForReference,
        hostnameForReference: visualSupport.hostnameForReference,
        renderBranchNotice: visualSupport.renderBranchNotice,
        patchBranchNotice: visualSupport.patchBranchNotice,
        isThinkingBlockExpanded: interactionState.isThinkingBlockExpanded,
        hasExplicitThinkingBlockExpandedState: interactionState.hasExplicitThinkingBlockExpandedState,
        setThinkingBlockExpanded: interactionState.setThinkingBlockExpanded,
        postAttachmentOpen: hostBridge.postAttachmentOpen,
        postMessageAction: hostBridge.postMessageAction,
        postPresentationProbe: hostBridge.postPresentationProbe,
        resolveMarkdownRenderer,
        renderReadexVideoProgressBlock: videoProgressRenderer.renderReadexVideoProgressBlock
      });
    } catch (error) {
      stageFailure("message_block_support_renderer", error);
    }

    try {
      messageBlockRenderer = createMessageBlockRenderer({
        trimmed,
        blockText,
        messageIsStreaming: runtimeModel.messageIsStreaming,
        markdownRenderOptions: renderSupport.markdownRenderOptions,
        renderMarkdownIntoElement: renderSupport.renderMarkdownIntoElement,
        refreshRenderedMarkdownDecorators: renderSupport.refreshRenderedMarkdownDecorators,
        postMainTextRenderProbe: renderSupport.postMainTextRenderProbe,
        renderThinkingBlock: messageBlockSupportRenderer.renderThinkingBlock,
        updateThinkingBlockElement: messageBlockSupportRenderer.updateThinkingBlockElement,
        renderReasoningSummaryBlock: messageBlockSupportRenderer.renderReasoningSummaryBlock,
        updateReasoningSummaryBlockElement: messageBlockSupportRenderer.updateReasoningSummaryBlockElement,
        renderReasoningActivityBlock: messageBlockSupportRenderer.renderReasoningActivityBlock,
        updateReasoningActivityBlockElement: messageBlockSupportRenderer.updateReasoningActivityBlockElement,
        renderReadexProcessingBlock: messageBlockSupportRenderer.renderReadexProcessingBlock,
        updateReadexProcessingBlockElement: messageBlockSupportRenderer.updateReadexProcessingBlockElement,
        renderReadexStoppedMarkerBlock: messageBlockSupportRenderer.renderReadexStoppedMarkerBlock,
        updateReadexStoppedMarkerBlockElement: messageBlockSupportRenderer.updateReadexStoppedMarkerBlockElement,
        renderReadexContextStatusBlock: messageBlockSupportRenderer.renderReadexContextStatusBlock,
        updateReadexContextStatusBlockElement: messageBlockSupportRenderer.updateReadexContextStatusBlockElement,
        renderReadexToolActivityBlock: messageBlockSupportRenderer.renderReadexToolActivityBlock,
        updateReadexToolActivityBlockElement: messageBlockSupportRenderer.updateReadexToolActivityBlockElement,
        renderSearchResultsBlock: messageBlockSupportRenderer.renderSearchResultsBlock,
        renderReadexSourcesBlock: messageBlockSupportRenderer.renderReadexSourcesBlock,
        updateReadexSourcesBlockElement: messageBlockSupportRenderer.updateReadexSourcesBlockElement,
        renderSearchProgressBlock: messageBlockSupportRenderer.renderSearchProgressBlock,
        renderAttachments: messageBlockSupportRenderer.renderAttachments,
        renderReadexVideoProgressBlock: videoProgressRenderer.renderReadexVideoProgressBlock,
        renderableMessageBlocks: runtimeModel.renderableMessageBlocks,
        makeIcon: visualSupport.makeIcon,
        postPresentationProbe: hostBridge.postPresentationProbe,
        isInteractiveTranscript: hostBridge.isInteractiveTranscript,
        hasMessageActionHandler: hostBridge.hasMessageActionHandler,
        postMessageAction: hostBridge.postMessageAction
      });
    } catch (error) {
      stageFailure("message_block_renderer", error);
    }

    try {
      messageUIRenderer = createMessageUIRenderer({
        trimmed,
        makeIcon: visualSupport.makeIcon,
        messageIsStreaming: runtimeModel.messageIsStreaming,
        renderableMessageBlocks: runtimeModel.renderableMessageBlocks,
        blockText,
        messagePrimaryTextContent: runtimeModel.messagePrimaryTextContent,
        transcriptPresentation: hostBridge.transcriptPresentation,
        transcriptUIState: hostBridge.transcriptUIState,
        isInteractiveTranscript: hostBridge.isInteractiveTranscript,
        postMessageAction: hostBridge.postMessageAction,
        postPresentationProbe: hostBridge.postPresentationProbe,
        postLayoutLabComponentSelection: hostBridge.postLayoutLabComponentSelection,
        rerenderConversationPreservingScroll: conversationController.rerenderConversationPreservingScroll,
        keepToolbarVisible: interactionState.keepToolbarVisible,
        clearToolbarTimers: interactionState.clearToolbarTimers,
        hideActiveTooltip: interactionState.hideActiveTooltip,
        clearTooltipTimeout: interactionState.clearTooltipTimeout,
        setCopiedMessage: interactionState.setCopiedMessage,
        isMessageCopied: interactionState.isMessageCopied
      });
    } catch (error) {
      stageFailure("message_ui_renderer", error);
    }

    try {
      messageArticleRenderer = createMessageArticleRenderer({
        trimmed,
        effectiveMessageStatus: runtimeModel.effectiveMessageStatus,
        messageRenderSignature: renderSupport.messageRenderSignature,
        headerSignature: messageUIRenderer.headerSignature,
        renderMessageHeader: messageUIRenderer.renderMessageHeader,
        isInteractiveTranscript: hostBridge.isInteractiveTranscript,
        transcriptUIState: hostBridge.transcriptUIState,
        renderUserEditor: messageUIRenderer.renderUserEditor,
        renderUserEditFooter: messageUIRenderer.renderUserEditFooter,
        canShowUserToolbar: messageUIRenderer.canShowUserToolbar,
        renderAssistantActions: messageUIRenderer.renderAssistantActions,
        renderUserActions: messageUIRenderer.renderUserActions,
        patchReadexAssistantFooterActions: messageUIRenderer.patchReadexAssistantFooterActions,
        postPresentationProbe: hostBridge.postPresentationProbe,
        attachMessageInteractions: messageUIRenderer.attachMessageInteractions,
        directChildByClass: renderSupport.directChildByClass,
        replaceElementIfSignatureChanged: renderSupport.replaceElementIfSignatureChanged,
        currentMessageForArticle: messageUIRenderer.currentMessageForArticle,
        messageContent: {
          renderBlocks: messageBlockRenderer.renderMessageBlocks,
          reconcileBlocks: messageBlockRenderer.reconcileMessageBlocks,
          reconcileStoppedBoundary: messageBlockRenderer.reconcileStoppedBoundary
        }
      });
    } catch (error) {
      stageFailure("message_article_renderer", error);
    }

    try {
      rendererComponents = createRendererComponents({
        renderableMessageBlocks: runtimeModel.renderableMessageBlocks,
        renderMessageBlocks: messageBlockRenderer.renderMessageBlocks,
        reconcileMessageBlocks: messageBlockRenderer.reconcileMessageBlocks,
        renderMessageArticle: messageArticleRenderer.renderMessageArticle,
        patchMessageArticle: messageArticleRenderer.patchMessageArticle,
        messageRenderSignature: renderSupport.messageRenderSignature
      });
    } catch (error) {
      stageFailure("renderer_components", error);
    }

    try {
      conversationRenderer = createConversationRenderer({
        rendererComponents,
        configureMessageGroupShell: messageArticleRenderer.configureMessageGroupShell,
        currentConversationDocumentHeight,
        scrollRoot,
        afterMessagesUpdated,
          computeTranscriptDisplayMessages: conversationLayout.computeDisplayMessages,
          transcriptDisplayMessages,
          groupedConversationMessages,
          renderBranchNotice: visualSupport.renderBranchNotice,
          patchBranchNotice: visualSupport.patchBranchNotice,
          postPresentationProbe: hostBridge.postPresentationProbe
        });
    } catch (error) {
      stageFailure("conversation_renderer", error);
    }

    return Object.freeze({
      messageBlockSupportRenderer,
      messageBlockRenderer,
      messageUIRenderer,
      messageArticleRenderer,
      rendererComponents,
      conversationRenderer
    });
  };
})();
