(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript bootstrap document stage dependency: ${name}`);
    }
    return value;
  }

  function stageFailure(kind, error) {
    const normalizedError = error instanceof Error ? error : new Error(String(error));
    normalizedError.chatTranscriptBootstrapKind = kind;
    throw normalizedError;
  }

  window.ChatTranscriptBootstrapDocumentStageFactory = function createChatTranscriptBootstrapDocumentStage(dependencies) {
    const windowObject = dependencies?.windowObject || window;
    const documentObject = dependencies?.documentObject || document;
    const requiredGlobalFactory = requiredFunction(dependencies, "requiredGlobalFactory");
    const publishModule = requiredFunction(dependencies, "publishModule");
    const requiredPublishedObject = requiredFunction(dependencies, "requiredPublishedObject");
    const requiredPublishedFunction = requiredFunction(dependencies, "requiredPublishedFunction");
    const trimmed = requiredFunction(dependencies, "trimmed");
    const postTranscriptProbe = requiredFunction(dependencies, "postTranscriptProbe");

    function composeDocumentStage() {
      const createChatTranscriptDocumentShell = requiredGlobalFactory(
        "ChatTranscriptDocumentShellFactory",
        "document_shell"
      );
      try {
        publishModule("documentShell", createChatTranscriptDocumentShell({
          installGlobalTranscriptHandlers: requiredPublishedFunction("overlayController", "installGlobalTranscriptHandlers"),
          applyHighlightTheme: requiredPublishedFunction("stylePlatform", "applyHighlightTheme"),
          applyPayloadStyle: requiredPublishedFunction("stylePlatform", "applyPayloadStyle")
        }));
      } catch (error) {
        stageFailure("document_shell", error);
      }

      const createChatTranscriptDocumentRuntime = requiredGlobalFactory(
        "ChatTranscriptDocumentRuntimeFactory",
        "document_runtime"
      );
      try {
        publishModule("documentRuntime", createChatTranscriptDocumentRuntime({
          documentShell: requiredPublishedObject("documentShell"),
          trimmed,
          postTranscriptProbe,
          transcriptScrollSnapshot: requiredPublishedFunction("scrollMetrics", "transcriptScrollSnapshot"),
          scrollRoot: requiredPublishedFunction("scrollMetrics", "scrollRoot"),
          currentConversationDocumentHeight: requiredPublishedFunction("scrollMetrics", "currentConversationDocumentHeight"),
          markdownRenderer: () => windowObject.ChatMarkdownRenderer,
          messagesRootElement: () => documentObject.getElementById("messages"),
          pageElement: () => documentObject.getElementById("page")
        }));
      } catch (error) {
        stageFailure("document_runtime", error);
      }
    }

    return Object.freeze({
      composeDocumentStage
    });
  };
})();
