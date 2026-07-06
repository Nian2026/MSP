(() => {
  const catalog = __CHAT_TRANSCRIPT_SYSTEM_SYMBOLS_PAYLOAD__;
  window.__chatTranscriptSystemSymbols =
    catalog && typeof catalog === "object" ? catalog : {};
})();
