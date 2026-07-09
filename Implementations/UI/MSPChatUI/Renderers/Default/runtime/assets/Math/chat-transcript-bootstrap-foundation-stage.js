(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript bootstrap foundation stage dependency: ${name}`);
    }
    return value;
  }

  function requiredNumber(dependencies, name) {
    const value = Number(dependencies?.[name]);
    if (!Number.isFinite(value)) {
      throw new Error(`Missing ChatTranscript bootstrap foundation stage dependency: ${name}`);
    }
    return value;
  }

  function stageFailure(kind, error) {
    const normalizedError = error instanceof Error ? error : new Error(String(error));
    normalizedError.chatTranscriptBootstrapKind = kind;
    throw normalizedError;
  }

  window.ChatTranscriptBootstrapFoundationStageFactory = function createChatTranscriptBootstrapFoundationStage(dependencies) {
    const requiredGlobalFactory = requiredFunction(dependencies, "requiredGlobalFactory");
    const publishModule = requiredFunction(dependencies, "publishModule");
    const publishLegacyModule = requiredFunction(dependencies, "publishLegacyModule");
    const requiredPublishedObject = requiredFunction(dependencies, "requiredPublishedObject");
    const requiredPublishedFunction = requiredFunction(dependencies, "requiredPublishedFunction");
    const resolveOptionalModule = requiredFunction(dependencies, "resolveOptionalModule");
    const trimmed = requiredFunction(dependencies, "trimmed");
    const blockText = requiredFunction(dependencies, "blockText");
    const postTranscriptProbe = requiredFunction(dependencies, "postTranscriptProbe");
    const transcriptLiveEdgeThreshold = requiredNumber(dependencies, "transcriptLiveEdgeThreshold");

    function composeFoundationStage() {
      const createChatTranscriptMessageStatusModel = requiredGlobalFactory(
        "ChatTranscriptMessageStatusModelFactory",
        "message_status_model"
      );
      try {
        publishModule("statusModel", createChatTranscriptMessageStatusModel({
          trimmed,
          messageHasStructuredBlocks: (message) => requiredPublishedFunction("blockModel", "messageHasStructuredBlocks")(message)
        }));
      } catch (error) {
        stageFailure("message_status_model", error);
      }

      const createChatTranscriptMessageBlockModel = requiredGlobalFactory(
        "ChatTranscriptMessageBlockModelFactory",
        "message_block_model"
      );
      try {
        publishModule("blockModel", createChatTranscriptMessageBlockModel({
          trimmed,
          normalizedStatus: requiredPublishedFunction("statusModel", "normalizedStatus"),
          normalizedCatalogBlockStatus: requiredPublishedFunction("statusModel", "normalizedCatalogBlockStatus"),
          legacyMessageIsStreaming: requiredPublishedFunction("statusModel", "legacyMessageIsStreaming"),
          legacyMessageIsSearchInProgress: requiredPublishedFunction("statusModel", "legacyMessageIsSearchInProgress")
        }));
      } catch (error) {
        stageFailure("message_block_model", error);
      }

      const createChatTranscriptHostBridge = requiredGlobalFactory(
        "ChatTranscriptHostBridgeFactory",
        "host_bridge"
      );
      try {
        publishModule("hostBridge", createChatTranscriptHostBridge());
      } catch (error) {
        stageFailure("host_bridge", error);
      }

      const createChatTranscriptStylePlatform = requiredGlobalFactory(
        "ChatTranscriptStylePlatformFactory",
        "style_platform"
      );
      try {
        publishModule("stylePlatform", createChatTranscriptStylePlatform());
      } catch (error) {
        stageFailure("style_platform", error);
      }

      const createChatTranscriptMessageDOM = requiredGlobalFactory(
        "ChatTranscriptMessageDOMFactory",
        "message_dom"
      );
      try {
        publishModule("messageDOM", createChatTranscriptMessageDOM({
          trimmed
        }));
      } catch (error) {
        stageFailure("message_dom", error);
      }

      const createChatTranscriptScrollMetrics = requiredGlobalFactory(
        "ChatTranscriptScrollMetricsFactory",
        "scroll_metrics"
      );
      try {
        publishModule("scrollMetrics", createChatTranscriptScrollMetrics({
          transcriptLiveEdgeThreshold
        }));
      } catch (error) {
        stageFailure("scroll_metrics", error);
      }

      const createChatTranscriptAnchorPlatform = requiredGlobalFactory(
        "ChatTranscriptAnchorPlatformFactory",
        "anchor_platform"
      );
      try {
        publishModule("anchorPlatform", createChatTranscriptAnchorPlatform({
          postPresentationProbe: requiredPublishedFunction("hostBridge", "postPresentationProbe"),
          findMessageElement: requiredPublishedFunction("messageDOM", "findMessageElement"),
          scrollRoot: requiredPublishedFunction("scrollMetrics", "scrollRoot"),
          clamp: requiredPublishedFunction("scrollMetrics", "clamp"),
          maximumScrollTop: requiredPublishedFunction("scrollMetrics", "maximumScrollTop"),
          scrollViewportRect: requiredPublishedFunction("scrollMetrics", "scrollViewportRect")
        }));
      } catch (error) {
        stageFailure("anchor_platform", error);
      }

      const createChatTranscriptDOMPlatform = requiredGlobalFactory(
        "ChatTranscriptDOMPlatformFactory",
        "dom_platform"
      );
      try {
        publishModule("domPlatform", createChatTranscriptDOMPlatform({
          scrollMetrics: requiredPublishedObject("scrollMetrics"),
          anchorPlatform: requiredPublishedObject("anchorPlatform")
        }));
      } catch (error) {
        stageFailure("dom_platform", error);
      }

      const createChatTranscriptMessageRuntimeModel = requiredGlobalFactory(
        "ChatTranscriptMessageRuntimeModelFactory",
        "message_runtime_model"
      );
      try {
        publishModule("runtimeModel", createChatTranscriptMessageRuntimeModel({
          trimmed,
          blockText,
          statusModel: requiredPublishedObject("statusModel"),
          normalizedCatalogBlock: requiredPublishedFunction("blockModel", "normalizedCatalogBlock"),
          messageHasStructuredBlocks: requiredPublishedFunction("blockModel", "messageHasStructuredBlocks"),
          translatedLegacyInlineBlocks: requiredPublishedFunction("blockModel", "translatedLegacyInlineBlocks"),
          resolvedMessageBlocks: (message) => {
            const payloadModel = resolveOptionalModule("payloadModel");
            if (payloadModel && typeof payloadModel.resolvedMessageBlocks === "function") {
              return payloadModel.resolvedMessageBlocks(message);
            }
            return [];
          }
        }));
      } catch (error) {
        stageFailure("message_runtime_model", error);
      }

      const createChatTranscriptRenderSupport = requiredGlobalFactory(
        "ChatTranscriptRenderSupportFactory",
        "render_support"
      );
      try {
        publishModule("renderSupport", createChatTranscriptRenderSupport({
          trimmed,
          transcriptUIState: requiredPublishedFunction("hostBridge", "transcriptUIState"),
          postMessageAction: requiredPublishedFunction("hostBridge", "postMessageAction"),
          postTranscriptProbe,
          statusModel: requiredPublishedObject("statusModel"),
          resolveRuntimeModel: () => resolveOptionalModule("runtimeModel"),
          resolveMessageBlockRenderer: () => resolveOptionalModule("messageBlockRenderer"),
          resolveInteractionState: () => resolveOptionalModule("interactionState")
        }));
      } catch (error) {
        stageFailure("render_support", error);
      }

      const createChatTranscriptConversationLayout = requiredGlobalFactory(
        "ChatTranscriptConversationLayoutFactory",
        "conversation_layout"
      );
      try {
        publishModule("conversationLayout", createChatTranscriptConversationLayout({
          trimmed,
          messageDOMKey: requiredPublishedFunction("renderSupport", "messageDOMKey")
        }));
      } catch (error) {
        stageFailure("conversation_layout", error);
      }

      const createChatTranscriptPayloadModel = requiredGlobalFactory(
        "ChatTranscriptPayloadModelFactory",
        "payload_model"
      );
      try {
        publishModule("payloadModel", createChatTranscriptPayloadModel({
          trimmed,
          conversationLayout: requiredPublishedObject("conversationLayout"),
          blockModel: requiredPublishedObject("blockModel"),
          structuredMessageStatus: requiredPublishedFunction("runtimeModel", "structuredMessageStatus"),
          structuredMessageShellStatus: requiredPublishedFunction("statusModel", "structuredMessageShellStatus")
        }));
      } catch (error) {
        stageFailure("payload_model", error);
      }

      const createChatTranscriptPayloadPatcher = requiredGlobalFactory(
        "ChatTranscriptPayloadPatcherFactory",
        "payload_patcher"
      );
      try {
        publishModule("payloadPatcher", createChatTranscriptPayloadPatcher({
          trimmed,
          messageDOMKey: requiredPublishedFunction("renderSupport", "messageDOMKey"),
          conversationLayout: requiredPublishedObject("conversationLayout"),
          blockModel: requiredPublishedObject("blockModel"),
          payloadModel: requiredPublishedObject("payloadModel"),
          postTranscriptProbe
        }));
      } catch (error) {
        stageFailure("payload_patcher", error);
      }

      const createChatTranscriptPayloadStore = requiredGlobalFactory(
        "ChatTranscriptPayloadStoreFactory",
        "payload_store"
      );
      try {
        publishLegacyModule("payloadStore", createChatTranscriptPayloadStore({
          payloadModel: requiredPublishedObject("payloadModel"),
          payloadPatcher: requiredPublishedObject("payloadPatcher")
        }));
      } catch (error) {
        stageFailure("payload_store", error);
      }

      const createChatTranscriptVisualSupport = requiredGlobalFactory(
        "ChatTranscriptVisualSupportFactory",
        "visual_support"
      );
      try {
        publishModule("visualSupport", createChatTranscriptVisualSupport({
          trimmed
        }));
      } catch (error) {
        stageFailure("visual_support", error);
      }
    }

    return Object.freeze({
      composeFoundationStage
    });
  };
})();
