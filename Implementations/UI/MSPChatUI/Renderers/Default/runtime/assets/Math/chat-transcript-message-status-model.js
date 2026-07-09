(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript message status model dependency: ${name}`);
    }
    return value;
  }

  window.ChatTranscriptMessageStatusModelFactory = function createChatTranscriptMessageStatusModel(dependencies) {
    const trimmed = requiredFunction(dependencies, "trimmed");
    const messageHasStructuredBlocks = requiredFunction(dependencies, "messageHasStructuredBlocks");

    function statusAliasKey(status) {
      return trimmed(status).toLowerCase().replace(/[\s_-]+/g, "");
    }

    function normalizedStatus(status) {
      const raw = trimmed(status).toLowerCase();
      if (!raw) {
        return "";
      }
      switch (statusAliasKey(raw)) {
        case "inprogress":
        case "running":
          return "processing";
        case "complete":
        case "completed":
        case "succeeded":
          return "success";
        case "failure":
        case "failed":
        case "error":
          return "failed";
        case "pause":
        case "paused":
          return "paused";
        case "cancelled":
        case "canceled":
        case "interrupted":
        case "stopped":
          return "interrupted";
        default:
          return raw;
      }
    }

    function statusIsLive(status) {
      const normalized = normalizedStatus(status);
      return normalized === "pending" || normalized === "processing" || normalized === "streaming" || normalized === "searching";
    }

    function messageShellStatus(message) {
      return normalizedStatus(message?.status);
    }

    function legacyStreamingFlagStatus(message) {
      if (Boolean(message?.isSearchInProgress)) {
        return "searching";
      }
      if (Boolean(message?.isStreaming)) {
        return "processing";
      }
      return "";
    }

    function legacyMessageStatus(message) {
      const status = messageShellStatus(message);
      if (status) {
        return status;
      }
      return legacyStreamingFlagStatus(message);
    }

    function structuredMessageShellStatus(message) {
      if (!messageHasStructuredBlocks(message)) {
        return "";
      }
      return messageShellStatus(message);
    }

    function legacyMessageIsStreaming(message) {
      return statusIsLive(legacyMessageStatus(message));
    }

    function legacyMessageIsSearchInProgress(message) {
      return legacyMessageStatus(message) === "searching";
    }

    function normalizedCatalogBlockStatus(block, message) {
      const explicitStatus = normalizedStatus(block?.status);
      if (explicitStatus) {
        return explicitStatus;
      }

      const blockType = typeof block?.type === "string" ? block.type : "";
      if (blockType === "search_progress") {
        return "processing";
      }
      if (blockType === "placeholder") {
        return "pending";
      }

      const messageStatus = messageHasStructuredBlocks(message)
        ? structuredMessageShellStatus(message)
        : legacyMessageStatus(message);
      if (messageStatus) {
        return messageStatus;
      }
      return "success";
    }

    function blockIsLive(block) {
      return statusIsLive(block?.status);
    }

    return Object.freeze({
      normalizedStatus,
      messageShellStatus,
      legacyStreamingFlagStatus,
      legacyMessageStatus,
      structuredMessageShellStatus,
      legacyMessageIsStreaming,
      legacyMessageIsSearchInProgress,
      normalizedCatalogBlockStatus,
      blockIsLive,
      statusIsLive
    });
  };
})();
