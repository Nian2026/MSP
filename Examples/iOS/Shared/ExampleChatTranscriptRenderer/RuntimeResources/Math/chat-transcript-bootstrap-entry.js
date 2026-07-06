(function () {
  function thresholdOption(options, name, fallback) {
    const value = Number(options?.[name]);
    return Number.isFinite(value) ? value : fallback;
  }

  function describedTranscriptBootstrapEntryError(error) {
    if (error instanceof Error) {
      return `${error.name}: ${error.message}`;
    }
    return String(error);
  }

  window.ChatTranscriptBootstrapEntryFactory = function createChatTranscriptBootstrapEntry(options = {}) {
    const windowObject = options?.windowObject || window;
    const transcriptTopPinThreshold = thresholdOption(options, "transcriptTopPinThreshold", 24);
    const transcriptLiveEdgeThreshold = thresholdOption(options, "transcriptLiveEdgeThreshold", 64);

    function failTranscriptBootstrapEntry(kind, error) {
      const normalizedError = error instanceof Error ? error : new Error(String(error));
      const message = describedTranscriptBootstrapEntryError(normalizedError);
      windowObject.__chatTranscriptLastRuntimeBootstrapError = message;
      windowObject.__chatTranscriptRuntimeBootstrap = {
        stage: "failed",
        source: "bridge",
        kind,
        error: message,
        hasRenderConversation: false
      };
      throw normalizedError;
    }

    function requiredBootstrapFactory() {
      const value = windowObject.ChatTranscriptBootstrapFactory;
      if (typeof value === "function") {
        return value;
      }
      failTranscriptBootstrapEntry(
        "bootstrap_factory",
        new Error("Missing ChatTranscriptBootstrapFactory")
      );
    }

    function initializeBootstrap() {
      const createChatTranscriptBootstrap = requiredBootstrapFactory();
      const bootstrap = createChatTranscriptBootstrap({
        transcriptTopPinThreshold,
        transcriptLiveEdgeThreshold
      });
      windowObject.__chatTranscriptBootstrap = bootstrap;
      return bootstrap;
    }

    return Object.freeze({
      initializeBootstrap
    });
  };
})();
