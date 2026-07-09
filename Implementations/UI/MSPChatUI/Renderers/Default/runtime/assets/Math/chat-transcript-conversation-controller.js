(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript conversation controller dependency: ${name}`);
    }
    return value;
  }

  function requiredObject(dependencies, name) {
    const value = dependencies?.[name];
    if (!value || typeof value !== "object") {
      throw new Error(`Missing ChatTranscript conversation controller dependency: ${name}`);
    }
    return value;
  }

  window.ChatTranscriptConversationControllerFactory = function createChatTranscriptConversationController(dependencies) {
    const scrollCoordinator = requiredObject(dependencies, "scrollCoordinator");
    const noteUserScrollGesture = requiredFunction(scrollCoordinator, "noteUserScrollGesture");
    const requestDisplayWindowExpansionIfNeeded = requiredFunction(scrollCoordinator, "requestDisplayWindowExpansionIfNeeded");
    const handleConversationScroll = requiredFunction(scrollCoordinator, "handleConversationScroll");
    const normalizedRenderOptions = requiredFunction(scrollCoordinator, "normalizedRenderOptions");
    const scheduleDeferredLiveRenderFlush = requiredFunction(scrollCoordinator, "scheduleDeferredLiveRenderFlush");
    const performConversationMutationPreservingScroll = requiredFunction(scrollCoordinator, "performConversationMutationPreservingScroll");
    const rerenderConversationPreservingScroll = requiredFunction(scrollCoordinator, "rerenderConversationPreservingScroll");
    const scrollConversationToTop = requiredFunction(scrollCoordinator, "scrollConversationToTop");
    const scrollConversationToBottom = requiredFunction(scrollCoordinator, "scrollConversationToBottom");
    const scrollConversationToMessage = requiredFunction(scrollCoordinator, "scrollConversationToMessage");

    function renderConversationPreservingScrollEntry(followBottomOrOptions) {
      return rerenderConversationPreservingScroll(normalizedRenderOptions(followBottomOrOptions));
    }

    function renderConversationImmediately(followBottomIfNearBottom) {
      return rerenderConversationPreservingScroll({
        followBottomIfNearBottom: Boolean(followBottomIfNearBottom),
        forceImmediateRender: true,
        debugReason: "render_conversation_immediately"
      });
    }

    return Object.freeze({
      noteUserScrollGesture,
      requestDisplayWindowExpansionIfNeeded,
      handleConversationScroll,
      scheduleDeferredLiveRenderFlush,
      normalizedRenderOptions,
      performConversationMutationPreservingScroll,
      rerenderConversationPreservingScroll,
      renderConversationPreservingScrollEntry,
      renderConversationImmediately,
      scrollConversationToTop,
      scrollConversationToBottom,
      scrollConversationToMessage
    });
  };
})();
