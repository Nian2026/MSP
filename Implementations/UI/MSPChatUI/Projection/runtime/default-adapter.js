(function (root, factory) {
  const api = factory({
    ids: root.MSPChatUIProjectionIdentity,
    timeline: root.MSPChatUITimelineContract,
    messages: root.MSPChatUIDefaultMessageAdapter,
    presentation: root.MSPChatUIDefaultPresentationAdapter
  });
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }
  root.MSPChatUIDefaultAdapter = api;
})(typeof globalThis !== "undefined" ? globalThis : window, function ({ ids, timeline, messages, presentation }) {
  function text(value) {
    return typeof value === "string" ? value : "";
  }

  function project(input, options = {}) {
    const normalized = timeline.normalizeTimeline(input);
    const projectedMessages = normalized.messages.map(messages.messageToDefault);
    const renderedMessages = projectedMessages.map((entry) => entry.message);
    const blockCatalog = projectedMessages.flatMap((entry) => entry.blocks);
    const finalPresentation = presentation.presentation(options.defaultPresentation || {}, normalized.presentation);
    const expansion = expansionMetadata(blockCatalog, finalPresentation);
    return {
      timeline: normalized,
      presentation: finalPresentation,
      payload: {
        conversationTitle: normalized.title,
        theme: finalPresentation.theme || "light",
        readexMarkdownRendererProfile: finalPresentation.readexMarkdownRendererProfile,
        readexMarkstreamCodeTheme: finalPresentation.readexMarkstreamCodeTheme,
        displayWindow: finalPresentation.displayWindow || null,
        messageActionPolicy: finalPresentation.messageActionPolicy || null,
        style: finalPresentation.style || {},
        messages: renderedMessages,
        blockCatalog,
        messageGroups: buildGroups(renderedMessages),
        ...expansion
      }
    };
  }

  function sourceID(block) {
    return text(block?.sourceBlockId || block?.sourceBlockID || block?.id);
  }

  function stateForBlock(block, presentation, field) {
    const states = presentation?.[field];
    if (!states || typeof states !== "object") return undefined;
    const candidates = [sourceID(block), text(block?.id)].filter(Boolean);
    for (const candidate of candidates) {
      if (typeof states[candidate] === "boolean") return states[candidate];
    }
    return undefined;
  }

  function expansionIDs(blockCatalog, presentation, type, expanded) {
    const explicitField = expanded ? "expandedBlocks" : "collapsedBlocks";
    return blockCatalog
      .filter((block) => block.type === type)
      .filter((block) => {
        const explicit = stateForBlock(block, presentation, explicitField);
        const collapsed = stateForBlock(block, presentation, "collapsedBlocks");
        return expanded ? explicit === true || collapsed === false : explicit === true;
      })
      .map(sourceID)
      .filter(Boolean);
  }

  function expansionMetadata(blockCatalog, presentation) {
    return {
      expandedReadexProcessingBlockIDs: expansionIDs(blockCatalog, presentation, "readex_processing", true),
      collapsedReadexProcessingBlockIDs: expansionIDs(blockCatalog, presentation, "readex_processing", false),
      expandedReadexToolActivityBlockIDs: expansionIDs(blockCatalog, presentation, "readex_tool_activity", true),
      collapsedReadexToolActivityBlockIDs: expansionIDs(blockCatalog, presentation, "readex_tool_activity", false)
    };
  }

  function buildGroups(messages) {
    return messages.map((message, index) => {
      const previous = messages[index - 1];
      const firstID = message.role === "assistant" ? text(message.replyToMessageID || previous?.id) : message.id;
      return {
        id: ids.groupKey(message.role, firstID || message.id),
        role: message.role === "assistant" ? "assistant" : "user",
        replyToMessageID: message.role === "assistant" ? firstID || null : null,
        messageIDs: [message.id]
      };
    });
  }

  return Object.freeze({
    project
  });
});
