(function () {
  const createChatTranscriptBootstrapLaunch = window.ChatTranscriptBootstrapLaunchFactory;
  if (typeof createChatTranscriptBootstrapLaunch !== "function") {
    const message = "Missing ChatTranscriptBootstrapLaunchFactory";
    window.__chatTranscriptLastRuntimeBootstrapError = message;
    window.__chatTranscriptRuntimeBootstrap = {
      stage: "failed",
      source: "bridge",
      kind: "bootstrap_launch",
      error: message,
      hasRenderConversation: false
    };
    throw new Error(message);
  }

  const ChatTranscriptBootstrapLaunch = createChatTranscriptBootstrapLaunch({
    windowObject: window,
    transcriptTopPinThreshold: 24,
    transcriptLiveEdgeThreshold: 64
  });
  ChatTranscriptBootstrapLaunch.launch();
})();
