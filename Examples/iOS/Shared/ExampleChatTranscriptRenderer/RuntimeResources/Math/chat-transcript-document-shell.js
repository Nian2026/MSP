(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript document shell dependency: ${name}`);
    }
    return value;
  }

  window.ChatTranscriptDocumentShellFactory = function createChatTranscriptDocumentShell(dependencies) {
    const installGlobalTranscriptHandlers = requiredFunction(dependencies, "installGlobalTranscriptHandlers");
    const applyHighlightTheme = requiredFunction(dependencies, "applyHighlightTheme");
    const applyPayloadStyle = requiredFunction(dependencies, "applyPayloadStyle");

    function normalizedTheme(theme) {
      return theme === "dark" ? "dark" : "light";
    }

    function applyPayload(payload) {
      const theme = normalizedTheme(payload?.theme);
      const readexMarkdownRendererProfile = typeof payload?.chatMarkdownRendererProfile === "string"
        ? payload.chatMarkdownRendererProfile.trim()
        : typeof payload?.readexMarkdownRendererProfile === "string"
        ? payload.readexMarkdownRendererProfile.trim()
        : "";
      installGlobalTranscriptHandlers();
      document.documentElement.setAttribute("data-theme", theme);
      if (readexMarkdownRendererProfile) {
        document.documentElement.setAttribute("data-readex-markdown-renderer", readexMarkdownRendererProfile);
      } else {
        document.documentElement.removeAttribute("data-readex-markdown-renderer");
      }
      applyHighlightTheme(theme);
      applyPayloadStyle(payload?.style);
      document.title = payload?.conversationTitle || "聊天记录";
      return theme;
    }

    return Object.freeze({
      normalizedTheme,
      applyPayload
    });
  };
})();
