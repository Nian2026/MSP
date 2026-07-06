(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript bootstrap render stage dependency: ${name}`);
    }
    return value;
  }

  function stageFailure(kind, error) {
    const normalizedError = error instanceof Error ? error : new Error(String(error));
    normalizedError.chatTranscriptBootstrapKind = kind;
    throw normalizedError;
  }

  window.ChatTranscriptBootstrapRenderStageFactory = function createChatTranscriptBootstrapRenderStage(dependencies) {
    const windowObject = dependencies?.windowObject || window;
    const requiredGlobalFactory = requiredFunction(dependencies, "requiredGlobalFactory");
    const publishModule = requiredFunction(dependencies, "publishModule");
    const requiredPublishedObject = requiredFunction(dependencies, "requiredPublishedObject");
    const requiredPublishedFunction = requiredFunction(dependencies, "requiredPublishedFunction");
    const trimmed = requiredFunction(dependencies, "trimmed");
    const blockText = requiredFunction(dependencies, "blockText");

    function composeRenderStage() {
      const createChatTranscriptRenderPipeline = requiredGlobalFactory(
        "ChatTranscriptRenderPipelineFactory",
        "render_pipeline"
      );
      try {
        const renderPipeline = createChatTranscriptRenderPipeline({
          createMessageBlockSupportRenderer: requiredGlobalFactory(
            "ChatTranscriptMessageBlockSupportRendererFactory",
            "message_block_support_renderer"
          ),
          createMessageBlockRenderer: requiredGlobalFactory(
            "ChatTranscriptMessageBlockRendererFactory",
            "message_block_renderer"
          ),
          createMessageUIRenderer: requiredGlobalFactory(
            "ChatTranscriptMessageUIRendererFactory",
            "message_ui_renderer"
          ),
          createMessageArticleRenderer: requiredGlobalFactory(
            "ChatTranscriptMessageArticleRendererFactory",
            "message_article_renderer"
          ),
          createVideoProgressRenderer: requiredGlobalFactory(
            "ChatTranscriptVideoProgressRendererFactory",
            "video_progress_renderer"
          ),
          createRendererComponents: requiredGlobalFactory(
            "ChatTranscriptRendererComponentCatalog",
            "renderer_components"
          ),
          createConversationRenderer: requiredGlobalFactory(
            "ChatTranscriptConversationRendererFactory",
            "conversation_renderer"
          ),
          trimmed,
          blockText,
          currentConversationDocumentHeight: requiredPublishedFunction("scrollMetrics", "currentConversationDocumentHeight"),
          scrollRoot: requiredPublishedFunction("scrollMetrics", "scrollRoot"),
          resolveMarkdownRenderer: () => windowObject.ChatMarkdownRenderer,
          visualSupport: requiredPublishedObject("visualSupport"),
          statusModel: requiredPublishedObject("statusModel"),
          runtimeModel: requiredPublishedObject("runtimeModel"),
          renderSupport: requiredPublishedObject("renderSupport"),
          hostBridge: requiredPublishedObject("hostBridge"),
          interactionState: requiredPublishedObject("interactionState"),
          conversationController: requiredPublishedObject("conversationController"),
          overlayController: requiredPublishedObject("overlayController"),
          payloadModel: requiredPublishedObject("payloadModel"),
          conversationLayout: requiredPublishedObject("conversationLayout")
        });
        publishModule("messageBlockSupportRenderer", renderPipeline.messageBlockSupportRenderer);
        publishModule("messageBlockRenderer", renderPipeline.messageBlockRenderer);
        publishModule("messageUIRenderer", renderPipeline.messageUIRenderer);
        publishModule("messageArticleRenderer", renderPipeline.messageArticleRenderer);
        publishModule("rendererComponents", renderPipeline.rendererComponents);
        publishModule("conversationRenderer", renderPipeline.conversationRenderer);
      } catch (error) {
        stageFailure("render_pipeline", error);
      }

      const createChatTranscriptRenderCoordinator = requiredGlobalFactory(
        "ChatTranscriptRenderCoordinatorFactory",
        "render_coordinator"
      );
      try {
        publishModule("renderCoordinator", createChatTranscriptRenderCoordinator({
          normalizedRenderOptions: requiredPublishedFunction("conversationController", "normalizedRenderOptions"),
          trimmed,
          messageDOMKey: requiredPublishedFunction("renderSupport", "messageDOMKey"),
          rerenderConversationPreservingScroll: requiredPublishedFunction("conversationController", "rerenderConversationPreservingScroll"),
          performConversationMutationPreservingScroll: requiredPublishedFunction("conversationController", "performConversationMutationPreservingScroll"),
          payloadModel: requiredPublishedObject("payloadModel"),
          payloadPatcher: requiredPublishedObject("payloadPatcher"),
          documentRuntime: requiredPublishedObject("documentRuntime"),
          conversationRenderer: requiredPublishedObject("conversationRenderer"),
          messageBlockRenderer: requiredPublishedObject("messageBlockRenderer"),
          messageArticleRenderer: requiredPublishedObject("messageArticleRenderer"),
          messageBlockSupportRenderer: requiredPublishedObject("messageBlockSupportRenderer"),
          scrollRoot: requiredPublishedFunction("scrollMetrics", "scrollRoot"),
          blockText
        }));
      } catch (error) {
        stageFailure("render_coordinator", error);
      }

    }

    return Object.freeze({
      composeRenderStage
    });
  };
})();
