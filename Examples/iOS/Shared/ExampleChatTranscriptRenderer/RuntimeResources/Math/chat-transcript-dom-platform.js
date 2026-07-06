(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript DOM platform dependency: ${name}`);
    }
    return value;
  }

  function requiredObject(dependencies, name) {
    const value = dependencies?.[name];
    if (!value || typeof value !== "object") {
      throw new Error(`Missing ChatTranscript DOM platform dependency: ${name}`);
    }
    return value;
  }

  window.ChatTranscriptDOMPlatformFactory = function createChatTranscriptDOMPlatform(dependencies) {
    const scrollMetrics = requiredObject(dependencies, "scrollMetrics");
    const anchorPlatform = requiredObject(dependencies, "anchorPlatform");
    const scrollRoot = requiredFunction(scrollMetrics, "scrollRoot");
    const clamp = requiredFunction(scrollMetrics, "clamp");
    const maximumScrollTop = requiredFunction(scrollMetrics, "maximumScrollTop");
    const isNearConversationBottom = requiredFunction(scrollMetrics, "isNearConversationBottom");
    const currentConversationDocumentHeight = requiredFunction(scrollMetrics, "currentConversationDocumentHeight");
    const scrollViewportRect = requiredFunction(scrollMetrics, "scrollViewportRect");
    const transcriptScrollSnapshot = requiredFunction(scrollMetrics, "transcriptScrollSnapshot");
    const anchorElementForPoint = requiredFunction(anchorPlatform, "anchorElementForPoint");
    const capturePresentationAnchor = requiredFunction(anchorPlatform, "capturePresentationAnchor");
    const restorePresentationAnchor = requiredFunction(anchorPlatform, "restorePresentationAnchor");
    const transcriptAnchorSnapshot = requiredFunction(anchorPlatform, "transcriptAnchorSnapshot");

    return Object.freeze({
      scrollRoot,
      clamp,
      maximumScrollTop,
      isNearConversationBottom,
      currentConversationDocumentHeight,
      scrollViewportRect,
      anchorElementForPoint,
      capturePresentationAnchor,
      restorePresentationAnchor,
      transcriptScrollSnapshot,
      transcriptAnchorSnapshot
    });
  };
})();
