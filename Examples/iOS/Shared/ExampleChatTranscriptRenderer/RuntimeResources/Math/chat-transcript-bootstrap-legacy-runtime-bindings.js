(function () {
  const legacyRuntimeBindings = Object.freeze({
    renderConversationPreservingScroll: "__renderConversationPreservingScroll",
    renderConversationImmediately: "__renderConversationImmediately",
    setConversationPresentation: "__setConversationPresentation",
    scrollConversationToTop: "__scrollConversationToTop",
    scrollConversationToBottom: "__scrollConversationToBottom",
    scrollConversationToMessage: "__scrollConversationToMessage",
    applyPatchPreservingScroll: "__applyConversationPatchPreservingScroll",
    renderConversation: "__renderConversation"
  });

  window.ChatTranscriptBootstrapLegacyRuntimeBindingsFactory = function createChatTranscriptBootstrapLegacyRuntimeBindings(dependencies = {}) {
    const windowObject = dependencies?.windowObject || window;

    function resolveLegacyRuntimeMethod(name) {
      const bindingName = legacyRuntimeBindings[name];
      if (typeof bindingName !== "string" || !bindingName) {
        return null;
      }
      const value = windowObject[bindingName];
      return typeof value === "function" ? value : null;
    }

    function publishLegacyRuntimeBindings(runtime) {
      windowObject.__renderConversationPreservingScroll = runtime?.renderConversationPreservingScroll;
      windowObject.__renderConversationImmediately = runtime?.renderConversationImmediately;
      windowObject.__setConversationPresentation = runtime?.setConversationPresentation;
      windowObject.__scrollConversationToTop = runtime?.scrollConversationToTop;
      windowObject.__scrollConversationToBottom = runtime?.scrollConversationToBottom;
      windowObject.__scrollConversationToMessage = runtime?.scrollConversationToMessage;
      windowObject.__applyConversationPatchPreservingScroll = runtime?.applyPatchPreservingScroll;
      windowObject.__renderConversation = runtime?.renderConversation;
    }

    return Object.freeze({
      resolveLegacyRuntimeMethod,
      publishLegacyRuntimeBindings
    });
  };
})();
