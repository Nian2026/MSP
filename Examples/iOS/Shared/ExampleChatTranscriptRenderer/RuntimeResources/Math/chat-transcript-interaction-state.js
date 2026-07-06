(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript interaction state dependency: ${name}`);
    }
    return value;
  }

  window.ChatTranscriptInteractionStateFactory = function createChatTranscriptInteractionState(dependencies) {
    const transcriptUIState = requiredFunction(dependencies, "transcriptUIState");
    const trimmed = requiredFunction(dependencies, "trimmed");
    const blockText = requiredFunction(dependencies, "blockText");
    const blockIsLive = requiredFunction(dependencies, "blockIsLive");
    const messageIsStreaming = requiredFunction(dependencies, "messageIsStreaming");
    const rerenderConversationPreservingScroll = requiredFunction(dependencies, "rerenderConversationPreservingScroll");

    function clearTooltipTimeout() {
      const state = transcriptUIState();
      if (state.tooltipTimeout) {
        clearTimeout(state.tooltipTimeout);
        state.tooltipTimeout = null;
      }
    }

    function hideActiveTooltip() {
      const state = transcriptUIState();
      clearTooltipTimeout();
      if (state.tooltipButton) {
        state.tooltipButton.classList.remove("show-tooltip");
        state.tooltipButton = null;
      }
    }

    function clearToolbarTimers(messageID) {
      const state = transcriptUIState();
      if (state.toolbarShowTimeouts[messageID]) {
        clearTimeout(state.toolbarShowTimeouts[messageID]);
        delete state.toolbarShowTimeouts[messageID];
      }
      if (state.toolbarHideTimeouts[messageID]) {
        clearTimeout(state.toolbarHideTimeouts[messageID]);
        delete state.toolbarHideTimeouts[messageID];
      }
    }

    function clearCopiedResetTimeout(messageID) {
      const state = transcriptUIState();
      if (state.copiedResetTimeouts[messageID]) {
        clearTimeout(state.copiedResetTimeouts[messageID]);
        delete state.copiedResetTimeouts[messageID];
      }
    }

    function isMessageCopied(messageID) {
      const state = transcriptUIState();
      const expiration = Number(state.copiedExpirations[messageID]) || 0;
      if (expiration <= 0) {
        return false;
      }
      if (expiration <= Date.now()) {
        delete state.copiedExpirations[messageID];
        clearCopiedResetTimeout(messageID);
        return false;
      }
      return true;
    }

    function keepToolbarVisible(messageID, visible) {
      const state = transcriptUIState();
      if (visible) {
        state.visibleUserToolbarMessageIDs[messageID] = true;
      } else {
        delete state.visibleUserToolbarMessageIDs[messageID];
      }
    }

    function setCopiedMessage(messageID) {
      const state = transcriptUIState();
      clearCopiedResetTimeout(messageID);
      state.copiedExpirations[messageID] = Date.now() + 1200;
      state.copiedResetTimeouts[messageID] = setTimeout(() => {
        delete state.copiedExpirations[messageID];
        clearCopiedResetTimeout(messageID);
        rerenderConversationPreservingScroll();
      }, 1200);
      rerenderConversationPreservingScroll();
    }

    function interactiveBlockStateKey(message, blockKey) {
      const messageID = trimmed(message?.id) || "__message__";
      const normalizedBlockKey = trimmed(blockKey) || "__block__";
      return `${messageID}:${normalizedBlockKey}`;
    }

    function defaultThinkingBlockExpanded(block, message) {
      const text = blockText(block);
      return Boolean((messageIsStreaming(message) || blockIsLive(block)) && block && block.durationMilliseconds == null && trimmed(text));
    }

    function isThinkingBlockExpanded(block, message, blockKey) {
      const state = transcriptUIState();
      const key = interactiveBlockStateKey(message, blockKey);
      if (Object.prototype.hasOwnProperty.call(state.expandedThinkingBlockState, key)) {
        return Boolean(state.expandedThinkingBlockState[key]);
      }
      return defaultThinkingBlockExpanded(block, message);
    }

    function hasExplicitThinkingBlockExpandedState(message, blockKey) {
      const state = transcriptUIState();
      const key = interactiveBlockStateKey(message, blockKey);
      return Object.prototype.hasOwnProperty.call(state.expandedThinkingBlockState, key);
    }

    function setThinkingBlockExpanded(message, blockKey, expanded) {
      const state = transcriptUIState();
      const key = interactiveBlockStateKey(message, blockKey);
      state.expandedThinkingBlockState[key] = Boolean(expanded);
    }

    return Object.freeze({
      clearTooltipTimeout,
      hideActiveTooltip,
      clearToolbarTimers,
      isMessageCopied,
      keepToolbarVisible,
      setCopiedMessage,
      interactiveBlockStateKey,
      defaultThinkingBlockExpanded,
      isThinkingBlockExpanded,
      hasExplicitThinkingBlockExpandedState,
      setThinkingBlockExpanded
    });
  };
})();
