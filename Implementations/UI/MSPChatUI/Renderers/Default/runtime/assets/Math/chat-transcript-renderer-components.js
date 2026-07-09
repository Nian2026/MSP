(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript renderer dependency: ${name}`);
    }
    return value;
  }

  window.ChatTranscriptRendererComponentCatalog = function createChatTranscriptRendererComponentCatalog(dependencies) {
    const MessageContent = Object.freeze({
      renderableBlocks: requiredFunction(dependencies, "renderableMessageBlocks"),
      renderBlocks: requiredFunction(dependencies, "renderMessageBlocks"),
      reconcileBlocks: requiredFunction(dependencies, "reconcileMessageBlocks")
    });

    const Message = Object.freeze({
      render: requiredFunction(dependencies, "renderMessageArticle"),
      patch: requiredFunction(dependencies, "patchMessageArticle"),
      signature: requiredFunction(dependencies, "messageRenderSignature")
    });

    return Object.freeze({
      MessageContent,
      Message
    });
  };
})();
