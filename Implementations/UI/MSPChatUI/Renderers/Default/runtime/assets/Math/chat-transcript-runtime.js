(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript runtime dependency: ${name}`);
    }
    return value;
  }

  function requiredObject(dependencies, name) {
    const value = dependencies?.[name];
    if (!value || typeof value !== "object") {
      throw new Error(`Missing ChatTranscript runtime dependency: ${name}`);
    }
    return value;
  }

  window.ChatTranscriptRuntimeFactory = function createChatTranscriptRuntime(dependencies) {
    const renderCoordinator = requiredObject(dependencies, "renderCoordinator");
    const conversationController = requiredObject(dependencies, "conversationController");
    const presentationController = requiredObject(dependencies, "presentationController");
    const applyDocumentPayloadShell = requiredFunction(renderCoordinator, "applyDocumentPayloadShell");
    const applyPatchPreservingScroll = requiredFunction(renderCoordinator, "applyPatchPreservingScroll");
    const updateStreamingMarkdownBlocks = requiredFunction(renderCoordinator, "updateStreamingMarkdownBlocks");
    const renderConversation = requiredFunction(renderCoordinator, "renderConversation");
    const renderConversationPreservingScroll = requiredFunction(conversationController, "renderConversationPreservingScrollEntry");
    const renderConversationImmediately = requiredFunction(conversationController, "renderConversationImmediately");
    const scrollConversationToTop = requiredFunction(conversationController, "scrollConversationToTop");
    const scrollConversationToBottom = requiredFunction(conversationController, "scrollConversationToBottom");
    const scrollConversationToMessage = requiredFunction(conversationController, "scrollConversationToMessage");
    const setConversationPresentation = requiredFunction(presentationController, "setConversationPresentation");

    return Object.freeze({
      applyDocumentPayloadShell,
      applyPatchPreservingScroll,
      updateStreamingMarkdownBlocks,
      renderConversation,
      renderConversationPreservingScroll,
      renderConversationImmediately,
      setConversationPresentation,
      scrollConversationToTop,
      scrollConversationToBottom,
      scrollConversationToMessage
    });
  };
})();
