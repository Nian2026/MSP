(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript bootstrap interaction stage dependency: ${name}`);
    }
    return value;
  }

  function requiredNumber(dependencies, name) {
    const value = Number(dependencies?.[name]);
    if (!Number.isFinite(value)) {
      throw new Error(`Missing ChatTranscript bootstrap interaction stage dependency: ${name}`);
    }
    return value;
  }

  function stageFailure(kind, error) {
    const normalizedError = error instanceof Error ? error : new Error(String(error));
    normalizedError.chatTranscriptBootstrapKind = kind;
    throw normalizedError;
  }

  window.ChatTranscriptBootstrapInteractionStageFactory = function createChatTranscriptBootstrapInteractionStage(dependencies) {
    const requiredGlobalFactory = requiredFunction(dependencies, "requiredGlobalFactory");
    const publishModule = requiredFunction(dependencies, "publishModule");
    const requiredPublishedObject = requiredFunction(dependencies, "requiredPublishedObject");
    const requiredPublishedFunction = requiredFunction(dependencies, "requiredPublishedFunction");
    const resolveOptionalModule = requiredFunction(dependencies, "resolveOptionalModule");
    const trimmed = requiredFunction(dependencies, "trimmed");
    const blockText = requiredFunction(dependencies, "blockText");
    const postTranscriptProbe = requiredFunction(dependencies, "postTranscriptProbe");
    const resolveRenderConversation = requiredFunction(dependencies, "resolveRenderConversation");
    const transcriptTopPinThreshold = requiredNumber(dependencies, "transcriptTopPinThreshold");
    const transcriptLiveEdgeThreshold = requiredNumber(dependencies, "transcriptLiveEdgeThreshold");

    function composeInteractionStage() {
      const createChatTranscriptScrollCoordinator = requiredGlobalFactory(
        "ChatTranscriptScrollCoordinatorFactory",
        "scroll_coordinator"
      );
      try {
        publishModule("scrollCoordinator", createChatTranscriptScrollCoordinator({
          trimmed,
          transcriptUIState: requiredPublishedFunction("hostBridge", "transcriptUIState"),
          transcriptPresentation: requiredPublishedFunction("hostBridge", "transcriptPresentation"),
          postTranscriptProbe,
          payloadModel: requiredPublishedObject("payloadModel"),
          scrollRoot: requiredPublishedFunction("scrollMetrics", "scrollRoot"),
          clamp: requiredPublishedFunction("scrollMetrics", "clamp"),
          isNearConversationBottom: requiredPublishedFunction("scrollMetrics", "isNearConversationBottom"),
          capturePresentationAnchor: requiredPublishedFunction("anchorPlatform", "capturePresentationAnchor"),
          restorePresentationAnchor: requiredPublishedFunction("anchorPlatform", "restorePresentationAnchor"),
          transcriptScrollSnapshot: requiredPublishedFunction("scrollMetrics", "transcriptScrollSnapshot"),
          transcriptAnchorSnapshot: requiredPublishedFunction("anchorPlatform", "transcriptAnchorSnapshot"),
          currentConversationDocumentHeight: requiredPublishedFunction("scrollMetrics", "currentConversationDocumentHeight"),
          findMessageElement: requiredPublishedFunction("messageDOM", "findMessageElement"),
          hasRenderedMessages: requiredPublishedFunction("messageDOM", "hasRenderedMessages"),
          resolveMessageUIRenderer: () => resolveOptionalModule("messageUIRenderer"),
          resolveSetConversationPresentation: () => resolveOptionalModule("presentationController")?.setConversationPresentation,
          resolveRenderConversation,
          transcriptTopPinThreshold,
          transcriptLiveEdgeThreshold
        }));
      } catch (error) {
        stageFailure("scroll_coordinator", error);
      }

      const createChatTranscriptConversationController = requiredGlobalFactory(
        "ChatTranscriptConversationControllerFactory",
        "conversation_controller"
      );
      try {
        publishModule("conversationController", createChatTranscriptConversationController({
          scrollCoordinator: requiredPublishedObject("scrollCoordinator")
        }));
      } catch (error) {
        stageFailure("conversation_controller", error);
      }

      const createChatTranscriptPresentationController = requiredGlobalFactory(
        "ChatTranscriptPresentationControllerFactory",
        "presentation_controller"
      );
      try {
        publishModule("presentationController", createChatTranscriptPresentationController({
          trimmed,
          transcriptUIState: requiredPublishedFunction("hostBridge", "transcriptUIState"),
          transcriptPresentation: requiredPublishedFunction("hostBridge", "transcriptPresentation"),
          hideActiveTooltip: () => {
            const interactionState = resolveOptionalModule("interactionState");
            if (interactionState && typeof interactionState.hideActiveTooltip === "function") {
              interactionState.hideActiveTooltip();
            }
          },
          postTranscriptProbe,
          scrollRoot: requiredPublishedFunction("scrollMetrics", "scrollRoot"),
          transcriptScrollSnapshot: requiredPublishedFunction("scrollMetrics", "transcriptScrollSnapshot"),
          applyConversationPresentationStyle: requiredPublishedFunction("stylePlatform", "applyConversationPresentationStyle"),
          hasRenderedMessages: requiredPublishedFunction("messageDOM", "hasRenderedMessages"),
          syncPresentationState: requiredPublishedFunction("messageDOM", "syncPresentationState"),
          rerenderConversationPreservingScroll: requiredPublishedFunction("conversationController", "rerenderConversationPreservingScroll"),
          messageUIRenderer: () => resolveOptionalModule("messageUIRenderer"),
          messageArticleRenderer: () => resolveOptionalModule("messageArticleRenderer")
        }));
      } catch (error) {
        stageFailure("presentation_controller", error);
      }

      const createChatTranscriptInteractionState = requiredGlobalFactory(
        "ChatTranscriptInteractionStateFactory",
        "interaction_state"
      );
      try {
        publishModule("interactionState", createChatTranscriptInteractionState({
          transcriptUIState: requiredPublishedFunction("hostBridge", "transcriptUIState"),
          trimmed,
          blockText,
          blockIsLive: requiredPublishedFunction("statusModel", "blockIsLive"),
          messageIsStreaming: requiredPublishedFunction("runtimeModel", "messageIsStreaming"),
          rerenderConversationPreservingScroll: requiredPublishedFunction("conversationController", "rerenderConversationPreservingScroll")
        }));
      } catch (error) {
        stageFailure("interaction_state", error);
      }

      const createChatTranscriptOverlayController = requiredGlobalFactory(
        "ChatTranscriptOverlayControllerFactory",
        "overlay_controller"
      );
      try {
        publishModule("overlayController", createChatTranscriptOverlayController({
          trimmed,
          postPresentationProbe: requiredPublishedFunction("hostBridge", "postPresentationProbe"),
          transcriptUIState: requiredPublishedFunction("hostBridge", "transcriptUIState"),
          displayTitleForReference: requiredPublishedFunction("visualSupport", "displayTitleForReference"),
          hostnameForReference: requiredPublishedFunction("visualSupport", "hostnameForReference"),
          populateReferenceAvatar: requiredPublishedFunction("visualSupport", "populateReferenceAvatar"),
          renderableMessageBlocks: requiredPublishedFunction("runtimeModel", "renderableMessageBlocks"),
          messageDOMKey: requiredPublishedFunction("renderSupport", "messageDOMKey"),
          messageIsStreaming: requiredPublishedFunction("runtimeModel", "messageIsStreaming"),
          findMessageElement: requiredPublishedFunction("messageDOM", "findMessageElement"),
          messageBlockKey: (block, index) => trimmed(block?.id) || `__message_block_${index}`,
          transcriptScrollSnapshot: requiredPublishedFunction("scrollMetrics", "transcriptScrollSnapshot"),
          scrollRoot: requiredPublishedFunction("scrollMetrics", "scrollRoot"),
          noteUserScrollGesture: requiredPublishedFunction("conversationController", "noteUserScrollGesture"),
          handleConversationScroll: requiredPublishedFunction("conversationController", "handleConversationScroll"),
          rerenderConversationPreservingScroll: requiredPublishedFunction("conversationController", "rerenderConversationPreservingScroll"),
          payloadModel: requiredPublishedObject("payloadModel")
        }));
      } catch (error) {
        stageFailure("overlay_controller", error);
      }
    }

    return Object.freeze({
      composeInteractionStage
    });
  };
})();
