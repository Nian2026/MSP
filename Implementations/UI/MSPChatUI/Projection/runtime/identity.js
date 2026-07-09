(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }
  root.MSPChatUIProjectionIdentity = api;
})(typeof globalThis !== "undefined" ? globalThis : window, function () {
  function text(value) {
    return typeof value === "string" ? value.trim() : "";
  }

  function stableID(parts) {
    return parts.map((part) => text(part).replace(/\s+/g, "-")).filter(Boolean).join(":");
  }

  function messageKey(message, index = 0) {
    return text(message?.patchKey) || text(message?.id) || `message-${index}`;
  }

  function blockID(message, block, index = 0) {
    return text(block?.id) || stableID([messageKey(message), "block", String(index)]);
  }

  function mainBlockID(message, index = 0) {
    return stableID([messageKey(message), "main", String(index)]);
  }

  function groupKey(role, firstMessageID) {
    return stableID([role || "assistant", firstMessageID || "group"]);
  }

  return Object.freeze({
    stableID,
    messageKey,
    blockID,
    mainBlockID,
    groupKey
  });
});
