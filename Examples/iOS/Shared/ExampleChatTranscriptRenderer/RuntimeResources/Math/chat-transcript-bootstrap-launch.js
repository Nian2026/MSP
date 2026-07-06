(function () {
  function thresholdOption(options, name, fallback) {
    const value = Number(options?.[name]);
    return Number.isFinite(value) ? value : fallback;
  }

  function failTranscriptBootstrapLaunch(windowObject, kind, message) {
    windowObject.__chatTranscriptLastRuntimeBootstrapError = message;
    windowObject.__chatTranscriptRuntimeBootstrap = {
      stage: "failed",
      source: "bridge",
      kind,
      error: message,
      hasRenderConversation: false
    };
    throw new Error(message);
  }

  window.ChatTranscriptBootstrapLaunchFactory = function createChatTranscriptBootstrapLaunch(options = {}) {
    const windowObject = options?.windowObject || window;
    const transcriptTopPinThreshold = thresholdOption(options, "transcriptTopPinThreshold", 24);
    const transcriptLiveEdgeThreshold = thresholdOption(options, "transcriptLiveEdgeThreshold", 64);

    function launch() {
      const createChatTranscriptBootstrapEntry = windowObject.ChatTranscriptBootstrapEntryFactory;
      if (typeof createChatTranscriptBootstrapEntry !== "function") {
        failTranscriptBootstrapLaunch(
          windowObject,
          "bootstrap_entry",
          "Missing ChatTranscriptBootstrapEntryFactory"
        );
      }

      const ChatTranscriptBootstrapEntry = createChatTranscriptBootstrapEntry({
        windowObject,
        transcriptTopPinThreshold,
        transcriptLiveEdgeThreshold
      });
      windowObject.__chatTranscriptBootstrap = ChatTranscriptBootstrapEntry.initializeBootstrap();
      return windowObject.__chatTranscriptBootstrap;
    }

    return Object.freeze({
      launch
    });
  };
})();
