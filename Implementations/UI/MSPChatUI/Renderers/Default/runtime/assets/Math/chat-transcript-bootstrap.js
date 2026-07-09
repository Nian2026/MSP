(function () {
  function thresholdOption(options, name, fallback) {
    const value = Number(options?.[name]);
    return Number.isFinite(value) ? value : fallback;
  }

  function describedTranscriptBootstrapError(error) {
    if (error instanceof Error) {
      return `${error.name}: ${error.message}`;
    }
    return String(error);
  }

  function failTranscriptBootstrapWithoutSupport(kind, error) {
    const normalizedError = error instanceof Error ? error : new Error(String(error));
    const message = describedTranscriptBootstrapError(normalizedError);
    window.__chatTranscriptLastRuntimeBootstrapError = message;
    window.__chatTranscriptRuntimeBootstrap = {
      stage: "failed",
      source: "external",
      kind,
      error: message,
      hasRenderConversation: false
    };
    throw normalizedError;
  }

  window.ChatTranscriptBootstrapFactory = function createChatTranscriptBootstrap(options = {}) {
    const transcriptTopPinThreshold = thresholdOption(options, "transcriptTopPinThreshold", 24);
    const transcriptLiveEdgeThreshold = thresholdOption(options, "transcriptLiveEdgeThreshold", 64);
    const createChatTranscriptBootstrapSupport = window.ChatTranscriptBootstrapSupportFactory;
    if (typeof createChatTranscriptBootstrapSupport !== "function") {
      failTranscriptBootstrapWithoutSupport(
        "bootstrap_support",
        new Error("Missing ChatTranscriptBootstrapSupportFactory")
      );
    }

    let ChatTranscriptBootstrapSupport = null;
    try {
      ChatTranscriptBootstrapSupport = createChatTranscriptBootstrapSupport({
        windowObject: window
      });
    } catch (error) {
      failTranscriptBootstrapWithoutSupport("bootstrap_support", error);
    }

    const createChatTranscriptBootstrapLifecycle = ChatTranscriptBootstrapSupport.requiredGlobalFactory(
      "ChatTranscriptBootstrapLifecycleFactory",
      "bootstrap_lifecycle"
    );
    let ChatTranscriptBootstrapLifecycle = null;
    try {
      ChatTranscriptBootstrapLifecycle = createChatTranscriptBootstrapLifecycle({
        windowObject: window,
        support: ChatTranscriptBootstrapSupport,
        transcriptTopPinThreshold,
        transcriptLiveEdgeThreshold
      });
    } catch (error) {
      ChatTranscriptBootstrapSupport.failTranscriptBootstrap("bootstrap_lifecycle", error);
    }

    try {
      return ChatTranscriptBootstrapLifecycle.runBootstrap();
    } catch (error) {
      ChatTranscriptBootstrapSupport.failTranscriptBootstrap("runtime", error);
    }
  };
})();
