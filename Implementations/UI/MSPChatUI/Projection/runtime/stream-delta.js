(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }
  root.MSPChatUIStreamDelta = api;
})(typeof globalThis !== "undefined" ? globalThis : window, function () {
  function appendText(block, delta) {
    const currentText = typeof block?.text === "string" ? block.text : "";
    const nextDelta = typeof delta?.textDelta === "string" ? delta.textDelta : "";
    return {
      ...block,
      text: currentText + nextDelta,
      streaming: delta.status === "running" ? true : block.streaming,
      status: delta.status || block.status
    };
  }

  return Object.freeze({
    appendText
  });
});
