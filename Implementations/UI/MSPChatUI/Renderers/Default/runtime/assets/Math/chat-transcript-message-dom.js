(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript message DOM dependency: ${name}`);
    }
    return value;
  }

  window.ChatTranscriptMessageDOMFactory = function createChatTranscriptMessageDOM(dependencies) {
    const trimmed = requiredFunction(dependencies, "trimmed");

    function findMessageElement(messageID) {
      const normalizedID = trimmed(messageID);
      if (!normalizedID) {
        return null;
      }
      return Array.from(document.querySelectorAll(".message")).find((element) => element.dataset.messageId === normalizedID) || null;
    }

    function hasRenderedMessages() {
      return Boolean(document.querySelector("#messages .message"));
    }

    function syncFocusedMessage(messageID) {
      const normalizedID = trimmed(messageID);
      Array.from(document.querySelectorAll(".message.is-focused")).forEach((element) => {
        element.classList.remove("is-focused");
      });
      if (!normalizedID) {
        return;
      }
      const focusedElement = findMessageElement(normalizedID);
      if (focusedElement) {
        focusedElement.classList.add("is-focused");
      }
    }

    function syncLayoutLabSelection(presentation) {
      const root = document.documentElement;
      if (!root) {
        return;
      }

      const layoutLabVisible = Boolean(presentation?.layoutLabVisible);
      root.toggleAttribute("data-layout-lab-interactive", layoutLabVisible);
      Array.from(document.querySelectorAll(".message.assistant")).forEach((element) => {
        element.classList.toggle("is-layout-lab-selected", layoutLabVisible && Boolean(presentation?.assistantBubbleSelected));
      });
      Array.from(document.querySelectorAll(".message.user")).forEach((element) => {
        element.classList.toggle("is-layout-lab-selected", layoutLabVisible && Boolean(presentation?.userBubbleSelected));
      });
    }

    function syncPresentationState(presentation) {
      syncFocusedMessage(presentation?.focusedMessageID);
      syncLayoutLabSelection(presentation);
    }

    return Object.freeze({
      findMessageElement,
      hasRenderedMessages,
      syncFocusedMessage,
      syncLayoutLabSelection,
      syncPresentationState
    });
  };
})();
