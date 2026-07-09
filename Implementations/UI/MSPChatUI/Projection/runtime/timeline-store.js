(function (root, factory) {
  const api = factory({
    events: root.MSPChatUIRuntimeEvents,
    streamDelta: root.MSPChatUIStreamDelta,
    timeline: root.MSPChatUITimelineContract
  });
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }
  root.MSPChatUITimelineStore = api;
})(typeof globalThis !== "undefined" ? globalThis : window, function ({ events, streamDelta, timeline }) {
  function clone(value) {
    return JSON.parse(JSON.stringify(value));
  }

  function nextRevision(current) {
    return (Number(current?.revision) || 0) + 1;
  }

  function replaceByID(list, id, nextValue) {
    const index = list.findIndex((item) => item.id === id);
    return index < 0
      ? [...list, nextValue]
      : list.map((item, itemIndex) => itemIndex === index ? nextValue : item);
  }

  function mapMessage(current, messageID, transform) {
    return {
      ...current,
      messages: current.messages.map((message) => message.id === messageID ? transform(message) : message)
    };
  }

  function applyRuntimeEvent(currentTimeline, runtimeEvent) {
    const validation = events.validateRuntimeEvent(runtimeEvent);
    if (!validation.ok) {
      const error = new Error(`Invalid MSPChatUI runtime event: ${validation.errors.join("; ")}`);
      error.validation = validation;
      throw error;
    }
    const event = validation.value;
    if (event.type === "timeline.replace") {
      return timeline.normalizeTimeline(event.timeline);
    }

    const current = timeline.normalizeTimeline(currentTimeline);
    if (event.type === "presentation.update") return updatePresentation(current, event);
    if (event.type === "message.upsert") return upsertMessage(current, event);
    if (event.type === "message.remove") return removeMessage(current, event);
    if (event.type === "message.status") return updateMessageStatus(current, event);
    if (event.type === "message.patch") return patchMessage(current, event);
    if (event.type === "block.upsert") return upsertBlock(current, event);
    if (event.type === "block.remove") return removeBlock(current, event);
    if (event.type === "block.patch") return patchBlock(current, event);
    if (event.type === "block.status" || event.type === "stream.delta") return updateBlock(current, event);
    if (event.type === "tool.lifecycle") return upsertToolLifecycle(current, event);
    if (event.type === "interaction.collapse") return updateCollapseState(current, event);
    if (event.type === "selection.update") return updateSelection(current, event);
    return { ...current, revision: nextRevision(current) };
  }

  function updatePresentation(current, event) {
    return {
      ...current,
      revision: nextRevision(current),
      presentation: { ...current.presentation, ...(event.presentation || {}) }
    };
  }

  function upsertMessage(current, event) {
    const message = timeline.normalizeMessage(event.message || { id: event.messageID }, current.messages.length);
    return { ...current, revision: nextRevision(current), messages: replaceByID(current.messages, message.id, message) };
  }

  function removeMessage(current, event) {
    return { ...current, revision: nextRevision(current), messages: current.messages.filter((message) => message.id !== event.messageID) };
  }

  function updateMessageStatus(current, event) {
    return mapMessage({ ...current, revision: nextRevision(current) }, event.messageID, (message) => ({ ...message, status: event.status }));
  }

  function patchMessage(current, event) {
    return mapMessage({ ...current, revision: nextRevision(current) }, event.messageID, (message) => ({
      ...message,
      ...(event.patch || {})
    }));
  }

  function upsertBlock(current, event) {
    const sourceBlock = event.block || { id: event.blockID, type: "markdown" };
    return mapMessage({ ...current, revision: nextRevision(current) }, event.messageID, (message) => {
      const block = timeline.normalizeBlock(sourceBlock, message.blocks.length, message.id);
      return { ...message, blocks: replaceByID(message.blocks, block.id, block) };
    });
  }

  function removeBlock(current, event) {
    return mapMessage({ ...current, revision: nextRevision(current) }, event.messageID, (message) => ({
      ...message,
      blocks: message.blocks.filter((block) => block.id !== event.blockID)
    }));
  }

  function patchBlock(current, event) {
    return mapMessage({ ...current, revision: nextRevision(current) }, event.messageID, (message) => ({
      ...message,
      blocks: message.blocks.map((block) => block.id === event.blockID ? { ...block, ...(event.patch || {}) } : block)
    }));
  }

  function updateBlock(current, event) {
    return mapMessage({ ...current, revision: nextRevision(current) }, event.messageID, (message) => ({
      ...message,
      blocks: message.blocks.map((block) => {
        if (block.id !== event.blockID) return block;
        if (event.type === "stream.delta") return streamDelta.appendText(block, event);
        return { ...block, status: event.status };
      })
    }));
  }

  function upsertToolLifecycle(current, event) {
    const source = event.toolCall && typeof event.toolCall === "object" ? event.toolCall : {};
    const block = {
      id: event.blockID,
      type: "toolCall",
      toolName: source.toolName || event.toolName || event.blockID,
      title: source.title || event.title,
      detailText: source.detailText,
      outputText: source.outputText,
      errorText: source.errorText,
      durationMs: source.durationMs,
      status: event.status || source.status || "running"
    };
    return upsertBlock(current, { ...event, block });
  }

  function updateCollapseState(current, event) {
    const collapsedBlocks = { ...(current.presentation?.collapsedBlocks || {}) };
    collapsedBlocks[event.blockID] = event.collapsed !== false;
    return updatePresentation(current, {
      ...event,
      presentation: {
        collapsedBlocks,
        lastCollapsedBlockID: event.blockID
      }
    });
  }

  function updateSelection(current, event) {
    return updatePresentation(current, {
      ...event,
      presentation: {
        selection: event.selection || null
      }
    });
  }

  function applyRuntimeEvents(currentTimeline, runtimeEvents) {
    return (Array.isArray(runtimeEvents) ? runtimeEvents : [])
      .reduce((timelineState, event) => applyRuntimeEvent(timelineState, event), clone(currentTimeline));
  }

  return Object.freeze({
    applyRuntimeEvent,
    applyRuntimeEvents
  });
});
